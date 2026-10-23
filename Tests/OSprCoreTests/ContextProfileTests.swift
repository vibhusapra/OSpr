import XCTest
@testable import OSprCore

final class ContextProfileTests: XCTestCase {
    func testLegacyProfilesDecodeWithoutOverrides() throws {
        let data = Data(#"{"profiles":[{"id":"00000000-0000-0000-0000-000000000001","bundleID":"com.test.app","mode":"email","enabled":true}]}"#.utf8)
        let settings = try JSONDecoder().decode(OSprSettings.self, from: data)
        let profile = try XCTUnwrap(settings.profiles.first)
        XCTAssertNil(profile.site); XCTAssertNil(profile.localModel); XCTAssertNil(profile.language); XCTAssertNil(profile.customPrompt)
        XCTAssertNil(profile.translationLanguage)
        XCTAssertEqual(settings.mode(for: "com.test.app"), .email)
        XCTAssertEqual(settings.mode(for: "com.test.app.child"), .clean)
    }

    func testSiteSpecificityAndFallbackAreIndependentOfArrayOrder() throws {
        var settings = OSprSettings()
        let app = AppProfile(bundleID: "com.test.browser", mode: .email)
        let root = AppProfile(bundleID: app.bundleID, mode: .code, site: "https://example.org")
        let team = AppProfile(bundleID: app.bundleID, mode: .bullets, site: "https://example.org/team/")
        let admin = AppProfile(bundleID: app.bundleID, mode: .custom, site: "https://example.org/team/admin")
        for rules in [[app, root, admin, team], [team, admin, root, app]] {
            settings.profiles = rules
            let document = try XCTUnwrap(ProfileSite("HTTPS://EXAMPLE.ORG:443/team/admin/edit?secret=do-not-store#fragment", isDocument: true))
            XCTAssertEqual(settings.matchingProfile(for: app.bundleID, document: document)?.id, admin.id)
            XCTAssertEqual(settings.matchingProfile(for: app.bundleID, document: ProfileSite("https://example.org/team/edit", isDocument: true))?.id, team.id)
            XCTAssertEqual(settings.matchingProfile(for: app.bundleID, document: ProfileSite("https://example.org/teammate", isDocument: true))?.id, root.id)
            XCTAssertEqual(settings.matchingProfile(for: app.bundleID, document: ProfileSite("https://other.org/team", isDocument: true))?.id, app.id)
            XCTAssertEqual(settings.matchingProfile(for: app.bundleID)?.id, app.id)
        }
    }

    func testRuleOriginPathAndCredentialBoundaries() throws {
        let rule = try XCTUnwrap(ProfileSite("https://example.org/team/"))
        for value in ["http://example.org/team", "https://sub.example.org/team", "https://example.org.evil/team", "https://example.org:444/team", "https://example.org/teammate", "https://example.org/Team", "https://example.org/team%2Fprivate"] {
            XCTAssertFalse(rule.matches(try XCTUnwrap(ProfileSite(value, isDocument: true))), value)
        }
        for value in ["https://example.org/team?x=1", "https://example.org/team#tab", "https://name@example.org/team", "file:///team", "example.org/team", "https://example.org:65536/team", "https://example.org/team/../private", "https://example.org/team/%2e%2e/private", "https://example.org/team%5Cprivate", "https://example.org/with space", "https://example.org/\nteam"] {
            XCTAssertNil(ProfileSite(value), value)
        }
        XCTAssertNil(ProfileSite("https://name@example.org/team", isDocument: true))
        XCTAssertTrue(rule.matches(try XCTUnwrap(ProfileSite("https://example.org:443/team/item?auth=secret#tab", isDocument: true))))
    }

    func testIPUnicodeAndEncodedPathCanonicalization() throws {
        XCTAssertEqual(ProfileSite("https://[::1]:443/team"), ProfileSite("https://[::1]/team/"))
        XCTAssertEqual(ProfileSite("http://127.0.0.1:80"), ProfileSite("http://127.0.0.1/"))
        XCTAssertEqual(ProfileSite("https://example.org/a%2fb"), ProfileSite("https://example.org/a%2Fb"))
        XCTAssertNotEqual(ProfileSite("https://example.org/a%2fb"), ProfileSite("https://example.org/a/b"))
        XCTAssertEqual(ProfileSite("https://münich.example/path"), ProfileSite("https://xn--mnich-kva.example/path"))
    }

    func testLocalOverridesAreOneTakeValueSnapshots() throws {
        var settings = OSprSettings()
        settings.language = "de"; settings.customPrompt = "Global instruction."
        settings.profiles = [.init(bundleID: "com.test.app", mode: .custom, localModel: "whisper-turbo", language: "en-GB", customPrompt: "Preserve identifiers.")]
        let snapshot = settings.resolvedProfile(for: "com.test.app")
        XCTAssertEqual(snapshot.model, "whisper-turbo"); XCTAssertEqual(snapshot.language, "en-GB")
        XCTAssertEqual(snapshot.mode, .custom); XCTAssertEqual(snapshot.customPrompt, "Preserve identifiers.")
        settings.profiles[0].language = "fr"; settings.model = "cohere-native8"
        XCTAssertEqual(snapshot.language, "en-GB"); XCTAssertEqual(snapshot.model, "whisper-turbo")
        XCTAssertEqual(settings.customPrompt, "Global instruction."); XCTAssertEqual(settings.mode, .clean)
        XCTAssertEqual(settings.resolvedProfile(for: "com.test.other").model, settings.model)
    }

    func testLanguageInheritanceAndExplicitAutomaticAreDifferent() {
        var settings = OSprSettings(); settings.language = "de"
        settings.profiles = [.init(bundleID: "com.test.inherit"), .init(bundleID: "com.test.auto", language: "")]
        XCTAssertEqual(settings.resolvedProfile(for: "com.test.inherit").language, "de")
        XCTAssertEqual(settings.resolvedProfile(for: "com.test.auto").language, "")
    }

    func testProfilesCannotChangeProviderPrivacyOrRetentionChoices() throws {
        var settings = OSprSettings()
        settings.transcriptionProvider = "soniox"; settings.transcriptionURL = "https://example.org/v1"
        settings.transcriptionModel = "stt-async-v5"; settings.rewriteProvider = "none"
        settings.autoPaste = false; settings.allowUnverifiedPaste = false; settings.keepAudio = false
        settings.profiles = [.init(bundleID: "com.test.app", mode: .custom, localModel: "whisper-turbo", language: "fr", customPrompt: "Keep names.")]
        let resolved = settings.resolvedProfile(for: "com.test.app")
        XCTAssertEqual(resolved.model, settings.model)
        XCTAssertEqual(resolved.transcriptionProvider, "soniox"); XCTAssertEqual(resolved.transcriptionURL, settings.transcriptionURL)
        XCTAssertEqual(resolved.transcriptionModel, "stt-async-v5"); XCTAssertEqual(resolved.rewriteProvider, "none")
        XCTAssertFalse(resolved.autoPaste); XCTAssertFalse(resolved.allowUnverifiedPaste); XCTAssertFalse(resolved.keepAudio)
        XCTAssertEqual(resolved.language, "fr"); XCTAssertEqual(resolved.customPrompt, "Keep names.")
    }

    func testInvalidDisabledAndForeignProfilesFailClosed() {
        var settings = OSprSettings()
        settings.profiles = [
            .init(bundleID: "com.test.app", mode: .code, enabled: false),
            .init(bundleID: "com.test.app", mode: .custom, site: "https://example.org?secret=1"),
            .init(bundleID: "com.test.app", mode: .custom, localModel: "untrusted/model"),
            .init(bundleID: "com.test.app", mode: .custom, language: "not a code"),
            .init(bundleID: "com.test.app", mode: .custom, customPrompt: String(repeating: "x", count: 16001)),
            .init(bundleID: "com.test.other", mode: .email)
        ]
        XCTAssertNil(settings.matchingProfile(for: "com.test.app", document: ProfileSite("https://example.org", isDocument: true)))
        XCTAssertFalse(settings.needsProfileDocument(for: "com.test.app"))
        XCTAssertEqual(settings.resolvedProfile(for: "com.test.app").mode, .clean)
    }

    func testCapturedDocumentDoesNotEnterTheConfigurationSnapshot() throws {
        var settings = OSprSettings()
        settings.profiles = [.init(bundleID: "com.test.browser", mode: .code, site: "https://example.org/team")]
        XCTAssertTrue(settings.needsProfileDocument(for: "com.test.browser"))
        XCTAssertFalse(settings.needsProfileDocument(for: "com.test.other"))
        let doc = try XCTUnwrap(ProfileSite("https://example.org/team/private-observed?auth=do-not-store#secret", isDocument: true))
        XCTAssertEqual(doc.normalized, "https://example.org/team/private-observed")
        let config = settings.resolvedProfile(for: "com.test.browser", document: doc)
        let data = try JSONEncoder().encode(config)
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(encoded.contains("private-observed")); XCTAssertFalse(encoded.contains("do-not-store"))
        XCTAssertEqual(config.mode, .code)
        XCTAssertEqual(try JSONDecoder().decode(OSprSettings.self, from: data).profiles, settings.profiles)
    }

    func testSameRuleAndEqualSpecificityUseDeterministicFirstMatch() {
        let a = AppProfile(bundleID: "com.test.app", mode: .email, site: "https://EXAMPLE.org:443/team/")
        let b = AppProfile(bundleID: "com.test.app", mode: .code, site: "https://example.org/team")
        XCTAssertTrue(a.hasSameRule(as: b))
        XCTAssertFalse(a.hasSameRule(as: .init(bundleID: a.bundleID)))
        var settings = OSprSettings(); settings.profiles = [a, b]
        XCTAssertEqual(settings.matchingProfile(for: a.bundleID, document: ProfileSite("https://example.org/team", isDocument: true))?.id, a.id)
    }

    func testEditUpdatesInPlaceAndRejectsDuplicateRulesOrInvalidDrafts() throws {
        var settings = OSprSettings()
        var profile = AppProfile(bundleID: "com.test.app", mode: .code, site: "https://example.org/team")
        try settings.upsertProfile(profile)
        profile.name = "Code"; profile.language = "fr"
        try settings.upsertProfile(profile)
        XCTAssertEqual(settings.profiles, [profile])
        XCTAssertThrowsError(try settings.upsertProfile(.init(bundleID: profile.bundleID, site: "https://EXAMPLE.org:443/team/")))
        XCTAssertThrowsError(try settings.upsertProfile(.init(bundleID: "com.test.app", language: "en\n")))
        XCTAssertEqual(settings.profiles, [profile])
        try settings.upsertProfile(.init(bundleID: "com.test.app"))
        XCTAssertEqual(settings.profiles.count, 2)
    }

    func testTranslationTargetIsSeparateFromRecognitionLanguage() {
        var settings = OSprSettings(); settings.translationLanguage = "English"
        settings.profiles = [.init(bundleID: "com.test.app", mode: .translate, language: "de", translationLanguage: "French")]
        let config = settings.resolvedProfile(for: "com.test.app")
        XCTAssertEqual(config.language, "de"); XCTAssertEqual(config.translationLanguage, "French")
        XCTAssertEqual(config.mode.instruction(custom: config.customPrompt, language: config.translationLanguage), "Translate into French. Preserve names, numbers and meaning.")
        XCTAssertEqual(settings.translationLanguage, "English")
        XCTAssertNotNil(AppProfile(bundleID: "com.test.app", translationLanguage: "French").validationError)
    }

    func testOlderDecodersCannotBroadenNewRulesOrLoseRequiredOverrides() throws {
        struct LegacyProfile: Decodable { var bundleID: String; var mode: WritingMode; var enabled: Bool }
        let profiles: [AppProfile] = [
            .init(bundleID: "com.test.app", mode: .code, site: "https://example.org/team"),
            .init(bundleID: "com.test.app", mode: .custom, customPrompt: "Keep code."),
            .init(bundleID: "com.test.app", mode: .clean, localModel: "whisper-turbo"),
            .init(bundleID: "com.test.app", mode: .clean, language: ""),
            .init(bundleID: "com.test.app", mode: .translate, translationLanguage: "French"),
            .init(bundleID: "com.test.app", mode: .email, name: "Mail")
        ]
        let data = try JSONEncoder().encode(profiles)
        let legacy = try JSONDecoder().decode([LegacyProfile].self, from: data)
        XCTAssertEqual(legacy.map(\.enabled), [false, false, false, false, false, true])
        XCTAssertEqual(legacy.first(where: { $0.enabled && $0.bundleID == "com.test.app" })?.mode, .email)
        XCTAssertEqual(try JSONDecoder().decode([AppProfile].self, from: data), profiles)
        var off = profiles[0]; off.enabled = false
        XCTAssertFalse(try JSONDecoder().decode(AppProfile.self, from: JSONEncoder().encode(off)).enabled)
    }
}
