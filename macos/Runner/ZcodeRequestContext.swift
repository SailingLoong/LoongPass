import Cocoa
import Darwin

/// Reuses an existing official telemetry identity. This reads no credentials,
/// creates no device ID, and never modifies or stops the official application.
enum ZcodeRequestContext {
    enum Failure: Error { case unavailable }
    static func readTelemetry(_ url: URL) throws -> String {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unavailable }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(), before.st_size > 0, before.st_size <= 16384,
              let data = try file.read(upToCount: 16385), data.count <= 16384,
              fstat(fd, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mid = value["deviceMid"] as? String, UUID(uuidString: mid) != nil else {
            throw Failure.unavailable
        }
        return mid.lowercased()
    }
    static func observe() throws -> [String: String] {
        guard let home = getpwuid(getuid())?.pointee.pw_dir,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.zcode.app"),
              let bundle = Bundle(url: appURL), bundle.bundleIdentifier == "dev.zcode.app",
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            throw Failure.unavailable
        }
        let root = URL(fileURLWithPath: String(cString: home)).appendingPathComponent(".zcode/v2", isDirectory: true)
        let device = try readTelemetry(root.appendingPathComponent("telemetry-state.json"))
        #if arch(arm64)
        let platform = "darwin-arm64"
        #else
        let platform = "darwin-x64"
        #endif
        return ["version": version, "platform": platform, "deviceMid": device,
                "language": Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-CN" : "en-US",
                "timezone": TimeZone.current.identifier]
    }
    static func authorizationURL(_ raw: String) throws -> URL {
        guard let parts = URLComponents(string: raw), let url = parts.url,
              parts.scheme == "https",
              parts.port == nil || parts.port == 443, parts.user == nil,
              parts.password == nil, parts.fragment == nil,
              ((parts.host == "bigmodel.cn" && parts.path == "/login") ||
               (parts.host == "zcode.z.ai" && ["/authorize", "/oauth/authorize"].contains(parts.path))) else { throw Failure.unavailable }
        return url
    }
}
