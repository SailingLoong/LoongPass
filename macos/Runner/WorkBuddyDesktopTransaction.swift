import Foundation
import CryptoKit
import Darwin

/// Transaction for the official WorkBuddy session and logout marker. The host
/// owns user-selected directory access and stops all observed client writers.
final class WorkBuddyDesktopTransaction {
    enum Failure: Error {
        case invalidSession, unsafeFile, busy, sourceChanged, recoveryRequired, io
    }
    private let root: URL
    private let journal: AccountFile
    private let ensureStopped: () throws -> Void
    private let sessionName = "workbuddy-desktop.info"
    private let markerName = "workbuddy-desktop.info.logged-out"
    private let journalName = "desktop-switch.json"
    private let maximumBytes = 1_048_576
    private var lockFD: Int32 = -1

    private func refreshLock() throws {
        let lock = root.appendingPathComponent(".\(sessionName).workbuddy.lock")
        var held = stat(), named = stat()
        guard lockFD >= 0, fstat(lockFD, &held) == 0, lstat(lock.path, &named) == 0,
            held.st_dev == named.st_dev, held.st_ino == named.st_ino,
            named.st_mode & S_IFMT == S_IFDIR, named.st_uid == geteuid(),
            futimens(lockFD, nil) == 0 else { throw Failure.sourceChanged }
    }

    init(root: URL, journal: AccountFile, ensureStopped: @escaping () throws -> Void) {
        self.root = root
        self.journal = journal
        self.ensureStopped = ensureStopped
    }

    static func validateSession(_ value: [String: Any]) throws {
        guard let account = value["account"] as? [String: Any],
            let uid = account["uid"] as? String, !uid.isEmpty, uid.utf8.count <= 256,
            let type = account["type"] as? String, ["personal", "pro"].contains(type),
            account["isCurrentOneIdEnterprise"] as? Bool != true,
            let auth = value["auth"] as? [String: Any],
            let domain = auth["domain"] as? String,
            ["www.workbuddy.cn", "www.codebuddy.cn"].contains(domain),
            let token = auth["accessToken"] as? String, !token.isEmpty, token.utf8.count <= 16384,
            token.utf8.allSatisfy({ (33...126).contains($0) }),
            value.keys.sorted() == ["account", "accounts", "allAccounts", "auth"] else { throw Failure.invalidSession }
        for key in ["enterpriseId", "enterprise_id"] {
            if let enterprise = account[key], !(enterprise is NSNull), enterprise as? String != "" {
                throw Failure.invalidSession
            }
        }
        if let realm = account["domain"] as? String, realm != domain { throw Failure.invalidSession }
        if let expiry = auth["expiresAt"] {
            guard let milliseconds = expiry as? NSNumber, milliseconds.doubleValue.isFinite,
                milliseconds.doubleValue > Date().timeIntervalSince1970 * 1000 else { throw Failure.invalidSession }
        }
        let profile = try JSONSerialization.data(withJSONObject: account, options: [.sortedKeys])
        for key in ["accounts", "allAccounts"] {
            guard let rows = value[key] as? [[String: Any]], rows.count == 1,
                try JSONSerialization.data(withJSONObject: rows[0], options: [.sortedKeys]) == profile else {
                throw Failure.invalidSession
            }
        }
    }

    private func validateRoot() throws {
        var metadata = stat()
        guard root.isFileURL, root.resolvingSymlinksInPath().path == root.path,
            lstat(root.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
            metadata.st_uid == geteuid(), metadata.st_mode & 0o022 == 0 else { throw Failure.unsafeFile }
    }

    private func read(_ name: String) throws -> Data? {
        try validateRoot()
        let fd = open(root.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw Failure.unsafeFile }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
            before.st_uid == geteuid(), before.st_nlink == 1, before.st_mode & 0o022 == 0,
            before.st_size <= maximumBytes else { throw Failure.unsafeFile }
        let data = try file.readToEnd() ?? Data()
        guard data.count <= maximumBytes, data.count == before.st_size,
            fstat(fd, &after) == 0, before.st_size == after.st_size,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw Failure.unsafeFile }
        return data
    }

    private func syncDirectory() throws {
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.io }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw Failure.io }
    }

    private func write(_ data: Data?, name: String) throws {
        try validateRoot()
        try refreshLock()
        let destination = root.appendingPathComponent(name)
        guard let data else {
            if unlink(destination.path) != 0, errno != ENOENT { throw Failure.io }
            try syncDirectory()
            return
        }
        let temporary = root.appendingPathComponent(".loongpass-switch-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.io }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try file.write(contentsOf: data)
        try file.synchronize()
        guard rename(temporary.path, destination.path) == 0 else { throw Failure.io }
        try syncDirectory()
        guard try read(name) == data else { throw Failure.io }
    }

    private func digest(_ data: Data?) -> String {
        guard let data else { return "absent" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Called only while the installed client is quiescent. Cooperates with
    /// proper-lockfile's directory lock; an existing lock is never stolen.
    private func locked<T>(_ action: () throws -> T) throws -> T {
        guard lockFD < 0 else { throw Failure.busy }
        try validateRoot()
        try ensureStopped()
        let lock = root.appendingPathComponent(".\(sessionName).workbuddy.lock")
        guard mkdir(lock.path, 0o700) == 0 else { throw Failure.busy }
        lockFD = open(lock.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard lockFD >= 0 else { throw Failure.io }
        defer {
            if (try? refreshLock()) != nil { rmdir(lock.path) }
            close(lockFD)
            lockFD = -1
        }
        try ensureStopped()
        return try action()
    }

    private func recoverPrepared() throws {
        guard var pending = try journal.read(name: journalName), pending["state"] as? String == "prepared" else { return }
        guard pending["root"] as? String == root.path,
            let expected = pending["afterDigest"] as? String else { throw Failure.recoveryRequired }
        func original(_ name: String) throws -> Data? {
            if pending[name] is NSNull { return nil }
            guard let encoded = pending[name] as? String, let data = Data(base64Encoded: encoded) else { throw Failure.recoveryRequired }
            return data
        }
        let before = try original("before"), marker = try original("marker")
        let current = try read(sessionName), currentMarker = try read(markerName)
        guard current == before || digest(current) == expected,
            currentMarker == marker || currentMarker == nil else { throw Failure.recoveryRequired }
        try ensureStopped()
        try write(before, name: sessionName)
        try write(marker, name: markerName)
        pending["state"] = "recovered"
        try journal.write(pending, name: journalName)
    }

    func apply(_ session: [String: Any]) throws {
        try Self.validateSession(session)
        try locked {
            try recoverPrepared()
            let before = try read(sessionName), marker = try read(markerName)
            var document: [String: Any] = [:]
            if let before {
                guard let existing = try JSONSerialization.jsonObject(with: before) as? [String: Any],
                    existing["uid"] == nil, existing["domain"] == nil else { throw Failure.invalidSession }
                document = existing
            }
            session.forEach { document[$0.key] = $0.value }
            let after = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            guard after.count <= maximumBytes else { throw Failure.invalidSession }
            var pending: [String: Any] = ["state": "prepared", "root": root.path,
                "before": before.map { $0.base64EncodedString() as Any } ?? NSNull(),
                "marker": marker.map { $0.base64EncodedString() as Any } ?? NSNull(),
                "afterDigest": digest(after)]
            try journal.write(pending, name: journalName)
            try ensureStopped()
            guard try read(sessionName) == before, try read(markerName) == marker else { throw Failure.sourceChanged }
            try write(after, name: sessionName)
            try write(nil, name: markerName)
            pending["state"] = "applied"
            try journal.write(pending, name: journalName)
        }
    }
}
