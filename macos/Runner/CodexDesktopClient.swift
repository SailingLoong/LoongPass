import Cocoa
import Security

/// Locates the signed official package and requests a normal application exit.
/// Process observation is shared with the other native desktop adapters.
struct CodexDesktopClient {
    static let bundleID = "com.openai.codex"
    let bundle: URL
    let executable: URL

    @MainActor static func installed() throws -> CodexDesktopClient {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
            Bundle(url: url)?.bundleIdentifier == bundleID,
            let resources = Bundle(url: url)?.resourceURL else { throw CodexRuntimeFailure.unavailable }
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
            SecRequirementCreateWithString(
                "anchor apple generic and identifier \"com.openai.codex\" and certificate leaf[subject.OU] = \"2DC432GLL2\"" as CFString,
                [], &requirement) == errSecSuccess,
            SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess else {
            throw CodexRuntimeFailure.unavailable
        }
        let package = resources.appendingPathComponent("codex-cli")
        let manifest = try Data(contentsOf: package.appendingPathComponent("codex-package.json"))
        let executable = try CodexExecutable.resolve(manifest: manifest, package: package)
        return CodexDesktopClient(bundle: url.resolvingSymlinksInPath(), executable: executable)
    }

    static func isWriter(_ command: DesktopClientProcesses.Command, bundle: URL) -> Bool {
        if command.executable.hasPrefix(bundle.path + "/") { return true }
        if URL(fileURLWithPath: command.executable).lastPathComponent.lowercased() == "codex" { return true }
        return command.arguments.contains { argument in
            argument.contains(bundle.path + "/") || argument.hasSuffix("/@openai/codex/bin/codex.js")
        }
    }

    func ensureStopped() throws {
        guard try DesktopClientProcesses.writers(matching: { Self.isWriter($0, bundle: bundle) }).isEmpty else {
            throw CodexRuntimeFailure.busy
        }
    }

    @MainActor func quit() async throws -> Bool {
        // A separate CLI must never be killed or silently switched underneath.
        guard try DesktopClientProcesses.writers(matching: {
            Self.isWriter($0, bundle: bundle) && !$0.executable.hasPrefix(bundle.path + "/") &&
                !$0.arguments.contains(where: { $0.contains(bundle.path + "/") })
        }).isEmpty else { throw CodexRuntimeFailure.busy }
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
        for application in applications {
            guard application.bundleURL?.resolvingSymlinksInPath() == bundle else { throw CodexRuntimeFailure.busy }
            let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
                targetDescriptor: NSAppleEventDescriptor(processIdentifier: application.processIdentifier),
                returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            do { try event.sendEvent(options: [.noReply, .canInteract], timeout: 3) }
            catch { throw CodexRuntimeFailure.busy }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while true {
            if (try? ensureStopped()) != nil { return !applications.isEmpty }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CodexRuntimeFailure.busy }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    @MainActor func reopen() async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { application, _ in
                continuation.resume(returning: application != nil)
            }
        }
    }
}
