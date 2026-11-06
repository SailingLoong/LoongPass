import Cocoa
import FlutterMacOS
import Security
import Darwin

/// The only native desktop-session writer. Every explicit activation waits for
/// the official client to quit before accessing its fixed authentication directory.
@MainActor final class WorkBuddyDesktopBridge {
    private let bundleID = "com.tencent.workbuddy.mac"
    private var busy = false

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) -> Bool {
        guard call.method == "activateWorkBuddyDesktop" else { return false }
        guard !busy, let session = call.arguments as? [String: Any] else {
            result("unavailable"); return true
        }
        busy = true
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        Task { @MainActor [weak self] in
            guard let self else { result("unavailable"); return }
            defer { self.busy = false }
            do {
                try WorkBuddyDesktopTransaction.validateSession(session)
                let bundle = try self.installedClient()
                let journal = try AccountFile.named("WorkBuddy-switch")
                let root = try self.directory()
                guard ProcessInfo.processInfo.systemUptime < deadline else { result("expired"); return }
                try await self.stopClient(bundle)
                guard ProcessInfo.processInfo.systemUptime < deadline else { result("expired"); return }
                guard try self.installedClient().path == bundle.path else { throw WorkBuddyDesktopTransaction.Failure.sourceChanged }
                let transaction = WorkBuddyDesktopTransaction(root: root, journal: journal) {
                    guard try WorkBuddyProcesses.writers(in: bundle).isEmpty else { throw WorkBuddyDesktopTransaction.Failure.busy }
                }
                try transaction.apply(session)
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                let opened: Bool = await withCheckedContinuation { continuation in
                    NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { application, _ in
                        continuation.resume(returning: application != nil)
                    }
                }
                result(opened ? "opened" : "applied")
            } catch WorkBuddyDesktopTransaction.Failure.busy {
                result("busy")
            } catch WorkBuddyDesktopTransaction.Failure.recoveryRequired {
                result("recoveryRequired")
            } catch {
                result("unknown")
            }
        }
        return true
    }

    private func installedClient() throws -> URL {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
            Bundle(url: url)?.bundleIdentifier == bundleID else { throw WorkBuddyDesktopTransaction.Failure.unsafeFile }
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
            let code,
            SecRequirementCreateWithString(
                "anchor apple generic and identifier \"com.tencent.workbuddy.mac\" and certificate leaf[subject.OU] = \"FN2V63AD2J\"" as CFString,
                [], &requirement) == errSecSuccess,
            SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess else {
            throw WorkBuddyDesktopTransaction.Failure.unsafeFile
        }
        let product = url.appendingPathComponent("Contents/Resources/app.asar.unpacked/cli/product.json")
        let data = try Data(contentsOf: product)
        try WorkBuddyDesktopTransaction.validateProduct(data)
        return url.resolvingSymlinksInPath()
    }

    private func directory() throws -> URL {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { throw WorkBuddyDesktopTransaction.Failure.unsafeFile }
        return URL(fileURLWithPath: String(cString: home))
            .appendingPathComponent("Library/Application Support/CodeBuddyExtension/Data/Public/auth")
    }

    private func stopClient(_ bundle: URL) async throws {
        for application in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            guard application.bundleURL?.resolvingSymlinksInPath().path == bundle.path else {
                throw WorkBuddyDesktopTransaction.Failure.busy
            }
            let quit = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
                eventID: AEEventID(kAEQuitApplication),
                targetDescriptor: NSAppleEventDescriptor(processIdentifier: application.processIdentifier),
                returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            do { try quit.sendEvent(options: [.noReply, .canInteract], timeout: 12) }
            catch { throw WorkBuddyDesktopTransaction.Failure.busy }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while true {
            if try WorkBuddyProcesses.writers(in: bundle).isEmpty { return }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw WorkBuddyDesktopTransaction.Failure.busy }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

}
