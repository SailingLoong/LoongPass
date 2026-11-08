import Foundation

/// Owns quit → effective-policy validation → commit → reopen ordering. The
/// injected boundaries keep checks from ever quitting a developer's real client.
enum CodexActivation {
    @MainActor static func run(workspaceId: String, quit: () async throws -> Bool,
        policy: () async throws -> CodexAuthPolicy, apply: () throws -> Void,
        reopen: () async -> Bool) async throws -> String {
        let wasRunning = try await quit()
        do {
            let effective = try await policy()
            try effective.validate(workspaceId: workspaceId)
            try apply()
            if wasRunning { return await reopen() ? "opened" : "applied" }
            return "applied"
        } catch {
            if wasRunning { _ = await reopen() }
            throw error
        }
    }
}
