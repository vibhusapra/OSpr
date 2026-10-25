// Temporarily copy into platform tests. Actual component, offscreen layout only.
import AppKit
import SwiftUI
import XCTest
@testable import OSpr
@testable import OSprCore

final class DurableImportRenderTemporary: XCTestCase {
    @MainActor func testLayouts() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OSPR_RENDER_ROOT"] ?? FileManager.default.currentDirectoryPath)
        var batch = FileImportBatch(urls: ["01-lecture.wav", "02-interrupted.wav", "03-待機-Café.wav", "04-a-long-public-recording-name-with-a-distinct-ending.mp3"].map { URL(fileURLWithPath: "/tmp/" + $0) })
        let first = batch.items[0]
        batch.begin(first.id); batch.finish(first.id, transcriptID: first.resultID, message: nil); batch.confirmStored(first.id)
        batch.begin(batch.items[1].id); batch.recover(existing: [first.resultID])
        for (name, scheme, width, height) in [("light", ColorScheme.light, 950.0, 440.0), ("dark", .dark, 950.0, 440.0), ("compact", .light, 700.0, 490.0)] {
            let body = ImportBatchContent(batch: batch, busy: false, retry: {}, open: { _ in }, recovered: true,
                recoveryDescription: "Saved locally with History. Source files stay unchanged. Resume reads their current contents using this batch’s original model and writing settings. A new batch replaces this queue.",
                providerDescription: "Local · whisper-small · Verbatim · rewrite: none", dismiss: {})
                .padding(18).frame(width: width, height: height).environment(\.colorScheme, scheme).tint(.osprPurple).background(Color.canvas)
            let view = NSHostingView(rootView: body); view.frame = NSRect(x: 0, y: 0, width: width, height: height)
            view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua); view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("docs/assets/durable-import-" + name + ".png"))
        }
    }
}
