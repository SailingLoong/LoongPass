import Foundation
import Darwin

@main struct WorkBuddyDesktopChecks {
    static func check(_ value: Bool) { precondition(value) }
    static func main() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("loongpass-desktop-checks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let native = base.appendingPathComponent("official"), own = base.appendingPathComponent("journal")
        for folder in [native, own] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                attributes: [.posixPermissions: folder == native ? 0o755 : 0o700])
        }
        let journal = try AccountFile(root: own)
        let file = native.appendingPathComponent("workbuddy-desktop.info")
        let marker = native.appendingPathComponent("workbuddy-desktop.info.logged-out")
        let old: [String: Any] = ["account": ["uid": "synthetic-old"],
            "auth": ["accessToken": ["$wbEncrypted": 1]], "preference": "preserve"]
        let before = try JSONSerialization.data(withJSONObject: old, options: [.sortedKeys])
        try before.write(to: file)
        try Data("synthetic logout".utf8).write(to: marker)
        let profile: [String: Any] = ["uid": "synthetic-next", "type": "personal", "nickname": "Test"]
        let session: [String: Any] = ["account": profile, "auth": ["accessToken": "synthetic-access", "domain": "www.workbuddy.cn"],
            "accounts": [profile], "allAccounts": [profile]]
        var running = true, stopChecks = 0
        var rejectAt: Int?
        let transaction = WorkBuddyDesktopTransaction(root: native, journal: journal) {
            stopChecks += 1
            if running || stopChecks == rejectAt { throw WorkBuddyDesktopTransaction.Failure.busy }
        }
        do { try transaction.apply(session); preconditionFailure("Running writer accepted") }
        catch WorkBuddyDesktopTransaction.Failure.busy {}
        check(try Data(contentsOf: file) == before)
        running = false
        try transaction.apply(session)
        let applied = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        check((applied["account"] as? [String: Any])?["uid"] as? String == "synthetic-next")
        check(applied["preference"] as? String == "preserve")
        check(!FileManager.default.fileExists(atPath: marker.path))
        check((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        var saved = try journal.read(name: "desktop-switch.json")!
        check(saved["state"] as? String == "applied")
        check(Data(base64Encoded: saved["before"] as! String) == before)

        // Simulate interruption after native replacement and before the final
        // journal acknowledgement. Recovery restores the original pair first.
        saved["state"] = "prepared"
        try journal.write(saved, name: "desktop-switch.json")
        try transaction.apply(session)
        check(try journal.read(name: "desktop-switch.json")?["state"] as? String == "applied")

        // The logout marker's existence is meaningful even when it is empty.
        try before.write(to: file)
        try Data().write(to: marker)
        try transaction.apply(session)
        saved = try journal.read(name: "desktop-switch.json")!
        check(saved["marker"] as? String == "")
        saved["state"] = "prepared"
        try journal.write(saved, name: "desktop-switch.json")
        stopChecks = 0
        rejectAt = 4 // After recovery, before replacing the restored preimage.
        do { try transaction.apply(session); preconditionFailure("New writer accepted") }
        catch WorkBuddyDesktopTransaction.Failure.busy {}
        check(try Data(contentsOf: file) == before)
        check(try Data(contentsOf: marker).isEmpty)
        rejectAt = nil

        let lock = native.appendingPathComponent(".workbuddy-desktop.info.workbuddy.lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        do { try transaction.apply(session); preconditionFailure("Foreign lock accepted") }
        catch WorkBuddyDesktopTransaction.Failure.busy {}
        check(FileManager.default.fileExists(atPath: lock.path))
        try FileManager.default.removeItem(at: lock)

        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: own.appendingPathComponent("desktop-switch.json"))
        do { try transaction.apply(session); preconditionFailure("Symlink accepted") }
        catch WorkBuddyDesktopTransaction.Failure.unsafeFile {}
        print("PASS native session, source preservation, logout marker, stopped writers, recovery, 0600, foreign lock and symlink rejection")
    }
}
