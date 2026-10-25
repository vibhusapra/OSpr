// Copy temporarily into platform tests. Simulated layout, not native interaction.
import AppKit
import SwiftUI
import XCTest
@testable import OSpr
@testable import OSprCore

final class HistorySourceRenderTemporary: XCTestCase {
    @MainActor func testLayouts() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OSPR_RENDER_ROOT"] ?? FileManager.default.currentDirectoryPath)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-source-render-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(directory: directory)
        var settings = OSprSettings(); settings.saveHistory = false
        try store.write(settings, name: "settings.json")
        let model = AppModel(instanceLock: try AppInstanceLock(directory: directory), directory: directory, enableServices: false)
        for (n, source) in ["lecture-01.wav", "lecture-02.wav", "A very long public source filename with a distinct ending—日本語 Café [final].mp3"].enumerated() {
            let value = Transcript(rawText: "Shared words from the public fixture.", text: "Shared words from the public fixture.", model: "fixture", mode: .verbatim,
                duration: 10, latencyMS: 25, source: "/private-parent/" + source)
            model.historyState.submit(value, select: n == 0)
        }
        try await model.historyState.flush(); await model.historyState.reload()
        for (name, scheme, width, query) in [("light", ColorScheme.light, 330.0, ""), ("dark", .dark, 330.0, ""), ("compact", .light, 220.0, ""), ("search", .light, 330.0, "lecture-02")] {
            model.historyState.query = query
            let deadline = Date().addingTimeInterval(3)
            repeat { try await Task.sleep(for: .milliseconds(20)) } while model.historyState.loading && Date() < deadline
            XCTAssertFalse(model.historyState.loading)
            XCTAssertEqual(model.historyState.rows.count, query.isEmpty ? 3 : 1)
            // Offscreen AppKit List cells do not materialize reliably. Render
            // the identical shared production row views in a plain stack.
            let body = VStack(alignment: .leading, spacing: 12) {
                TextField("Search words or filenames", text: .constant(query)).textFieldStyle(.roundedBorder)
                Text(query.isEmpty ? "Export all history…" : "Export all search matches…").font(.caption).foregroundStyle(.secondary)
                ForEach(model.historyState.rows) { row in HistoryListRow(record: row); Divider() }
                Spacer(minLength: 0)
            }.padding(12).frame(width: width, height: 410).environment(\.colorScheme, scheme).tint(.osprPurple).background(Color.canvas)
            let view = NSHostingView(rootView: body); view.frame = NSRect(x: 0, y: 0, width: width, height: 410)
            view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua); view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("docs/assets/history-source-" + name + ".png"))
        }
    }
}
