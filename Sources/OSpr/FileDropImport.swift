import AppKit
import OSprCore

@MainActor enum FileDropImport {
    /// Resolve the complete ordered drop before starting inference. One unreadable
    /// item rejects the drop visibly rather than silently importing a subset.
    static func urls(from providers: [NSItemProvider]) async throws -> [URL] {
        var urls: [URL] = []
        for (index, provider) in providers.enumerated() {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
            }
            guard let url, url.isFileURL else {
                throw OSprError.message("Dropped item \(index + 1) could not be read as a local file. No files were imported; try the drop again or use Import files.")
            }
            urls.append(url)
        }
        return urls
    }
}
