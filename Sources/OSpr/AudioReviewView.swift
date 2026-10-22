import SwiftUI
import OSprCore

@MainActor struct AudioReviewView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: AudioReviewPlayer
    let record: Transcript
    @State private var showWords = false
    init(model: AppModel, record: Transcript) {
        self.model = model; self.record = record; self.player = model.audioReview
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").frame(width: 18) }
                    .accessibilityLabel(player.playing ? "Pause retained audio" : "Play retained audio")
                Button { player.seek(to: player.position - 5) } label: { Image(systemName: "gobackward.5") }.accessibilityLabel("Back five seconds")
                Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }), in: 0...max(0.01, player.duration))
                    .accessibilityLabel("Audio position")
                Text(AudioTimeline.label(player.position) + " / " + AudioTimeline.label(player.duration)).font(.caption.monospacedDigit())
                Picker("Playback speed", selection: Binding(get: { player.speed }, set: { player.setSpeed($0) })) {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in Text(String(format: "%g×", speed)).tag(speed) }
                }.labelsHidden().frame(width: 72)
            }.disabled(!player.ready || blocksPlayback)
            if player.loading { ProgressView("Preparing local playback…").controlSize(.small) }
            if !player.error.isEmpty {
                HStack { Text(player.error).font(.caption).foregroundStyle(.orange); Button("Retry") { Task { await loadAudio() } }.font(.caption).disabled(blocksPlayback) }
            }
            HStack {
                Text("Local audio · recognizer source").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Export audio…") { model.exportRetainedAudio(record) }.font(.caption).disabled(model.busy)
            }
            DisclosureGroup("Timed original transcript") {
                VStack(alignment: .leading, spacing: 8) {
                    if let words = record.words, !words.isEmpty { Toggle("Word timestamps", isOn: $showWords).toggleStyle(.switch).controlSize(.mini) }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(Array((showWords ? record.words ?? record.segments : record.segments).enumerated()), id: \.offset) { _, segment in
                                Button { player.seek(to: segment.start, play: true) } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Text(AudioTimeline.label(segment.start)).monospacedDigit().frame(width: 62, alignment: .leading).foregroundStyle(.secondary)
                                        Text(segment.text).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                                    }.font(.caption).padding(7)
                                        .background(player.position >= segment.start && player.position < segment.end ? Color.osprPurple.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                                }.buttonStyle(.plain).disabled(!player.ready || blocksPlayback)
                            }
                        }
                    }.frame(maxHeight: 150)
                    Text("Edited text stays separate from recognizer timing. Word timestamps are available only when the engine supplies them.").font(.caption2).foregroundStyle(.secondary)
                }
            }.font(.caption)
        }.padding(12).background(Color.osprPurple.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .task(id: record.audioFile) { await loadAudio() }
        .onDisappear { if player.fileName == record.audioFile { player.stop() } }
    }
    private var blocksPlayback: Bool { model.phase == "recording" || model.phase == "starting" || model.audioMaintenance }
    private func loadAudio() async {
        guard let name = record.audioFile else { return }
        do {
            let resolved = try await model.audioArchive.resolve(name: name, id: record.id)
            guard !Task.isCancelled else { return }
            guard let url = resolved else { player.stop(); player.error = "Retained audio is no longer available."; return }
            await player.load(url)
        } catch {
            guard !Task.isCancelled else { return }
            player.stop(); player.error = error.localizedDescription
        }
    }
}
