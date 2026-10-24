// Copy into the platform test target and run ProfileFeedbackRenderTemporary.
// Headless layout renders only: no native event, picker, focus or save acceptance.
import AppKit
import SwiftUI
import XCTest
@testable import OSpr
@testable import OSprCore

final class ProfileFeedbackRenderTemporary: XCTestCase {
    @MainActor func testRenderFeedback() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OSPR_RENDER_ROOT"] ?? FileManager.default.currentDirectoryPath)
        let cases: [(String, ColorScheme, Double, Double, WritingMode, String?, String?)] = [
            ("invalid-site-light", .light, 744, 588, .verbatim, "https://example.com/project?public=1", nil),
            ("invalid-site-dark", .dark, 744, 588, .verbatim, "https://example.com/project?public=1", nil),
            ("invalid-custom", .light, 744, 588, .custom, nil, ""),
            ("provider-off-light", .light, 744, 588, .custom, nil, "Preserve names, numbers and negation."),
            ("provider-off-dark", .dark, 920, 740, .translate, "https://example.com/project", nil),
            ("compact-stress", .light, 500, 480, .verbatim, "https://example.com/project?public=1", nil)
        ]
        for (name, scheme, width, height, mode, site, instruction) in cases {
            let profile = AppProfile(bundleID: "com.example.browser", mode: mode, name: "Public browser profile",
                site: site, localModel: "whisper-turbo", language: "fr", customPrompt: instruction,
                translationLanguage: mode == .translate ? "Japanese" : nil)
            let body = ContextProfileEditor(profile: profile, localSpeech: true, rewriteEnabled: false,
                globalTranslation: "English", close: {}, save: { _ in })
                .frame(width: width, height: height).environment(\.colorScheme, scheme).tint(.osprPurple).background(Color.canvas)
            let view = NSHostingView(rootView: body)
            view.frame = NSRect(x: 0, y: 0, width: width, height: height)
            view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: root.appendingPathComponent("docs/assets/profile-feedback-" + name + ".png"))
        }
    }
}
