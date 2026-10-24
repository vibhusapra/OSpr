import ApplicationServices
import OSprCore

/// One write attempt. A failed acknowledgement may hide a completed write, so
/// only an explicit unsupported/read-only result permits a different transport.
@MainActor enum InsertionTransport {
    struct Accessibility {
        let isSettable: () -> (AXError, Bool)
        let write: () -> AXError
    }

    static func send(accessibility: Accessibility?, validate: () throws -> Void,
                     paste: () throws -> Void) throws -> InsertionDelivery {
        func validateCurrent() throws {
            try Task.checkCancellation()
            try validate()
            try Task.checkCancellation()
        }
        try validateCurrent()
        if let accessibility {
            let (capability, settable) = accessibility.isSettable()
            switch capability {
            case .success:
                if settable {
                    // The capability query can take time; recheck before writing.
                    try validateCurrent()
                    let result = accessibility.write()
                    switch result {
                    case .success: return .accessibility
                    case .attributeUnsupported, .notImplemented: break
                    default:
                        throw OSprError.message("The app did not confirm text insertion. Check the destination before inserting again to avoid duplicate text.")
                    }
                }
            case .attributeUnsupported, .notImplemented: break
            default:
                throw OSprError.message("The destination could not be checked. Focus the intended field and try again.")
            }
        }
        // Never post a shortcut using focus captured before a slow AX request.
        try validateCurrent()
        try paste()
        return .clipboard
    }
}
