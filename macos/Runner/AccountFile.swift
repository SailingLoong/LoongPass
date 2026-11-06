import Foundation
import Darwin

/// Plain JSON in an app-owned private directory. One lifetime writer per region.
/// Domain adapters own schemas and CAS; this primitive owns durable file I/O.
final class AccountFile {
    enum Failure: Error { case unavailable }
    let root: URL
    private let lockFD: Int32
    private static var stores: [String: AccountFile] = [:]
    private static let registryLock = NSLock()
    static let documentScopes: Set<String> = ["MiniMax-cn", "MiniMax-global", "TRAE-cn", "ZCode", "RewardChannels", "ModelService"]
    static func named(_ name: String) throws -> AccountFile {
        registryLock.lock(); defer { registryLock.unlock() }
        guard documentScopes.contains(name) || ["Qoder-cn", "Qoder-global", "WorkBuddy-switch"].contains(name) else { throw Failure.unavailable }
        if let existing = stores[name] { return existing }
        let support = try AppDataDirectory.applicationSupport()
        let app = support.appendingPathComponent("LoongPass", isDirectory: true)
        let root = app.appendingPathComponent(name, isDirectory: true)
        for directory in [app, root] {
            if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw Failure.unavailable }
            try validateDirectory(directory)
            let parentFD = open(directory.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parentFD >= 0 else { throw Failure.unavailable }
            let synced = fsync(parentFD)
            close(parentFD)
            guard synced == 0 else { throw Failure.unavailable }
        }
        let store = try AccountFile(root: root)
        stores[name] = store
        return store
    }
    init(root: URL) throws {
        try Self.validateDirectory(root)
        self.root = root
        let fd = open(root.appendingPathComponent("owner.lock").path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }
        do {
            try Self.validateFile(fd)
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure.unavailable }
        } catch { close(fd); throw error }
        lockFD = fd
    }
    deinit { flock(lockFD, LOCK_UN); close(lockFD) }
    private static func validateDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
            info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
            url.resolvingSymlinksInPath().path == url.path else { throw Failure.unavailable }
    }
    private static func validateFile(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
            info.st_size <= 5 * 1024 * 1024 else { throw Failure.unavailable }
    }
    private func path(_ name: String) throws -> URL {
        guard !name.isEmpty, !name.contains("/"), name.hasSuffix(".json") else { throw Failure.unavailable }
        try Self.validateDirectory(root)
        return root.appendingPathComponent(name)
    }
    func read(name: String) throws -> [String: Any]? {
        let url = try path(name)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw Failure.unavailable }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try Self.validateFile(fd)
        guard let data = try file.readToEnd(), data.count <= 5 * 1024 * 1024,
            let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.unavailable }
        return value
    }
    func write(_ value: [String: Any], name: String) throws {
        let url = try path(name)
        _ = try read(name: name) // Reject an existing link or foreign file.
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard data.count <= 5 * 1024 * 1024 else { throw Failure.unavailable }
        let stage = root.appendingPathComponent(".write-\(UUID().uuidString)")
        let fd = open(stage.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        try file.write(contentsOf: data)
        try file.synchronize()
        guard rename(stage.path, url.path) == 0 else { throw Failure.unavailable }
        try sync()
        guard try JSONSerialization.data(withJSONObject: read(name: name) ?? [:], options: [.sortedKeys]) == data else { throw Failure.unavailable }
    }
    func sync() throws {
        try Self.validateDirectory(root)
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw Failure.unavailable }
    }
}
