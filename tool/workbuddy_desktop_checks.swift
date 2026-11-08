import Foundation
import Darwin

@main struct WorkBuddyDesktopChecks {
    static func check(_ value: Bool) { precondition(value) }
    static func session() -> [String: Any] {
        let profile: [String: Any] = ["uid": "synthetic-next", "type": "personal", "nickname": "Test"]
        return ["account": profile, "auth": ["accessToken": "synthetic-access", "domain": "www.workbuddy.cn"],
            "accounts": [profile], "allAccounts": [profile]]
    }
    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--crash" {
            let base = URL(fileURLWithPath: CommandLine.arguments[2])
            let journal = try AccountFile(root: base.appendingPathComponent("journal"))
            var checks = 0
            let transaction = WorkBuddyDesktopTransaction(root: base.appendingPathComponent("official"), journal: journal) {
                checks += 1
                if checks == 3 { kill(getpid(), SIGKILL); _exit(77) }
            }
            try transaction.apply(session())
            preconditionFailure("Crash seam was not reached")
        }
        let product: [String: Any] = ["authentication": ["id": "workbuddy-desktop",
            "type": "account-scoped-external-link", "attributes": ["platform": "workbuddy"]]]
        try WorkBuddyDesktopTransaction.validateProduct(JSONSerialization.data(withJSONObject: product))
        var foreignProduct = product
        foreignProduct["applicationName"] = "foreign-client"
        do {
            try WorkBuddyDesktopTransaction.validateProduct(JSONSerialization.data(withJSONObject: foreignProduct))
            preconditionFailure("Foreign client product accepted")
        } catch WorkBuddyDesktopTransaction.Failure.unsafeFile {}
        let flat: [String: Any] = ["authentication": ["id": "workbuddy-desktop",
            "type": "account-scoped-external-link", "platform": "workbuddy"]]
        do {
            try WorkBuddyDesktopTransaction.validateProduct(JSONSerialization.data(withJSONObject: flat))
            preconditionFailure("Unsupported product shape accepted")
        } catch WorkBuddyDesktopTransaction.Failure.unsafeFile {}
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
        let session = session()
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

        // A separate process dies after the durable intent, bypassing defer.
        let crashRoot = base.appendingPathComponent("crashed")
        for name in ["official", "journal"] {
            try FileManager.default.createDirectory(at: crashRoot.appendingPathComponent(name),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--crash", crashRoot.path]
        try child.run()
        child.waitUntilExit()
        check(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL)
        let crashJournal = try AccountFile(root: crashRoot.appendingPathComponent("journal"))
        check(try crashJournal.read(name: "desktop-switch.json")?["state"] as? String == "prepared")
        let crashNative = crashRoot.appendingPathComponent("official")
        let orphan = crashNative.appendingPathComponent(".workbuddy-desktop.info.workbuddy.lock")
        check(FileManager.default.fileExists(atPath: orphan.path))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -11)], ofItemAtPath: orphan.path)
        try WorkBuddyDesktopTransaction(root: crashNative, journal: crashJournal, ensureStopped: {}).apply(session)
        check(!FileManager.default.fileExists(atPath: orphan.path))
        check(try crashJournal.read(name: "desktop-switch.json")?["state"] as? String == "applied")

        var leaseChecks = 0
        try WorkBuddyDesktopTransaction(root: native, journal: journal) {
            leaseChecks += 1
            if leaseChecks == 2 {
                let initial = try FileManager.default.attributesOfItem(atPath: lock.path)[.modificationDate] as! Date
                Thread.sleep(forTimeInterval: 6)
                let renewed = try FileManager.default.attributesOfItem(atPath: lock.path)[.modificationDate] as! Date
                check(renewed > initial) // The calling thread made no progress.
            }
        }.apply(session)
        let lastApplied = try Data(contentsOf: file)
        var replacementChecks = 0
        do {
            try WorkBuddyDesktopTransaction(root: native, journal: journal) {
                replacementChecks += 1
                if replacementChecks == 3 {
                    try FileManager.default.removeItem(at: lock)
                    try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
                }
            }.apply(session)
            preconditionFailure("Replaced lock accepted")
        } catch WorkBuddyDesktopTransaction.Failure.sourceChanged {}
        check(try Data(contentsOf: file) == lastApplied)
        check(FileManager.default.fileExists(atPath: lock.path))
        try FileManager.default.removeItem(at: lock)

        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: own.appendingPathComponent("desktop-switch.json"))
        do { try transaction.apply(session); preconditionFailure("Symlink accepted") }
        catch WorkBuddyDesktopTransaction.Failure.unsafeFile {}
        print("PASS official product shape, native session, logout marker, stopped writers, SIGKILL/stale-lock recovery, background renewal, replaced-lock refusal, 0600 and symlink rejection")
    }
}
