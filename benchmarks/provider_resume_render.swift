// Actual batch-card component, offscreen layout only; not a native dialog test.
import AppKit
import SwiftUI
import XCTest
@testable import OSpr
@testable import OSprCore

final class ProviderResumeRenderTemporary: XCTestCase {
    @MainActor func testLayouts() throws {
        guard let path = ProcessInfo.processInfo.environment["OSPR_PROVIDER_RENDER_ROOT"] else { throw XCTSkip("Explicit offscreen render only") }
        let output = URL(fileURLWithPath: path)
        var config = OSprSettings(); config.mode = .clean
        config.transcriptionProvider = "compatible"; config.transcriptionURL = "https://speech.example.invalid:8443/teams/public-review/saved/v1"
        config.transcriptionModel = "original-speech-model"
        config.rewriteProvider = "compatible"; config.rewriteURL = "https://rewrite.example.invalid:9443/public-review/v1"
        config.rewriteModel = "original-text-model"
        var batch = FileImportBatch(urls: [URL(fileURLWithPath: "/tmp/Public provider resume.wav")]); batch.recover(existing: [])
        let description = FileImportSnapshot.providerDescription(for: config)
        for (name, scheme, width, height) in [("light", ColorScheme.light, 950.0, 390.0), ("dark", .dark, 950.0, 390.0), ("compact", .light, 700.0, 440.0)] {
            let body = ImportBatchContent(batch: batch, busy: false, retry: {}, open: { _ in }, recovered: true,
                recoveryDescription: "Saved locally with History. Resume uses the original model and writing settings; source files are read as they are now.",
                providerDescription: description, dismiss: {})
                .padding(18).frame(width: width, height: height).environment(\.colorScheme, scheme).tint(.osprPurple).background(Color.canvas)
            let view = NSHostingView(rootView: body); view.frame = NSRect(x: 0, y: 0, width: width, height: height)
            view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua); view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("provider-resume-" + name + ".png"))
        }
    }
}
