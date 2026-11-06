import Foundation
import Darwin

@main struct Checks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zcode-context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("telemetry-state.json")
        let bytes = Data("{\"deviceMid\":\"11111111-2222-4333-8444-555555555555\"}".utf8)
        try bytes.write(to: file)
        let observed = try ZcodeRequestContext.readTelemetry(file)
        let unchanged = try Data(contentsOf: file)
        precondition(observed == "11111111-2222-4333-8444-555555555555")
        precondition(unchanged == bytes)
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        do { _ = try ZcodeRequestContext.readTelemetry(link); fatalError("Accepted symlink") } catch {}
        try Data("{\"deviceMid\":\"invalid\"}".utf8).write(to: file)
        do { _ = try ZcodeRequestContext.readTelemetry(file); fatalError("Accepted invalid identity") } catch {}
        _ = try ZcodeRequestContext.authorizationURL("https://bigmodel.cn/login?flow=synthetic")
        for url in ["https://example.com/login", "http://bigmodel.cn/login", "https://bigmodel.cn/other", "https://bigmodel.cn:444/login", "https://user@bigmodel.cn/login"] {
            do { _ = try ZcodeRequestContext.authorizationURL(url); fatalError("Accepted unexpected authorization URL") } catch {}
        }
        print("ZCode request context checks passed; source unchanged")
    }
}
