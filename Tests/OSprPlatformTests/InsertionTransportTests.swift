import ApplicationServices
import XCTest
@testable import OSpr
@testable import OSprCore

final class InsertionTransportTests: XCTestCase {
    @MainActor func testAcknowledgedWriteNeverPastes() throws {
        var events: [String] = []
        let delivery = try InsertionTransport.send(accessibility: .init(isSettable: {
            events.append("capability"); return (.success, true)
        }, write: { events.append("write"); return .success }), validate: {
            events.append("validate")
        }, paste: { events.append("paste") })
        XCTAssertEqual(delivery, .accessibility)
        XCTAssertEqual(events, ["validate", "capability", "validate", "write"])
    }

    @MainActor func testAppliedWriteWithLostAcknowledgementCannotDuplicateThroughPaste() {
        let failures: [AXError] = [.cannotComplete, .failure, .invalidUIElement, .illegalArgument,
                                   .apiDisabled, .noValue, .actionUnsupported, AXError(rawValue: -99999)!]
        for failure in failures {
            var text = "", writes = 0, pastes = 0
            XCTAssertThrowsError(try InsertionTransport.send(accessibility: .init(isSettable: {
                (.success, true)
            }, write: {
                writes += 1; text += "public phrase" // Write happened before the reply was lost.
                return failure
            }), validate: {}, paste: { pastes += 1; text += "public phrase" })) { error in
                XCTAssertTrue(error.localizedDescription.contains("Check the destination"))
            }
            XCTAssertEqual(text, "public phrase", "AX error \(failure.rawValue)")
            XCTAssertEqual(writes, 1); XCTAssertEqual(pastes, 0)
        }
    }

    @MainActor func testReadOnlyOrUnsupportedCapabilityPastesOnceWithoutWrite() throws {
        for capability: (AXError, Bool) in [(.success, false), (.attributeUnsupported, false), (.notImplemented, false)] {
            var events: [String] = []
            let delivery = try InsertionTransport.send(accessibility: .init(isSettable: {
                events.append("capability"); return capability
            }, write: { events.append("write"); return .success }), validate: {
                events.append("validate")
            }, paste: { events.append("paste") })
            XCTAssertEqual(delivery, .clipboard)
            XCTAssertEqual(events, ["validate", "capability", "validate", "paste"])
        }
    }

    @MainActor func testUnsupportedWriteRevalidatesBeforeFallback() throws {
        for error: AXError in [.attributeUnsupported, .notImplemented] {
            var events: [String] = []
            let delivery = try InsertionTransport.send(accessibility: .init(isSettable: {
                events.append("capability"); return (.success, true)
            }, write: { events.append("write"); return error }), validate: {
                events.append("validate")
            }, paste: { events.append("paste") })
            XCTAssertEqual(delivery, .clipboard)
            XCTAssertEqual(events, ["validate", "capability", "validate", "write", "validate", "paste"])
        }
    }

    @MainActor func testUncertainCapabilityDoesNotWriteOrPaste() {
        for error: AXError in [.cannotComplete, .failure, .invalidUIElement, .illegalArgument, .apiDisabled, .noValue] {
            var writes = 0, pastes = 0
            XCTAssertThrowsError(try InsertionTransport.send(accessibility: .init(isSettable: {
                (error, true)
            }, write: { writes += 1; return .success }), validate: {}, paste: { pastes += 1 }))
            XCTAssertEqual(writes, 0); XCTAssertEqual(pastes, 0)
        }
    }

    @MainActor func testDestinationChangesDuringCapabilityOrWriteCannotReachNextEffect() {
        // Capability IPC can move focus before either a direct write or a paste.
        for settable in [true, false] {
            var changed = false, writes = 0, pastes = 0
            XCTAssertThrowsError(try InsertionTransport.send(accessibility: .init(isSettable: {
                changed = true; return (.success, settable)
            }, write: { writes += 1; return .success }), validate: {
                if changed { throw OSprError.message("Field changed") }
            }, paste: { pastes += 1 }))
            XCTAssertEqual(writes, 0); XCTAssertEqual(pastes, 0)
        }
        // An unsupported setter can also take time and return after a switch.
        var changed = false, pastes = 0
        XCTAssertThrowsError(try InsertionTransport.send(accessibility: .init(isSettable: {
            (.success, true)
        }, write: { changed = true; return .attributeUnsupported }), validate: {
            if changed { throw OSprError.message("Cursor moved") }
        }, paste: { pastes += 1 }))
        XCTAssertEqual(pastes, 0)
    }

    @MainActor func testExplicitUnverifiedRouteStillValidatesAndPropagatesPasteFailure() throws {
        var events: [String] = []
        XCTAssertEqual(try InsertionTransport.send(accessibility: nil, validate: {
            events.append("validate")
        }, paste: { events.append("paste") }), .clipboard)
        XCTAssertEqual(events, ["validate", "validate", "paste"])
        XCTAssertThrowsError(try InsertionTransport.send(accessibility: nil, validate: {}, paste: {
            throw OSprError.message("Could not create shortcut")
        }))
    }

    @MainActor func testCancelledAttemptHasNoEffects() async throws {
        var queries = 0, writes = 0, pastes = 0, validations = 0
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertThrowsError(try InsertionTransport.send(accessibility: .init(isSettable: {
                queries += 1; return (.success, true)
            }, write: { writes += 1; return .success }), validate: {
                validations += 1
            }, paste: { pastes += 1 })) { error in XCTAssertTrue(error is CancellationError) }
        }
        try await task.value
        XCTAssertEqual(validations, 0); XCTAssertEqual(queries, 0)
        XCTAssertEqual(writes, 0); XCTAssertEqual(pastes, 0)
    }

    @MainActor func testCancellationDuringNativeRequestPreventsNextEffect() async throws {
        for cancelDuringWrite in [false, true] {
            var writes = 0, pastes = 0
            let task = Task { @MainActor in
                XCTAssertThrowsError(try InsertionTransport.send(accessibility: .init(isSettable: {
                    if !cancelDuringWrite { withUnsafeCurrentTask { $0?.cancel() } }
                    return (.success, true)
                }, write: {
                    writes += 1
                    withUnsafeCurrentTask { $0?.cancel() }
                    return .attributeUnsupported
                }), validate: {}, paste: { pastes += 1 })) { error in
                    XCTAssertTrue(error is CancellationError)
                }
            }
            try await task.value
            XCTAssertEqual(writes, cancelDuringWrite ? 1 : 0)
            XCTAssertEqual(pastes, 0)
        }
    }
    @MainActor func testWebRouteNeverQueriesOrWritesMisleadingSelectedTextCapability() throws {
        var events: [String] = []
        XCTAssertEqual(try InsertionTransport.send(accessibility: .init(isSettable: {
            events.append("capability"); return (.success, true)
        }, write: { events.append("write"); return .success }), preferClipboard: {
            events.append("web-role"); return true
        }, validate: { events.append("validate") }, paste: { events.append("paste") }), .clipboard)
        XCTAssertEqual(events, ["validate", "web-role", "validate", "paste"])
    }

    @MainActor func testWebRoutingFailureOrFocusChangeHasNoWriteOrPaste() {
        for unreadable in [true, false] {
            var changed = false, effects = 0
            XCTAssertThrowsError(try InsertionTransport.send(accessibility: .init(isSettable: {
                effects += 1; return (.success, true)
            }, write: { effects += 1; return .success }), preferClipboard: {
                changed = true
                if unreadable { throw OSprError.message("Unavailable ancestry") }
                return true
            }, validate: {
                if changed { throw OSprError.message("Field changed during ancestry read") }
            }, paste: { effects += 1 }))
            XCTAssertEqual(effects, 0)
        }
    }

}
