import Cocoa
import FlutterMacOS
import Security
import Darwin

/// The only native desktop-session writer. Directory access is granted by the
/// user's picker, and every activation waits for the official client to quit.
@MainActor final class WorkBuddyDesktopBridge {
    private let bundleID = "com.tencent.workbuddy.mac"
    private var busy = false

    func handle(_ call: FlutterMethodCall, window: NSWindow, result: @escaping FlutterResult) -> Bool {
        guard call.method == "activateWorkBuddyDesktop" else { return false }
        guard !busy, let session = call.arguments as? [String: Any] else {
            result("unavailable"); return true
        }
        busy = true
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        Task { @MainActor [weak self, weak window] in
            guard let self else { result("unavailable"); return }
            defer { self.busy = false }
            do {
                try WorkBuddyDesktopTransaction.validateSession(session)
                let bundle = try self.installedClient()
                let journal = try AccountFile.named("WorkBuddy-switch")
                guard let window,
                    let root = try await self.directory(window: window, journal: journal) else {
                    result("cancelled"); return
                }
                let scoped = root.startAccessingSecurityScopedResource()
                defer { if scoped { root.stopAccessingSecurityScopedResource() } }
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

    private func directory(window: NSWindow, journal: AccountFile) async throws -> URL? {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { throw WorkBuddyDesktopTransaction.Failure.unsafeFile }
        let expected = URL(fileURLWithPath: String(cString: home))
            .appendingPathComponent("Library/Application Support/CodeBuddyExtension/Data/Public/auth")
        if let saved = try journal.read(name: "directory.json"),
            let encoded = saved["bookmark"] as? String, let data = Data(base64Encoded: encoded) {
            var stale = false
            if let root = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                relativeTo: nil, bookmarkDataIsStale: &stale), !stale, root.path == expected.path {
                return root
            }
        }
        let panel = NSOpenPanel()
        panel.title = "允许切换 WorkBuddy 账号"
        panel.message = "选择 WorkBuddy 的 auth 文件夹。LoongPass 会请求客户端正常退出，保存可恢复的原授权，应用所选账号后重新打开客户端。"
        panel.directoryURL = expected
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        guard response == .OK, let root = panel.url else { return nil }
        guard root.path == expected.path, root.resolvingSymlinksInPath().path == expected.path else {
            throw WorkBuddyDesktopTransaction.Failure.unsafeFile
        }
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        let bookmark = try root.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        try journal.write(["bookmark": bookmark.base64EncodedString()], name: "directory.json")
        return root
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
