import Foundation
import OSprCore

/// Replay saved raw model outputs through the product's actual Swift guard.
/// Does not run inference or access native UI, microphone or history.
@main struct RefinementGuardReplay {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw OSprError.message("Supply a refinement_eval.py JSON receipt.")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard let receipt = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = receipt["records"] as? [[String: Any]] else {
            throw OSprError.message("Invalid refinement receipt.")
        }
        let evaluated = try records.map { row -> [String: Any] in
            guard let id = row["id"] as? String, let source = row["input"] as? String,
                  let candidate = row["text"] as? String,
                  let facts = row["facts"] as? [String], let forbidden = row["forbidden"] as? [String] else {
                throw OSprError.message("Invalid refinement row.")
            }
            let reason = RewriteGuard.rejection(original: source, rewritten: candidate, mode: .clean)
            let delivered = reason == nil ? candidate : source
            let missing = facts.filter { !delivered.localizedCaseInsensitiveContains($0) }
            let invented = forbidden.filter { delivered.localizedCaseInsensitiveContains($0) }
            return ["id": id, "rejected": reason != nil, "reason": reason ?? "", "delivered": delivered,
                    "missing_facts": missing, "forbidden_present": invented,
                    "lexical_pass": missing.isEmpty && invented.isEmpty]
        }
        let result: [String: Any] = ["status": "evaluated-actual-swift-refinement-guard", "records": evaluated,
            "boundary": "Saved raw outputs through the product Clean-mode Swift tripwire and original-text fallback. Substring sentinels and heuristics do not prove semantic fidelity or native insertion."]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
        FileHandle.standardOutput.write(Data([10]))
    }
}
