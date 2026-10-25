import Foundation

@main struct LifetimeOwner {
    static func main() async throws {
        let arguments = CommandLine.arguments
        let worker = WorkerClient(root: arguments[1], timeout: 180, startupTimeout: 20)
        defer { worker.shutdown() }
        let mode = arguments[2]
        let destination = URL(fileURLWithPath: arguments[3])
        var records = [[String: Any]]()
        if mode == "measure" {
            for _ in 0..<6 {
                let start = DispatchTime.now().uptimeNanoseconds
                let reply = try await worker.request(["action": "ping"])
                records.append(["pid": reply["pid"]!, "round_trip_ms": Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000])
            }
        } else if mode == "control" {
            _ = try await worker.request(["action": "owned_lifetime_control"])
        } else if mode == "real" {
            let reply = try await worker.request(["action": "transcribe", "path": arguments[4], "model": "parakeet-v3", "language": "en", "trim": false])
            records.append(reply)
        } else { throw OSprError.message("Unknown lifetime control mode") }
        try JSONSerialization.data(withJSONObject: ["records": records], options: [.sortedKeys]).write(to: destination, options: .atomic)
    }
}
