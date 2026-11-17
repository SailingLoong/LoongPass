import Foundation

/// The account owner supplies durable persistence; the session owns child I/O.
enum CodexRenewal {
    @MainActor static func run(executable: URL, home: URL, credential: CodexCredential,
        policy: CodexAuthPolicy, preserve: (Data) throws -> Void) async throws {
        let path = home.appendingPathComponent("auth.json")
        try credential.data.write(to: path, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let server = CodexAppServer(executable: executable, home: home, overrides: policy.loginOverrides)
        var failure: Error?
        do {
            try await server.start()
            let reply = try await server.request("account/read", params: ["refreshToken": true])
            guard let account = reply["account"] as? [String: Any], account["type"] as? String == "chatgpt" else {
                throw CodexRuntimeFailure.loginFailed
            }
        } catch { failure = error }
        await server.close()
        // A lost response or cancellation does not undo an upstream rotation.
        // Finalize persistence before deciding whether activation may proceed.
        guard let bytes = try CodexAuthFile(root: home).read() else { throw CodexRuntimeFailure.loginFailed }
        let final = try CodexCredential(data: bytes)
        guard final.id == credential.id else { throw CodexRuntimeFailure.loginFailed }
        try policy.validate(workspaceId: final.workspaceId)
        try preserve(bytes)
        if let failure { throw failure }
        try Task.checkCancellation()
    }
}
