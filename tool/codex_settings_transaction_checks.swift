import Foundation
import Darwin

@main struct CodexSettingsTransactionChecks {
    static func auth(_ user: String) throws -> Data {
        let claims: [String: Any] = ["email": "\(user)@example.invalid", "https://api.openai.com/auth": [
            "chatgpt_user_id": user, "user_id": user, "chatgpt_account_id": "workspace-\(user)"]]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let token = "header.\(payload).synthetic"
        return try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": [
            "id_token": token, "access_token": token, "refresh_token": "synthetic-\(user)", "account_id": "workspace-\(user)"]])
    }
    static func setup(_ root: URL) throws -> (Data, Data, Data) {
        for name in ["native", "saved"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let a = try auth("a"), b = try auth("b")
        let first = try CodexCredential(data: a), second = try CodexCredential(data: b)
        let state: [String: Any] = [
            "electron-account-renderer-state-v1": ["owner": first.rendererOwnerKey, "inactive": [second.rendererOwnerKey: [
                "atoms": ["chatgpt-sidebar-state-v2": "b-cloud", "composer-auto-context-enabled": false],
                "globals": ["local-projects": ["old-b-project"]]]]],
            "electron-persisted-atom-state": ["composer-auto-context-enabled": true, "chatgpt-sidebar-state-v2": "a-cloud"],
            "local-projects": ["project-a"], "selected-project": "project-a", "unrelated": ["preserve": true],
        ]
        let preferences = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
        try a.write(to: root.appendingPathComponent("native/auth.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("native/auth.json").path)
        let statePath = root.appendingPathComponent("native/.codex-global-state.json")
        try preferences.write(to: statePath)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: statePath.path)
        try Data("unchanged configuration".utf8).write(to: root.appendingPathComponent("native/config.toml"))
        try Data("unchanged conversations".utf8).write(to: root.appendingPathComponent("native/state_5.sqlite"))
        return (a, b, preferences)
    }
    static func owner(_ root: URL, a: Data, b: Data) throws -> CodexAccounts {
        let accounts = try CodexAccounts(file: AccountFile(root: root.appendingPathComponent("saved")))
        _ = try accounts.capture(a); _ = try accounts.capture(b)
        return accounts
    }
    static func run(_ root: URL) throws {
        let (a, b, original) = try setup(root)
        let accounts = try owner(root, a: a, b: b), target = try CodexCredential(data: b)
        let home = root.appendingPathComponent("native"), path = home.appendingPathComponent(".codex-global-state.json")
        var interrupted = false
        do {
            try accounts.activate(id: target.id, authFile: CodexAuthFile(root: home)) {
                if !interrupted, try Data(contentsOf: path) != original {
                    interrupted = true
                    throw CodexFailure.busy
                }
            }
            preconditionFailure("Writer restart was accepted")
        } catch CodexFailure.busy {}
        let restoredSettings = try Data(contentsOf: path), restoredAuth = try Data(contentsOf: home.appendingPathComponent("auth.json"))
        precondition(restoredSettings == original && restoredAuth == a, "Paired failure did not preserve the original environment")
        try accounts.activate(id: target.id, authFile: CodexAuthFile(root: home), ensureStopped: {})
        let applied = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        let metadata = applied["electron-account-renderer-state-v1"] as! [String: Any]
        let inactive = metadata["inactive"] as! [String: Any], destination = inactive[target.rendererOwnerKey] as! [String: Any]
        let globals = destination["globals"] as! [String: Any], atoms = destination["atoms"] as! [String: Any]
        precondition(globals["local-projects"] as? [String] == ["project-a"], "Target would restore different local projects")
        precondition(atoms["composer-auto-context-enabled"] as? Bool == true)
        precondition(atoms["chatgpt-sidebar-state-v2"] as? String == "b-cloud", "Account cloud cache was transferred")
        let configuration = try Data(contentsOf: home.appendingPathComponent("config.toml"))
        let conversations = try Data(contentsOf: home.appendingPathComponent("state_5.sqlite"))
        precondition(configuration == Data("unchanged configuration".utf8) && conversations == Data("unchanged conversations".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as! NSNumber
        precondition(mode.intValue == 0o644, "Settings permissions changed")
        // Codex may stay closed across several switches; its renderer owner
        // still denotes A even though the current authentication has advanced.
        try accounts.activate(id: target.id, authFile: CodexAuthFile(root: home), ensureStopped: {})
        let first = try CodexCredential(data: a)
        try accounts.activate(id: first.id, authFile: CodexAuthFile(root: home), ensureStopped: {})
        try accounts.activate(id: target.id, authFile: CodexAuthFile(root: home), ensureStopped: {})
        let c = try auth("c"), third = try CodexCredential(data: c)
        _ = try accounts.capture(c)
        try accounts.activate(id: third.id, authFile: CodexAuthFile(root: home), ensureStopped: {})
        let finalAuth = try Data(contentsOf: home.appendingPathComponent("auth.json"))
        precondition(finalAuth == c, "Repeated stopped-client switches did not apply the selected account")
        let beforeForeign = try Data(contentsOf: path)
        var foreign = try JSONSerialization.jsonObject(with: beforeForeign) as! [String: Any]
        var foreignMetadata = foreign["electron-account-renderer-state-v1"] as! [String: Any]
        foreignMetadata["owner"] = String(repeating: "f", count: 64)
        foreign["electron-account-renderer-state-v1"] = foreignMetadata
        let foreignData = try JSONSerialization.data(withJSONObject: foreign, options: [.sortedKeys])
        try foreignData.write(to: path)
        do {
            try accounts.activate(id: target.id, authFile: CodexAuthFile(root: home), ensureStopped: {})
            preconditionFailure("An unknown renderer owner was accepted")
        } catch CodexFailure.settingsUnavailable {}
        let rejectedAuth = try Data(contentsOf: home.appendingPathComponent("auth.json")), rejectedSettings = try Data(contentsOf: path)
        precondition(rejectedAuth == c && rejectedSettings == foreignData)
        try beforeForeign.write(to: path)
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--projected-fixture" {
            let output = try JSONSerialization.data(withJSONObject: ["state": applied, "userId": "b", "accountId": "workspace-b"])
            try output.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .withoutOverwriting)
        }
    }
    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--crash" {
            let root = URL(fileURLWithPath: CommandLine.arguments[2])
            let (a, b, original) = try setup(root)
            let accounts = try owner(root, a: a, b: b), target = try CodexCredential(data: b)
            try accounts.activate(id: target.id, authFile: CodexAuthFile(root: root.appendingPathComponent("native"))) {
                if try Data(contentsOf: root.appendingPathComponent("native/.codex-global-state.json")) != original {
                    kill(getpid(), SIGKILL); _exit(77)
                }
            }
            preconditionFailure("Paired crash boundary missing")
        }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("loongpass-settings-transaction-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try run(root)
        let crash = root.appendingPathComponent("crash")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--crash", crash.path]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run(); child.waitUntilExit()
        precondition(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL)
        let (_, _, original) = try setup(root.appendingPathComponent("reference"))
        let home = crash.appendingPathComponent("native"), settings = home.appendingPathComponent(".codex-global-state.json")
        let beforeAuth = try Data(contentsOf: home.appendingPathComponent("auth.json"))
        let accounts = try CodexAccounts(file: AccountFile(root: crash.appendingPathComponent("saved")))
        let target = try CodexCredential(data: auth("b"))
        var sawRestored = false, interrupted = false
        do {
            try accounts.activate(id: target.id, authFile: CodexAuthFile(root: home)) {
                let data = try Data(contentsOf: settings)
                if data == original { sawRestored = true }
                if sawRestored, !interrupted, data != original {
                    interrupted = true; throw CodexFailure.busy
                }
            }
            preconditionFailure("Recovery refused-writer boundary missing")
        } catch CodexFailure.busy {}
        let restored = try Data(contentsOf: settings), preservedAuth = try Data(contentsOf: home.appendingPathComponent("auth.json"))
        precondition(sawRestored && restored == original && preservedAuth == beforeAuth, "Interrupted paired switch did not recover exact source settings")
        print("PASS paired authentication/local-settings activation, exact refusal rollback, target local environment and account cache isolation")
    }
}
