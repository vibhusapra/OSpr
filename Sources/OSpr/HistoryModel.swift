import Foundation
import Combine
import OSprCore

/// Main-actor presentation for bounded history pages. Full payloads are retained
/// only for the selected/latest record and work awaiting a successful commit.
@MainActor final class HistoryModel: ObservableObject {
    @Published private(set) var rows: [HistoryRow] = []
    @Published private(set) var statistics = HistoryStatistics(records: 0, words: 0)
    @Published private(set) var latest: Transcript?
    @Published private(set) var selected: Transcript?
    @Published private(set) var loading = false
    @Published private(set) var loadingDetail = false
    @Published private(set) var saving = false
    @Published private(set) var failure = ""
    @Published private(set) var next: Int64?
    @Published var query = "" { didSet { if query != oldValue { refresh(debounce: true) } } }
    @Published var selection: UUID? {
        didSet { if selection != oldValue { loadSelection() } }
    }
    var onOrphanedAudio: (Set<String>) -> Void = { _ in }
    private let repository: HistoryRepository
    private var pageTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var pageEpoch = UUID()
    private var detailEpoch = UUID()
    private var writeEpoch = UUID()
    private var pendingRecords: [UUID: Transcript] = [:]
    @Published private(set) var savingEnabled: Bool
    private let pageSize: Int

    init(repository: HistoryRepository, saving: Bool, pageSize: Int = 100) {
        self.repository = repository; savingEnabled = saving
        self.pageSize = min(200, max(1, pageSize))
    }

    func start(retentionDays: Int) async {
        do { try await configure(saving: savingEnabled, retentionDays: retentionDays) }
        catch { failure = error.localizedDescription }
    }

    /// Apply both settings in one admission so observers see the whole policy.
    func configure(saving enabled: Bool, retentionDays: Int) async throws {
        savingEnabled = enabled
        if !enabled { stripCachedAudio(.all) }
        let token = beginWrite()
        repository.configure(saving: enabled, retentionDays: retentionDays, completion: observer(token))
        try await flush()
    }

    /// Awaitable for initialization, tests and explicit refresh. A newer mutation
    /// or query invalidates every result, including stats and latest detail.
    func reload() async {
        let epoch = UUID(); pageEpoch = epoch
        loading = true
        let text = query
        do {
            let page = try await repository.page(query: text, limit: pageSize)
            let stats = try await repository.statistics()
            let newest = try await repository.page(limit: 1).rows.first
            let record = try await newest.asyncFlatMap { try await self.repository.record(id: $0.id) }
            try Task.checkCancellation()
            guard pageEpoch == epoch else { return }
            rows = page.rows; next = page.next; statistics = stats
            latest = record
            if selection == nil { selection = rows.first?.id }
            else { loadSelection() }
            loading = false
        } catch is CancellationError {
            if pageEpoch == epoch { loading = false }
        } catch {
            if pageEpoch == epoch { loading = false; failure = error.localizedDescription }
        }
    }

    func refresh(debounce: Bool = false) {
        pageTask?.cancel(); pageEpoch = UUID(); loading = true
        pageTask = Task { [weak self] in
            if debounce {
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            }
            guard let self, !Task.isCancelled else { return }
            await reload()
        }
    }

    func loadMore() {
        guard let cursor = next, !loading else { return }
        pageTask?.cancel()
        let epoch = UUID(); pageEpoch = epoch; loading = true
        let text = query
        pageTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await repository.page(query: text, before: cursor, limit: pageSize)
                try Task.checkCancellation()
                guard pageEpoch == epoch else { return }
                let existing = Set(rows.map(\.id))
                rows.append(contentsOf: page.rows.filter { !existing.contains($0.id) })
                next = page.next; loading = false
            } catch is CancellationError {
                if pageEpoch == epoch { loading = false }
            } catch { if pageEpoch == epoch { loading = false; failure = error.localizedDescription } }
        }
    }

    func record(id: UUID) async throws -> Transcript? {
        if let pending = pendingRecords[id] { return pending }
        return try await repository.record(id: id)
    }

    func export(to destination: URL, format: TranscriptFileFormat, query: String) async throws -> TranscriptBatchExport.Result {
        try await repository.export(to: destination, format: format, query: query)
    }

    /// The transcriber ends its lease before admitting another take. Its newest
    /// result is a complete cached record, including failed/pending saves. A
    /// failed ASR take was never published here and must release its audio even
    /// if an unrelated unreadable archive prevents repository queries.
    func retainsResultAudio(id: UUID, name: String) -> Bool {
        savingEnabled && latest?.id == id && latest?.audioFile == name
    }

    func submit(_ value: Transcript, select: Bool) {
        var record = value
        if !savingEnabled { record.audioFile = nil }
        let token = beginWrite()
        pendingRecords[record.id] = record
        latest = record
        // A freshly recognized result is immediately available for copy/export,
        // even if a disk error prevents the next summary page from loading.
        if select || selection == nil { selection = record.id; selected = record }
        repository.submit(record, completion: observer(token))
    }

    func updateText(id: UUID, text: String) {
        let token = beginWrite()
        if selected?.id == id { selected?.text = text }
        if latest?.id == id { latest?.text = text }
        if pendingRecords[id] != nil { pendingRecords[id]?.text = text }
        repository.updateText(id: id, text: text, completion: observer(token))
    }

    func updateSummary(id: UUID, summary: MeetingSummary, expectedRawText: String, expectedEditedText: String? = nil) async throws {
        let token = beginWrite()
        repository.updateSummary(id: id, summary: summary, expectedRawText: expectedRawText, expectedEditedText: expectedEditedText, completion: observer(token))
        try await flush()
        guard let record = try await repository.record(id: id), record.rawText == expectedRawText,
              let saved = record.summary, saved.validatesStoredSource(for: record), saved.sourceIsCurrent(in: record), saved.items == summary.items,
              saved.excerpts == summary.excerpts, saved.model == summary.model, saved.chunks == summary.chunks,
              saved.created == summary.created, saved.sourceKind == summary.sourceKind,
              saved.sourceSHA256 == summary.sourceSHA256, saved.sourceSnapshot == summary.sourceSnapshot else {
            throw OSprError.message("Summary could not be applied. The transcript may have been removed or changed.")
        }
        guard writeEpoch == token else { return }
        if selected?.id == id { selected = record }
        if latest?.id == id { latest = record }
        if pendingRecords[id] != nil { pendingRecords[id] = record }
    }

    func clearSummary(id: UUID, expected: MeetingSummary) async throws {
        let token = beginWrite()
        repository.clearSummary(id: id, expected: expected, completion: observer(token))
        try await flush()
        guard let record = try await repository.record(id: id), record.summary == nil else {
            throw OSprError.message("Summary was not removed. It may have changed; review it before trying again.")
        }
        guard writeEpoch == token else { return }
        if selected?.id == id { selected = record }
        if latest?.id == id { latest = record }
        if pendingRecords[id] != nil { pendingRecords[id] = record }
    }

    func updateNotes(id: UUID, notes: MeetingNotes, expectedRawText: String) async throws {
        let token = beginWrite()
        repository.updateNotes(id: id, notes: notes, expectedRawText: expectedRawText, completion: observer(token))
        try await flush()
        guard let record = try await repository.record(id: id), record.rawText == expectedRawText,
              let saved = record.notes, saved.excerpts == notes.excerpts,
              saved.sourceSHA256 == notes.sourceSHA256, saved.model == notes.model,
              saved.created == notes.created else {
            throw OSprError.message("Notes could not be applied to this transcript. It may have been removed or changed.")
        }
        guard writeEpoch == token else { return }
        if selected?.id == id { selected = record }
        if latest?.id == id { latest = record }
    }

    func remove(id: UUID) {
        let token = beginWrite()
        pendingRecords.removeValue(forKey: id)
        rows.removeAll { $0.id == id }
        if latest?.id == id { latest = nil }
        if selection == id { selection = nil; selected = nil }
        repository.remove(ids: [id], completion: observer(token))
    }

    func clear() {
        let token = beginWrite()
        pendingRecords.removeAll(); rows.removeAll(); latest = nil; selection = nil; selected = nil
        statistics = HistoryStatistics(records: 0, words: 0); next = nil
        repository.clear(completion: observer(token))
    }

    func stripAudio(_ removal: HistoryAudioRemoval) {
        let token = beginWrite(); stripCachedAudio(removal)
        repository.stripAudio(removal, completion: observer(token))
    }

    func audioFiles() async throws -> Set<String> { try await repository.audioFiles() }

    func flush() async throws {
        // The callback always owns cleanup, including stale callbacks. Returning
        // names here as well would acknowledge/delete a receipt twice.
        _ = try await repository.flushAsync()
    }

    func flushOnQuit() throws { _ = try repository.flush() }

    private func beginWrite() -> UUID {
        pageTask?.cancel(); pageEpoch = UUID(); loading = false
        detailTask?.cancel(); detailEpoch = UUID(); loadingDetail = false
        let token = UUID(); writeEpoch = token; saving = true
        return token
    }

    private func observer(_ token: UUID) -> HistoryRepository.Completion {
        { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Committed orphan cleanup cannot be discarded with old UI work.
                if !result.orphanedAudio.isEmpty { onOrphanedAudio(result.orphanedAudio) }
                guard writeEpoch == token else { return }
                saving = false; failure = result.failure ?? ""
                if result.failure == nil { pendingRecords.removeAll(); refresh() }
            }
        }
    }

    private func loadSelection() {
        detailTask?.cancel(); let epoch = UUID(); detailEpoch = epoch
        guard let id = selection else { selected = nil; loadingDetail = false; return }
        if let record = pendingRecords[id] { selected = record; loadingDetail = false; return }
        if selected?.id != id { selected = nil }
        loadingDetail = true
        detailTask = Task { [weak self] in
            guard let self else { return }
            do {
                let record = try await repository.record(id: id)
                try Task.checkCancellation()
                guard detailEpoch == epoch, selection == id else { return }
                selected = record; loadingDetail = false
            } catch is CancellationError {
                if detailEpoch == epoch { loadingDetail = false }
            } catch { if detailEpoch == epoch { loadingDetail = false; failure = error.localizedDescription } }
        }
    }

    private func stripCachedAudio(_ removal: HistoryAudioRemoval) {
        func strip(_ record: inout Transcript?) {
            guard let name = record?.audioFile else { return }
            switch removal {
            case .all: record?.audioFile = nil
            case .names(let names): if names.contains(name) { record?.audioFile = nil }
            }
        }
        strip(&selected); strip(&latest)
        for id in Array(pendingRecords.keys) {
            var record = pendingRecords[id]; strip(&record); pendingRecords[id] = record
        }
    }
}

private extension Optional {
    func asyncFlatMap<T>(_ transform: (Wrapped) async throws -> T?) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}
