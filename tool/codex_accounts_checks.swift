import Foundation
import Darwin

private enum CheckFailure: Error { case failed(String) }

private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw CheckFailure.failed(message) }
}

private func rejects(_ failure: CodexFailure, _ action: () throws -> Void) throws {
    do { try action() } catch let error as CodexFailure {
        try check(error == failure, "unexpected sanitized failure")
        return
    }
    throw CheckFailure.failed("unsafe operation was accepted")
}

private func token(_ claims: [String: Any]) throws -> String {
    let payload = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
        .base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "eyJhbGciOiJSUzI1NiJ9.\(payload).synthetic-signature"
}

private func login(user: String = "user-a", workspace: String = "workspace-a",
                  email: String = "alice@example.invalid", rotation: String = "first",
                  accessUser: String? = nil, accessWorkspace: String? = nil) throws -> Data {
    let namespace = "https://api.openai.com/auth"
    let id = try token(["sub": "oauth-subject-\(user)", "email": email, namespace: [
        "chatgpt_user_id": user, "user_id": user, "chatgpt_account_id": workspace,
        "chatgpt_plan_type": "plus",
    ]])
    let access = try token(["sub": "oauth-subject-\(user)", namespace: [
        "chatgpt_user_id": accessUser ?? user, "user_id": accessUser ?? user,
        "chatgpt_account_id": accessWorkspace ?? workspace, "chatgpt_plan_type": "plus",
        "chatgpt_account_user_id": "membership-\(user)-\(workspace)",
    ]])
    let document: [String: Any] = [
        "auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(),
        "tokens": ["id_token": id, "access_token": access,
                   "refresh_token": "synthetic-refresh-\(rotation)", "account_id": workspace,
                   "oauth_provenance": "synthetic-official-flow", "login_owner_id": "owner-\(user)"],
        "last_refresh": "2026-11-07T00:00:00Z",
        "future_auth_field": ["keep": ["exact bytes", rotation], "enabled": true],
    ]
    var data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    data.append(contentsOf: [10, 10])
    return data
}

private final class Fixture {
    let root: URL
    let home: URL
    var file: AccountFile?
    var auth: URL { home.appendingPathComponent("auth.json") }

    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("loongpass-codex-checks-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("codex", isDirectory: true)
        let store = root.appendingPathComponent("saved", isDirectory: true)
        for directory in [root, home, store] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        file = try AccountFile(root: store)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func writeAuth(_ data: Data) throws {
        try data.write(to: auth, options: [.atomic])
        guard chmod(auth.path, 0o600) == 0 else { throw CheckFailure.failed("fixture permissions") }
    }

    func accounts() throws -> CodexAccounts {
        guard let file else { throw CheckFailure.failed("fixture store is closed") }
        return try CodexAccounts(file: file)
    }
    func authFile() -> CodexAuthFile { CodexAuthFile(root: home) }
}

@main
struct CodexAccountsChecks {
    static func credentialChecks() throws {
        let data = try login()
        let first = try CodexCredential(data: data)
        try check(first.data == data, "credential bytes were normalized")
        try check(first.userId == "user-a" && first.workspaceId == "workspace-a", "incorrect official identity")
        try check(first.email == "alice@example.invalid" && first.plan == "plus", "incorrect account projection")
        try check(first.id == CodexCredential(data: login(rotation: "renewed")).id, "renewal changed account identity")
        try check(first.id != CodexCredential(data: login(workspace: "workspace-b")).id, "workspaces were collapsed")
        try check(first.id != CodexCredential(data: login(user: "user-b")).id, "same-email users were collapsed")
        try rejects(.invalidCredential) { _ = try CodexCredential(data: login(accessUser: "different-user")) }
        try rejects(.invalidCredential) { _ = try CodexCredential(data: login(accessWorkspace: "different-workspace")) }
        var apiKey = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        apiKey["OPENAI_API_KEY"] = "synthetic-api-key"
        try rejects(.invalidCredential) { _ = try CodexCredential(data: JSONSerialization.data(withJSONObject: apiKey)) }
        var mismatch = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var tokens = mismatch["tokens"] as! [String: Any]
        tokens["account_id"] = "another-workspace"
        mismatch["tokens"] = tokens
        try rejects(.invalidCredential) { _ = try CodexCredential(data: JSONSerialization.data(withJSONObject: mismatch)) }
        try rejects(.invalidCredential) { _ = try CodexCredential(data: Data("{}".utf8)) }
    }

    static func storageChecks() throws {
        let fixture = try Fixture(), accounts = try fixture.accounts()
        let a = try accounts.capture(login())
        let rotated = try login(rotation: "renewed")
        try check(try accounts.capture(rotated) == a, "duplicate identity created another account")
        let otherWorkspace = try accounts.capture(login(workspace: "workspace-b"))
        let otherUser = try accounts.capture(login(user: "user-b"))
        try check(Set([a, otherWorkspace, otherUser]).count == 3, "saved identities were collapsed")
        let summary = accounts.summaries(currentId: a)
        try check(summary.count == 3 && summary.filter { $0["isCurrent"] as? Bool == true }.count == 1,
                  "current authentication projection")
        let projected = try JSONSerialization.data(withJSONObject: summary)
        try check(!String(decoding: projected, as: UTF8.self).contains("synthetic-refresh"), "projection leaked authentication")
        try check(try fixture.accounts().credential(id: a).data == rotated, "saved rotation was not durable")
        let observed = try login(rotation: "observed")
        try accounts.observe(observed)
        try accounts.observe(nil)
        try accounts.observe(login(user: "unknown-user", workspace: "unknown-workspace"))
        try check(accounts.summaries(currentId: nil).count == 3, "observation imported an unknown account")
        try check(try fixture.accounts().credential(id: a).data == observed, "observation did not persist known renewal")
        try accounts.remove(id: otherWorkspace)
        try rejects(.accountNotFound) { _ = try fixture.accounts().credential(id: otherWorkspace) }
        try rejects(.accountNotFound) { try accounts.remove(id: "missing") }
    }

    static func switchChecks() throws {
        let fixture = try Fixture(), accounts = try fixture.accounts()
        let aData = try login(), bData = try login(user: "user-b", workspace: "workspace-b", email: "bob@example.invalid")
        let a = try accounts.capture(aData), b = try accounts.capture(bData)
        let settings: [String: Data] = [
            "config.toml": Data("model = \"gpt-synthetic\"\n[projects.\"/synthetic/project\"]\ntrust_level = \"trusted\"\n".utf8),
            "desktop-preferences.json": Data("{ \"theme\": \"dark\", \"pinned\": [\"project-a\"] }\n".utf8),
            "projects.json": Data("[\"project-a\",\"project-b\"]\n".utf8),
            "state_5.sqlite": Data([0, 1, 2, 3, 255, 9, 10]),
            "thread.jsonl": Data("{\"thread\":\"synthetic-conversation\",\"messages\":[1,2,3]}\n".utf8),
        ]
        for (name, data) in settings { try data.write(to: fixture.home.appendingPathComponent(name)) }
        let freshA = try login(rotation: "fresh-outgoing-a")
        try fixture.writeAuth(freshA)
        let originalNames = try FileManager.default.contentsOfDirectory(atPath: fixture.home.path).sorted()
        try accounts.activate(id: b, authFile: fixture.authFile(), ensureStopped: {})
        try check(try fixture.authFile().read() == bData, "B authentication was not applied exactly")
        try check(try fixture.accounts().credential(id: a).data == freshA, "latest outgoing A renewal was lost")
        let freshB = try login(user: "user-b", workspace: "workspace-b", email: "bob@example.invalid", rotation: "fresh-outgoing-b")
        try fixture.writeAuth(freshB)
        try accounts.activate(id: a, authFile: fixture.authFile(), ensureStopped: {})
        try check(try fixture.authFile().read() == freshA, "A return restored stale credentials")
        try check(try fixture.accounts().credential(id: b).data == freshB, "latest outgoing B renewal was lost")
        for (name, data) in settings {
            try check(try Data(contentsOf: fixture.home.appendingPathComponent(name)) == data, "unrelated Codex state changed")
        }
        try check(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path).sorted() == originalNames,
                  "authentication staging left files in the Codex home")
        let permissions = try FileManager.default.attributesOfItem(atPath: fixture.auth.path)[.posixPermissions] as? NSNumber
        try check(permissions?.intValue == 0o600, "authentication file is not private")
        try accounts.remove(id: a)
        try check(try fixture.authFile().read() == freshA, "removing a saved account logged the client out")

        let empty = try Fixture(), emptyAccounts = try empty.accounts()
        let target = try emptyAccounts.capture(bData)
        try emptyAccounts.activate(id: target, authFile: empty.authFile(), ensureStopped: {})
        try check(try empty.authFile().read() == bData, "first authentication activation failed")
        try empty.writeAuth(freshB)
        try emptyAccounts.activate(id: target, authFile: empty.authFile(), ensureStopped: {})
        try check(try empty.authFile().read() == freshB, "same-account activation restored a stale saved token")
    }

    static func writerAndSourceChecks() throws {
        let fixture = try Fixture(), accounts = try fixture.accounts()
        let aData = try login(), bData = try login(user: "user-b", workspace: "workspace-b")
        let b = try accounts.capture(bData)
        try fixture.writeAuth(aData)
        try rejects(.busy) { try accounts.activate(id: b, authFile: fixture.authFile(), ensureStopped: { throw CodexFailure.busy }) }
        try check(try fixture.authFile().read() == aData, "an active writer was overwritten")
        try check(accounts.summaries(currentId: nil).count == 1, "failed writer check imported outgoing state")
        let rootFD = open(fixture.home.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { throw CheckFailure.failed("fixture root lock") }
        guard flock(rootFD, LOCK_EX | LOCK_NB) == 0 else { close(rootFD); throw CheckFailure.failed("fixture lock") }
        try rejects(.busy) { try accounts.activate(id: b, authFile: fixture.authFile(), ensureStopped: {}) }
        flock(rootFD, LOCK_UN); close(rootFD)
        var calls = 0
        let changed = try login(rotation: "external-renewal")
        try rejects(.sourceChanged) {
            try accounts.activate(id: b, authFile: fixture.authFile()) {
                calls += 1
                if calls == 2 { try fixture.writeAuth(changed) }
            }
        }
        try check(calls >= 2, "writer state was not rechecked before replacement")
        try check(try fixture.authFile().read() == changed, "changed source authentication was overwritten")
        try rejects(.recoveryConflict) { try fixture.accounts().activate(id: b, authFile: fixture.authFile(), ensureStopped: {}) }
        try check(try fixture.authFile().read() == changed, "conflicting recovery restored stale authentication")

        let replaced = try Fixture(), replacedAccounts = try replaced.accounts()
        let target = try replacedAccounts.capture(bData)
        try replaced.writeAuth(aData)
        var checks = 0
        try rejects(.sourceChanged) {
            try replacedAccounts.activate(id: target, authFile: replaced.authFile()) {
                checks += 1
                if checks == 2 {
                    try FileManager.default.moveItem(at: replaced.home, to: replaced.root.appendingPathComponent("original-home"))
                    try FileManager.default.createDirectory(at: replaced.home, withIntermediateDirectories: false,
                                                            attributes: [.posixPermissions: 0o700])
                    try replaced.writeAuth(changed)
                }
            }
        }
        try check(try Data(contentsOf: replaced.auth) == changed, "replacement root was modified")

        let staged = try Fixture(), stagedAccounts = try staged.accounts()
        let stagedTarget = try stagedAccounts.capture(bData)
        try staged.writeAuth(aData)
        var stageChecks = 0
        try rejects(.sourceChanged) {
            try stagedAccounts.activate(id: stagedTarget, authFile: staged.authFile()) {
                stageChecks += 1
                if stageChecks == 2 {
                    let name = try FileManager.default.contentsOfDirectory(atPath: staged.home.path)
                        .first { $0.hasPrefix(".loongpass-auth-") }
                    guard let name else { throw CheckFailure.failed("fixture stage was not created") }
                    let writer = try FileHandle(forWritingTo: staged.home.appendingPathComponent(name))
                    try writer.truncate(atOffset: 0)
                    try writer.write(contentsOf: Data("unrecognized stage bytes".utf8))
                    try writer.synchronize(); try writer.close()
                }
            }
        }
        try check(try staged.authFile().read() == aData, "modified credential stage replaced live authentication")
    }

    static func unsafePathChecks() throws {
        let fixture = try Fixture(), accounts = try fixture.accounts()
        let data = try login(), target = try accounts.capture(data)
        let external = fixture.root.appendingPathComponent("external.json")
        try data.write(to: external); chmod(external.path, 0o600)
        guard symlink(external.path, fixture.auth.path) == 0 else { throw CheckFailure.failed("fixture link") }
        try rejects(.unsafePath) { _ = try fixture.authFile().read() }
        try rejects(.unsafePath) { try accounts.activate(id: target, authFile: fixture.authFile(), ensureStopped: {}) }
        try check(try Data(contentsOf: external) == data, "symlink destination changed")
        try FileManager.default.removeItem(at: fixture.auth)
        guard link(external.path, fixture.auth.path) == 0 else { throw CheckFailure.failed("fixture hard link") }
        try rejects(.unsafePath) { _ = try fixture.authFile().read() }
        try FileManager.default.removeItem(at: fixture.auth)
        try fixture.writeAuth(data)
        chmod(fixture.auth.path, 0o644)
        try rejects(.unsafePath) { _ = try fixture.authFile().read() }
        chmod(fixture.auth.path, 0o600)
        let alias = fixture.root.appendingPathComponent("home-alias")
        guard symlink(fixture.home.path, alias.path) == 0 else { throw CheckFailure.failed("fixture directory link") }
        try rejects(.unsafePath) { _ = try CodexAuthFile(root: alias).read() }
        chmod(fixture.home.path, 0o777)
        try rejects(.unsafePath) { _ = try fixture.authFile().read() }
        chmod(fixture.home.path, 0o700)
        try FileManager.default.removeItem(at: fixture.auth)
        guard mkfifo(fixture.auth.path, 0o600) == 0 else { throw CheckFailure.failed("fixture pipe") }
        try rejects(.unsafePath) { _ = try fixture.authFile().read() }
    }

    static func recoveryChecks() throws {
        let aData = try login(), bData = try login(user: "user-b", workspace: "workspace-b")
        for reachedTarget in [false, true] {
            let fixture = try Fixture(), accounts = try fixture.accounts()
            let a = try accounts.capture(aData), b = try accounts.capture(bData)
            try fixture.writeAuth(aData)
            var checks = 0
            try rejects(.busy) {
                try accounts.activate(id: b, authFile: fixture.authFile()) {
                    checks += 1
                    if checks == 2 { throw CodexFailure.busy }
                }
            }
            try check(checks == 2, "interruption did not reach the prepared transaction")
            // A process may stop immediately before or after the atomic rename.
            if reachedTarget { try fixture.writeAuth(bData) }
            let resumed = try fixture.accounts()
            try resumed.activate(id: reachedTarget ? b : a, authFile: fixture.authFile(), ensureStopped: {})
            try check(try fixture.authFile().read() == (reachedTarget ? bData : aData), "recognized recovery restored a stale source")
            try check(try fixture.accounts().credential(id: a).data == aData, "prepared transaction lost outgoing login")
        }
    }

    private static func prepareCrash(_ fixture: Fixture) throws -> String {
        let accounts = try fixture.accounts()
        _ = try accounts.capture(login())
        let target = try accounts.capture(login(user: "user-b", workspace: "workspace-b"))
        try fixture.writeAuth(login())
        return target
    }

    static func crashedProcessChecks() throws {
        let fixture = try Fixture(), target = try prepareCrash(fixture)
        fixture.file = nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--interrupt-activation", fixture.root.path, target]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        try check(process.terminationStatus == 91, "owned interruption process did not reach the durable boundary")
        fixture.file = try AccountFile(root: fixture.root.appendingPathComponent("saved"))
        let resumed = try fixture.accounts()
        try resumed.activate(id: target, authFile: fixture.authFile(), ensureStopped: {})
        try check(try fixture.authFile().read() == login(user: "user-b", workspace: "workspace-b"), "crashed activation did not recover")
        try check(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path) == ["auth.json"],
                  "crashed activation left a private credential staging file")
    }

    static func interruptActivation() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let accounts = try CodexAccounts(file: AccountFile(root: root.appendingPathComponent("saved")))
        var checks = 0
        try accounts.activate(id: CommandLine.arguments[3], authFile: CodexAuthFile(root: root.appendingPathComponent("codex"))) {
            checks += 1
            if checks == 2 { _exit(91) }
        }
        throw CheckFailure.failed("interruption boundary was not reached")
    }

    static func main() {
        do {
            if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--interrupt-activation" {
                try interruptActivation()
                return
            }
            try credentialChecks()
            try storageChecks()
            try switchChecks()
            try writerAndSourceChecks()
            try unsafePathChecks()
            try recoveryChecks()
            try crashedProcessChecks()
            print("PASS Codex identities, durable renewals, auth-only A/B/A, unsafe paths, writers, changed source and crash recovery")
        } catch {
            // The check messages contain fixture labels only, never authentication data.
            if case CheckFailure.failed(let message) = error { print("FAIL \(message)") }
            else { print("FAIL Codex checks") }
            exit(1)
        }
    }
}
