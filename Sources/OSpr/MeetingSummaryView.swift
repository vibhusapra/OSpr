import OSprCore
import SwiftUI

struct MeetingSummaryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: AudioReviewPlayer
    @State private var expanded = true
    let record: Transcript
    let summary: MeetingSummary
    init(model: AppModel, record: Transcript, summary: MeetingSummary) {
        self.model = model; self.record = record; self.summary = summary; player = model.audioReview
    }
    var body: some View {
        QuoteAudioContext(request: AudioQuoteRequest(record: record, summary: summary)) { audio in
            DisclosureGroup("Meeting summary · local AI", isExpanded: $expanded) {
                ScrollView {
                    MeetingSummaryContent(summary: summary, sourceIsCurrent: summary.sourceIsCurrent(in: record),
                        audio: audio, canPlay: player.ready && player.fileName == record.audioFile && !model.blocksQuotePlayback,
                        play: { id in if let audio { model.playQuote(audio, sourceID: id) } },
                        copy: { model.copy(audio.map { summary.markdown(audio: $0) } ?? summary.markdown) })
                }.frame(maxHeight: 280)
            }
        }
    }
}

struct MeetingSummaryContent: View {
    let summary: MeetingSummary
    var sourceIsCurrent = true
    var audio: AudioQuoteTimeline?
    var canPlay = false
    var play: (Int) -> Void = { _ in }
    let copy: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(summary.sourceKind == .original
                 ? "Uses the original transcript; editor changes do not update these notes."
                 : "Uses the edited text captured when this summary was generated. Its source snapshot is retained below.")
                .font(.caption).foregroundStyle(.secondary)
            if !sourceIsCurrent {
                Label("Edited text changed after generation. These notes still cite the saved snapshot; regenerate to use newer edits.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("AI paraphrases. Review the supporting quotes and full source transcript for errors, omissions or unresolved conflicts. Actions are notes; OSpr does not execute them.")
                .font(.caption).foregroundStyle(.secondary)
            if summary.items.isEmpty { Text("The model returned no summary items. Review the source transcript.").foregroundStyle(.secondary) }
            ForEach(SummarySection.allCases, id: \.self) { section in
                let points = summary.items.filter { $0.section == section }
                if !points.isEmpty {
                    Text(section.title).font(.headline)
                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(point.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            DisclosureGroup(point.sourceIDs.count == 1 ? "Source \(point.sourceIDs[0] + 1)" : "\(point.sourceIDs.count) source quotes") {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(point.sourceIDs, id: \.self) { id in
                                        if let excerpt = summary.excerpts.first(where: { $0.id == id }) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("SOURCE \(id + 1)").font(.caption2).foregroundStyle(.secondary)
                                                QuoteAudioLabel(id: id, audio: audio, canPlay: canPlay, play: play)
                                                Text(excerpt.text).font(.callout).textSelection(.enabled)
                                                    .fixedSize(horizontal: false, vertical: true)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                        }
                                    }
                                }
                            }.font(.caption)
                        }
                    }
                }
            }
            if let snapshot = summary.sourceSnapshot {
                DisclosureGroup("Edited source captured for this summary") {
                    Text(snapshot).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Button("Copy summary with sources as Markdown", action: copy)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
    }
}
