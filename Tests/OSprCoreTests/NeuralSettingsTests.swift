import XCTest
@testable import OSprCore

final class NeuralSettingsTests: XCTestCase {
    func testFreshAndMissingPreferencesKeepFullAudioButExplicitChoicesSurvive() throws {
        XCTAssertFalse(OSprSettings().silenceTrim)
        XCTAssertFalse(try JSONDecoder().decode(OSprSettings.self, from: Data("{}".utf8)).silenceTrim)
        for value in [true, false] {
            let bytes = try JSONSerialization.data(withJSONObject: ["silenceTrim": value])
            let decoded = try JSONDecoder().decode(OSprSettings.self, from: bytes)
            XCTAssertEqual(decoded.silenceTrim, value)
            XCTAssertEqual(try JSONDecoder().decode(OSprSettings.self, from: JSONEncoder().encode(decoded)).silenceTrim, value)
        }
    }
    func testLegacySettingsKeepTheirBehaviorAndNeuralDefaultsOff() throws {
        let old = try JSONDecoder().decode(OSprSettings.self, from: Data(#"{"autoStopSeconds":3,"silenceTrim":false}"#.utf8))
        XCTAssertFalse(old.neuralAutoFinish); XCTAssertEqual(old.neuralSilenceSeconds, 1.2)
        XCTAssertFalse(old.neuralEdgeTrim)
        XCTAssertEqual(old.autoStopSeconds, 3); XCTAssertFalse(old.silenceTrim)
        let row = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        XCTAssertEqual(row["autoStopSeconds"] as? Double, 3)
    }
    func testNeuralPreferenceEncodesInactiveForAnOlderAppWhilePreservingRMSChoice() throws {
        var settings = OSprSettings()
        settings.autoStopSeconds = 5; settings.neuralAutoFinish = true; settings.neuralSilenceSeconds = 1.5
        let bytes = try JSONEncoder().encode(settings)
        struct Legacy: Decodable { let autoStopSeconds: Double }
        XCTAssertEqual(try JSONDecoder().decode(Legacy.self, from: bytes).autoStopSeconds, 0)
        let decoded = try JSONDecoder().decode(OSprSettings.self, from: bytes)
        XCTAssertEqual(decoded, settings)
        var disabled = decoded; disabled.neuralAutoFinish = false
        XCTAssertEqual(try JSONDecoder().decode(Legacy.self, from: JSONEncoder().encode(disabled)).autoStopSeconds, 5)
    }
    func testCustomEncoderPreservesEveryNondefaultSettingAcrossRoundTrip() throws {
        var s = OSprSettings()
        s.model = "whisper-small"; s.language = "fr"; s.mode = .custom
        s.rewriteProvider = "local"; s.rewriteURL = "http://127.0.0.1:8100/v1"; s.rewriteModel = "fixture-rewrite"
        s.transcriptionProvider = "compatible"; s.transcriptionURL = "https://example.com/v1"; s.transcriptionModel = "fixture-asr"
        s.customPrompt = "Preserve this fixture"; s.translationLanguage = "French"; s.vocabulary = "OSpr"
        s.replacements = [.init(spoken: "fixture", replacement: "example")]
        s.profiles = [.init(bundleID: "app.fixture", mode: .verbatim, name: "Fixture", site: "https://example.com/path", language: "fr")]
        s.saveHistory = false; s.keepAudio = true; s.audioBudgetMB = 512; s.retentionDays = 7
        s.autoPaste = false; s.restoreClipboard = false; s.allowUnverifiedPaste = true; s.spokenPunctuation = true
        s.silenceTrim = true; s.silenceThreshold = 0.001; s.autoStopSeconds = 3
        s.neuralAutoFinish = true; s.neuralSilenceSeconds = 1.5; s.neuralEdgeTrim = true
        s.pushToTalk = true; s.hotkeyFnOnly = true; s.hotkeyCode = 6; s.hotkeyModifiers = 768
        s.microphoneID = "fixture-input"; s.preview = true; s.speakerLabels = true; s.launchAtLogin = true; s.rootPath = "/tmp/fixture-engine"
        XCTAssertEqual(try JSONDecoder().decode(OSprSettings.self, from: JSONEncoder().encode(s)), s)
    }
    func testInvalidNeuralSilenceDurationsReturnToTheStudiedDefault() {
        for value in [Double.nan, .infinity, -.infinity, 0, 1.19, 30.1] {
            var s = OSprSettings(); s.neuralSilenceSeconds = value
            XCTAssertEqual(s.validated().neuralSilenceSeconds, 1.2)
        }
        for value in [1.2, 1.5, 3, 5, 30] {
            var s = OSprSettings(); s.neuralSilenceSeconds = value
            XCTAssertEqual(s.validated().neuralSilenceSeconds, value)
        }
    }
    func testNeuralEdgesPreventOlderAppsFromApplyingRMSAndKeepTheStoredChoice() throws {
        var settings = OSprSettings(); settings.neuralEdgeTrim = true; settings.silenceTrim = true
        let bytes = try JSONEncoder().encode(settings)
        struct Legacy: Decodable { let silenceTrim: Bool }
        XCTAssertFalse(try JSONDecoder().decode(Legacy.self, from: bytes).silenceTrim)
        let decoded = try JSONDecoder().decode(OSprSettings.self, from: bytes)
        XCTAssertTrue(decoded.silenceTrim); XCTAssertEqual(decoded, settings)
        XCTAssertTrue(decoded.usesNeuralEdges)
        for provider in ["compatible", "deepgram", "soniox"] {
            var cloud = decoded; cloud.transcriptionProvider = provider
            XCTAssertFalse(cloud.usesNeuralEdges)
        }
    }
}
