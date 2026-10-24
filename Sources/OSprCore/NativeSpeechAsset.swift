import Foundation
import CryptoKit

/// The same data pin as the worker, independently checked before native load.
/// Reads only these five known assets; no download or conversion occurs here.
public enum NativeSpeechAsset {
    private struct Specification: Decodable {
        let subfolder: String
        let files: [Entry]
    }
    struct Entry: Decodable { let path: String; let size: Int; let sha256: String }
    public static func validate(_ modelURL: URL) throws {
        let spec = try JSONDecoder().decode(Specification.self, from: Data(specification.utf8))
        let root = modelURL.resolvingSymlinksInPath().standardizedFileURL
        guard root.isFileURL, root.lastPathComponent == spec.subfolder,
              (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw OSprError.message("The local speech detector path does not match the pinned model.")
        }
        let snapshot = root.deletingLastPathComponent()
        for entry in spec.files { try verify(snapshot.appendingPathComponent(entry.path), entry: entry) }
    }
    static func verify(_ fileURL: URL, entry: Entry) throws {
        let file = try FileHandle(forReadingFrom: fileURL.resolvingSymlinksInPath())
        defer { try? file.close() }
        guard entry.size > 0, entry.size <= 1_048_576 else { throw OSprError.message("Invalid speech detector asset size.") }
        var data = Data()
        while data.count <= entry.size {
            let part = try file.read(upToCount: entry.size + 1 - data.count) ?? Data()
            if part.isEmpty { break }
            data.append(part)
        }
        guard data.count == entry.size,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == entry.sha256 else {
            throw OSprError.message("The speech detector failed its pinned integrity check. Prepare it again in Models.")
        }
    }
    private static let specification = #"""
{
  "repo": "FluidInference/silero-vad-coreml",
  "revision": "b419383c55c110e2c9271fa6ee0ea83d03c70d96",
  "license": "MIT",
  "subfolder": "silero-vad-unified-v6.0.0.mlmodelc",
  "files": [
    {
      "path": "silero-vad-unified-v6.0.0.mlmodelc/analytics/coremldata.bin",
      "size": 243,
      "sha256": "2141be60ea0adf7acb1232fbcfaffb2be308ae02e6672d3762aedf36611ea9fd"
    },
    {
      "path": "silero-vad-unified-v6.0.0.mlmodelc/coremldata.bin",
      "size": 593,
      "sha256": "f460dcdf796b19c04bc38ab6e69601831f634e5e74d499487f0c8fe17ca12f0f"
    },
    {
      "path": "silero-vad-unified-v6.0.0.mlmodelc/metadata.json",
      "size": 3232,
      "sha256": "282b1b788b5d4d66d6a70d468464a7ada71d2469a8705526b741fd9ab841295a"
    },
    {
      "path": "silero-vad-unified-v6.0.0.mlmodelc/model.mil",
      "size": 25126,
      "sha256": "79eea23c368f3e7edf85af798a953f5b0910e4b08ff48e55fff8545dd05fd047"
    },
    {
      "path": "silero-vad-unified-v6.0.0.mlmodelc/weights/weight.bin",
      "size": 882304,
      "sha256": "853cf34740d3f5061f977ebe2976f7c921b064261c9c4753b3a1196f2dba42b4"
    }
  ]
}
"""#
}
