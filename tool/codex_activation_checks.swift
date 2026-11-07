import Foundation

@main struct CodexActivationChecks {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("loongpass-codex-activation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = root.appendingPathComponent("auth.json")
        let original = Data("original login".utf8), target = Data("target login".utf8)
        for changed in ["keyring", "workspace"] {
            try original.write(to: auth)
            var configuration: [String: Any] = ["cli_auth_credentials_store": "file"]
            var reopened = false
            do {
                _ = try await CodexActivation.run(workspaceId: "workspace-b", quit: {
                    if changed == "keyring" { configuration["cli_auth_credentials_store"] = "keyring" }
                    else { configuration["forced_chatgpt_workspace_id"] = "workspace-a" }
                    return true
                }, policy: { try CodexAuthPolicy(configuration) }, apply: { try target.write(to: auth) }, reopen: {
                    reopened = true; return true
                })
                preconditionFailure("Changed policy did not prevent activation")
            } catch CodexRuntimeFailure.unsupportedStore {} catch CodexRuntimeFailure.restricted {}
            let after = try Data(contentsOf: auth)
            precondition(after == original, "Authentication was replaced under incompatible policy")
            precondition(reopened, "Previously running desktop was not restored on refusal")
        }
        try original.write(to: auth)
        var opened = false
        let result = try await CodexActivation.run(workspaceId: "workspace-b", quit: { false }, policy: {
            try CodexAuthPolicy(["cli_auth_credentials_store": "file"])
        }, apply: { try target.write(to: auth) }, reopen: { opened = true; return true })
        let applied = try Data(contentsOf: auth)
        precondition(applied == target && result == "applied" && !opened)
        print("Codex activation checks passed: post-quit store/workspace policy, refusal preserves auth, prior desktop restored, stopped desktop stays stopped")
    }
}
