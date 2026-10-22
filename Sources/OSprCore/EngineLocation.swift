import Foundation

/// Installed CLI tools discover the engine beside their app executable. Explicit
/// overrides win; development commands can still run from a checkout directory.
public enum EngineLocation {
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               executable: URL? = Bundle.main.executableURL,
                               currentDirectory: String = FileManager.default.currentDirectoryPath) -> String {
        if let override = environment["OSPR_ROOT"], !override.isEmpty { return override }
        if let executable {
            let resources = executable.resolvingSymlinksInPath().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Resources", isDirectory: true)
            let engine = resources.appendingPathComponent("Engine", isDirectory: true)
            if FileManager.default.isExecutableFile(atPath: engine.appendingPathComponent(".venv/bin/python").path) { return engine.path }
            let marker = resources.appendingPathComponent("checkout-root.txt")
            if let checkout = try? String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               !checkout.isEmpty, FileManager.default.fileExists(atPath: URL(fileURLWithPath: checkout).appendingPathComponent("pyproject.toml").path) { return checkout }
        }
        return currentDirectory
    }
}
