import AppKit
import SwiftUI
import OSprCore

struct OptionalLocalModels: View {
    @ObservedObject var model: AppModel
    private let assets = [("rewrite-quality", "Qwen3 4B · local refinement & key excerpts"),
        ("meeting-quality", "Qwen3.5 9B · refinement & summaries · 6 GB download"),
        ("diarization", "Nemotron · experimental speaker labels"),
        ("speech-detector", "Silero · experimental neural edges & auto finish (native CPU)")]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Optional local models").font(.headline)
            ForEach(assets, id: \.0) { id, name in
                if let cache = model.modelCache[id] {
                    Card { VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(name).font(.callout)
                            Text(cache.cacheLabel + (model.residentModels.contains(id) ? " · resident" : "")).font(.caption).foregroundStyle(.secondary)
                            if LocalRefinementModel.allCases.contains(where: { $0.workerModel == id }) {
                                Text("Runs synthetic text, then discards it. Uses cached weights and leaves your loaded speech model resident. Preparing another text model replaces this one.")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            if model.preparedTextModel == id { Text("Synthetic text preparation complete").font(.caption).foregroundStyle(Color.osprInk) }
                            if id == "speech-detector" {
                                Text("MIT model data · optional edge filtering and auto finish; speech recognition uses your selected engine.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack { actions(id: id, cache: cache) }
                            VStack(alignment: .leading) { actions(id: id, cache: cache) }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
            Text("Preparing does not enable AI refinement. It moves first-use work before dictation; later requests still take time.").font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func actions(id: String, cache: ModelCacheStatus) -> some View {
        if !cache.complete { Button("Download") { model.warm(downloadOnly: id) }.disabled(model.busy || model.checkingModels) }
        if let choice = LocalRefinementModel.allCases.first(where: { $0.workerModel == id }), cache.complete {
            Button(model.preparedTextModel == id ? "Prepared ✓" : "Prepare on Metal") { model.prepareTextModel(choice) }
                .disabled(model.busy || model.checkingModels || model.preparedTextModel == id)
        }
        if let path = cache.path { Button("Show in Finder") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") } }
    }
}
