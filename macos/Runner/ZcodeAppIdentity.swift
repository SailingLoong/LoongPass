// Native-only filesystem identity observation. This is not signer verification,
// runtime discovery, process observation or authorization to access an account.
import Foundation
import Darwin

struct ZcodeAppObservation: CustomStringConvertible {
    let app: ZcodeOwnerApp
    let version: String
    var description: String { "ZcodeAppObservation(redacted)" }
}

struct ZcodeAppIdentityCollector {
    private let limit = 1_048_576
    private func unavailable() -> ZcodeBridgeFailure { .nativeContextUnavailable }
    private func opened(_ parent: Int32, _ name: String, directory: Bool) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (directory ? O_DIRECTORY : 0))
        guard fd >= 0 else { throw unavailable() }; return fd
    }
    private func status(_ fd: Int32, directory: Bool) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              directory || info.st_nlink == 1 else { throw unavailable() }
        return info
    }
    private func sameCurrent(_ fd: Int32, _ url: URL, directory: Bool) throws {
        let observed = try status(fd, directory: directory)
        var current = stat()
        guard lstat(url.path, &current) == 0,
              current.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              current.st_dev == observed.st_dev, current.st_ino == observed.st_ino,
              directory || current.st_nlink == 1 else { throw unavailable() }
    }
    func collect(at url: URL) throws -> ZcodeAppObservation {
        guard url.isFileURL, (url.host == nil || url.host == ""),
              url.query == nil, url.fragment == nil, url.user == nil, url.password == nil,
              url.path.hasPrefix("/"), url.pathExtension == "app",
              url.standardizedFileURL.path == url.path,
              url.resolvingSymlinksInPath().path == url.path else { throw unavailable() }
        let root = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
        guard root >= 0 else { throw unavailable() }; defer { close(root) }
        let contents = try opened(root, "Contents", directory: true); defer { close(contents) }
        let plist = try opened(contents, "Info.plist", directory: false); defer { close(plist) }
        let before = try status(plist, directory: false)
        guard before.st_size > 0, before.st_size <= limit else { throw unavailable() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(plist, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0, data.count + count <= limit else { throw unavailable() }
            data.append(contentsOf: buffer.prefix(count))
        }
        let after = try status(plist, directory: false)
        guard before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              let values = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              values["CFBundleIdentifier"] as? String == "dev.zcode.app",
              values["CFBundleShortVersionString"] as? String == "3.17.2",
              let executable = values["CFBundleExecutable"] as? String,
              !executable.isEmpty, ![".", ".."].contains(executable),
              !executable.contains("/"), !executable.contains("\\"),
              !executable.contains("\0") else { throw unavailable() }
        let macOS = try opened(contents, "MacOS", directory: true); defer { close(macOS) }
        let binary = try opened(macOS, executable, directory: false); defer { close(binary) }
        let physical = try status(binary, directory: false)
        guard physical.st_mode & 0o111 != 0 else { throw unavailable() }
        let contentsURL = url.appendingPathComponent("Contents")
        let binaryURL = contentsURL.appendingPathComponent("MacOS").appendingPathComponent(executable)
        guard binaryURL.resolvingSymlinksInPath().path == binaryURL.path else { throw unavailable() }
        try sameCurrent(root, url, directory: true)
        try sameCurrent(contents, contentsURL, directory: true)
        try sameCurrent(plist, contentsURL.appendingPathComponent("Info.plist"), directory: false)
        try sameCurrent(macOS, contentsURL.appendingPathComponent("MacOS"), directory: true)
        try sameCurrent(binary, binaryURL, directory: false)
        return ZcodeAppObservation(app: ZcodeOwnerApp(bundleId: "dev.zcode.app", bundlePath: url.path,
            executablePath: binaryURL.path, device: UInt64(bitPattern: Int64(physical.st_dev)), inode: physical.st_ino), version: "3.17.2")
    }
}
