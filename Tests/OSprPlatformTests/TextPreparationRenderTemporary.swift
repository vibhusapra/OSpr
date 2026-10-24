import AppKit
import SwiftUI
import XCTest
@testable import OSpr
@testable import OSprCore
final class TextPreparationRenderTemporary: XCTestCase {
    @MainActor func testRenderOptionalModels() async throws {
        let root = URL(fileURLWithPath: "/Users/vibhusapra/Documents/ChatGPT/OSpr")
        let profile = root.appendingPathComponent(".local/text-preparation-render-profile")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let app = AppModel(instanceLock: try AppInstanceLock(directory: profile), directory: profile, enableServices: false)
        for _ in 0..<1000 { if !app.busy { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let lock = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("backend/ospr_backend/models.lock.json"))) as! [String: [String: Any]]
        for id in ["rewrite-quality", "meeting-quality", "diarization"] {
            let spec = lock[id]!
            app.modelCache[id] = ModelCacheStatus(["id": id, "repo": spec["repo"]!, "revision": spec["revision"]!,
                "required_bytes": spec["artifact_bytes"]!, "verified_bytes": spec["artifact_bytes"]!, "complete": true,
                "path": "/public-fixture-cache/" + id])
        }
        for (name, scheme, width, height) in [("light", ColorScheme.light, 720.0, 600.0), ("dark", .dark, 720.0, 600.0), ("narrow", .light, 390.0, 650.0)] {
            let view = NSHostingView(rootView: OptionalLocalModels(model: app).padding(20).frame(width: width, height: height, alignment: .top).environment(\.colorScheme, scheme).background(Color.canvas))
            view.frame = NSRect(x: 0, y: 0, width: width, height: height)
            view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent(".local/text-preparation-models-" + name + ".png"))
        }
        try await app.prepareForTermination()
    }
}
