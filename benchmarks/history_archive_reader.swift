// Compile against a retained older Core to verify its forward-version refusal.
import Foundation
import OSprCore

@main struct HistoryArchiveReader {
    static func main() {
        do {
            guard CommandLine.arguments.count == 2 else { throw OSprError.message("Expected a disposable fixture directory.") }
            let db = try HistoryDatabase(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
            print("records=\(try db.statistics().records)")
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
        }
    }
}
