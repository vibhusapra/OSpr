// Copy into platform tests temporarily. Offscreen layout, not native interaction.
import AppKit
import SwiftUI
import XCTest
@testable import OSpr
@testable import OSprCore

final class FileImportRenderTemporary: XCTestCase {
    @MainActor func testLayouts() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OSPR_RENDER_ROOT"] ?? FileManager.default.currentDirectoryPath)
        var batch = FileImportBatch(urls: ["01-lecture.wav", "02-damaged.wav", "03-long-public-fixture-name.wav"].map { URL(fileURLWithPath: "/tmp/" + $0) })
        for (index, item) in batch.items.enumerated() {
            batch.begin(item.id)
            batch.finish(item.id, transcriptID: index == 1 ? nil : UUID(), message: index == 1 ? "This file could not be read as audio. Check that it plays, or export it as WAV, MP3 or M4A and retry. The source is unchanged." : nil)
        }
        for (name, scheme, width, height) in [("light", ColorScheme.light, 880.0, 350.0), ("dark", .dark, 880.0, 350.0), ("compact", .light, 700.0, 390.0)] {
            let body = ImportBatchContent(batch: batch, busy: false, retry: {}, open: { _ in })
                .padding(18).frame(width: width, height: height).environment(\.colorScheme, scheme).tint(.osprPurple).background(Color.canvas)
            let view = NSHostingView(rootView: body); view.frame = NSRect(x: 0, y: 0, width: width, height: height)
            view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua); view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("docs/assets/file-import-batch-" + name + ".png"))
        }
    }
}
