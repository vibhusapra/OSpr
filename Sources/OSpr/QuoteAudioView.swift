import OSprCore
import SwiftUI

/// A single cancellable, off-main index for the current quote/source snapshot.
/// Cached results are hidden immediately when the request changes.
struct QuoteAudioContext<Content: View>: View {
    let request: AudioQuoteRequest
    @ViewBuilder let content: (AudioQuoteTimeline?) -> Content
    @State private var resolved: AudioQuoteTimeline?
    var body: some View {
        content(resolved?.request == request ? resolved : nil)
            .task(id: request) {
                resolved = nil
                let job = Task.detached(priority: .userInitiated) { [request] in AudioQuoteTimeline(request, cancelled: { Task.isCancelled }) }
                let value = await withTaskCancellationHandler(operation: { await job.value }, onCancel: { job.cancel() })
                guard !Task.isCancelled else { return }
                resolved = value
            }
    }
}

struct QuoteAudioLabel: View {
    let id: Int
    var audio: AudioQuoteTimeline?
    var canPlay = false
    var play: (Int) -> Void = { _ in }
    var body: some View {
        if let timing = audio?.timings[id] {
            if audio?.request.audioFile != nil {
                Button { play(id) } label: { Label(timing.label, systemImage: "play.circle") }
                    .buttonStyle(.borderless).font(.caption).disabled(!canPlay)
                    .accessibilityLabel("Play source \(id + 1) at \(AudioTimeline.label(timing.start))")
                    .help("Seek to matching original audio. Recognizer timestamps are estimates; review the surrounding recording.")
            } else {
                Label(timing.label, systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                    .help("No audio was retained for playback. These times describe the original recognizer output.")
            }
        } else if let reason = audio?.unavailable[id] {
            Text(reason.explanation).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct MeetingNotesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: AudioReviewPlayer
    let record: Transcript
    let notes: MeetingNotes
    init(model: AppModel, record: Transcript, notes: MeetingNotes) {
        self.model = model; self.record = record; self.notes = notes; player = model.audioReview
    }
    var body: some View {
        QuoteAudioContext(request: AudioQuoteRequest(record: record, notes: notes)) { audio in
            DisclosureGroup("Key excerpts · local AI selection") {
                ScrollView { VStack(alignment: .leading, spacing: 12) {
                    Text("Exact source excerpts. Selection can miss context or important points; review the full transcript.").font(.caption).foregroundStyle(.secondary)
                    ForEach(notes.excerpts) { excerpt in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("SOURCE \(excerpt.id + 1)").font(.caption2).foregroundStyle(.secondary)
                            QuoteAudioLabel(id: excerpt.id, audio: audio, canPlay: player.ready && player.fileName == record.audioFile && !model.blocksQuotePlayback,
                                            play: { id in if let audio { model.playQuote(audio, sourceID: id) } })
                            Text(excerpt.text).textSelection(.enabled)
                        }
                    }
                    Button("Copy notes as Markdown") { model.copy(audio.map { notes.markdown(audio: $0) } ?? notes.markdown) }
                }.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 220)
            }
        }
    }
}
