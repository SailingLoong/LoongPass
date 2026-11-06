import AppKit
import Darwin

/// One storage location for every account and journal, independent of views.
enum AppDataDirectory {
    enum Failure: Error { case unavailable, busy, conflict }
    private static let lock = NSLock()
    private static var cached: URL?

    static func applicationSupport() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        guard let home = getpwuid(getuid())?.pointee.pw_dir,
              let bundleID = Bundle.main.bundleIdentifier else { throw Failure.unavailable }
        let user = URL(fileURLWithPath: String(cString: home), isDirectory: true)
        let support = user.appendingPathComponent("Library/Application Support", isDirectory: true)
        let legacy = user.appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Application Support/LoongPass", isDirectory: true)
        _ = try prepare(support: support, legacy: legacy) {
            guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .allSatisfy({ $0.processIdentifier == getpid() || $0.isTerminated }) else { throw Failure.busy }
        }
        cached = support
        return support
    }

    /// Move the complete old store, including claim journals and recovery data.
    /// No copy/merge fallback: refresh grants must never have two active stores.
    static func prepare(support: URL, legacy: URL, ensureIdle: () throws -> Void) throws -> URL {
        if try !exists(support) {
            guard mkdir(support.path, 0o700) == 0 else { throw Failure.unavailable }
            try synchronize(support.deletingLastPathComponent())
        }
        try validateDirectory(support, privateOnly: false)
        let migration = try exclusiveLock(support.appendingPathComponent(".LoongPass-migration.lock"))
        defer { close(migration) }
        let root = support.appendingPathComponent("LoongPass", isDirectory: true)
        let hasLegacy = try exists(legacy), hasRoot = try exists(root)
        guard !(hasLegacy && hasRoot) else { throw Failure.conflict }
        if hasLegacy {
            try validateDirectory(legacy)
            try ensureIdle()
            var owners: [Int32] = []
            defer { owners.forEach { close($0) } }
            for name in try FileManager.default.contentsOfDirectory(atPath: legacy.path) {
                let child = legacy.appendingPathComponent(name)
                var info = stat()
                guard lstat(child.path, &info) == 0 else { throw Failure.unavailable }
                if info.st_mode & S_IFMT == S_IFDIR {
                    try validateDirectory(child)
                    owners.append(try exclusiveLock(child.appendingPathComponent("owner.lock")))
                }
            }
            try ensureIdle()
            // RENAME_EXCL prevents a concurrent target from ever being replaced.
            guard renamex_np(legacy.path, root.path, UInt32(RENAME_EXCL)) == 0 else { throw Failure.unavailable }
            try synchronize(legacy.deletingLastPathComponent())
            try synchronize(support)
        } else if !hasRoot {
            guard mkdir(root.path, 0o700) == 0 else { throw Failure.unavailable }
            try synchronize(support)
        }
        try validateDirectory(root)
        return root
    }

    private static func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        guard errno == ENOENT else { throw Failure.unavailable }
        return false
    }

    private static func validateDirectory(_ url: URL, privateOnly: Bool = true) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), (!privateOnly || info.st_mode & 0o7777 == 0o700),
              url.resolvingSymlinksInPath().path == url.path else { throw Failure.unavailable }
    }

    private static func exclusiveLock(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o7777 == 0o600 else {
            close(fd); throw Failure.unavailable
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw Failure.busy }
        return fd
    }

    private static func synchronize(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw Failure.unavailable }
    }
}
