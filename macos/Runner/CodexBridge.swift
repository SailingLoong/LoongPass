import Cocoa
import Darwin
import FlutterMacOS

/// App-lifetime account owner. Status reads only project this state; the page
/// never owns credential refresh, file observation, or authorization jobs.
@MainActor final class CodexBridge {
    private var accounts: CodexAccounts?
    private var file: AccountFile?
    private var authFile: CodexAuthFile?
    private var home: URL?
    private var watcher: DispatchSourceFileSystemObject?
    private var loginTask: Task<Void, Never>?
    private var initializationTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var loginServer: CodexAppServer?
    private var started = false, available = false, busy = false, loginPending = false, stopping = false
    private var issue = "unavailable"
    private var currentId: String?, message: String?, outcome: String?, observedAt: String?

    func start() {
        guard !started else { return }
        started = true; busy = true
        initializationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.busy = false }
            do {
                let file = try AccountFile.named("Codex")
                self.file = file; self.accounts = try CodexAccounts(file: file)
                guard let userHome = getpwuid(getuid())?.pointee.pw_dir else { throw CodexRuntimeFailure.unavailable }
                let configuredHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
                if let configuredHome, !configuredHome.hasPrefix("/") { throw CodexRuntimeFailure.unavailable }
                let home = configuredHome.map { URL(fileURLWithPath: $0) } ??
                    URL(fileURLWithPath: String(cString: userHome)).appendingPathComponent(".codex")
                guard home.path.hasPrefix("/"), home.resolvingSymlinksInPath().path == home.path else { throw CodexRuntimeFailure.unavailable }
                self.home = home; self.authFile = CodexAuthFile(root: home)
                let client = try CodexDesktopClient.installed()
                _ = try await self.policy(client)
                self.available = true; self.issue = ""
                try self.observeLive()
                try self.watch(home)
            } catch { self.report(error, unavailable: true) }
        }
    }

    private func snapshot() -> [String: Any] {
        var value: [String: Any] = [
            "available": available, "issue": issue,
            "accounts": accounts?.summaries(currentId: currentId) ?? [],
            "loginPending": loginPending, "busy": busy,
        ]
        if let currentId { value["currentId"] = currentId }
        if let message { value["message"] = message }
        if let outcome { value["outcome"] = outcome }
        if let observedAt { value["observedAt"] = observedAt }
        return value
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) -> Bool {
        let methods = ["codexAccountsStatus", "codexImportCurrent", "codexStartLogin", "codexCancelLogin", "codexActivate", "codexRemove"]
        guard methods.contains(call.method) else { return false }
        guard call.method != "codexAccountsStatus" else { result(snapshot()); return true }
        let args = call.arguments as? [String: Any] ?? [:]
        let id = args["id"] as? String
        guard ["codexActivate", "codexRemove"].contains(call.method) ?
            (args.count == 1 && id?.isEmpty == false && (id?.utf8.count ?? 0) <= 128) : args.isEmpty else {
            result(FlutterError(code: "codex_invalid_arguments", message: nil, details: nil)); return true
        }
        if call.method == "codexCancelLogin" {
            Task { @MainActor in
                self.loginTask?.cancel()
                await self.loginServer?.close()
                await self.loginTask?.value
                result(self.snapshot())
            }
            return true
        }
        guard available, !busy, !loginPending, !stopping else { result(snapshot()); return true }
        if call.method == "codexStartLogin" {
            loginPending = true; message = "正在打开 Codex 官方授权。"; outcome = nil
            loginTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.authorize()
            }
            result(snapshot()); return true
        }
        busy = true; outcome = nil; message = nil
        operationTask = Task { @MainActor in
            do {
                switch call.method {
                case "codexImportCurrent":
                    let client = try CodexDesktopClient.installed(), policy = try await self.policy(client)
                    guard let bytes = try self.authFile?.read(), let accounts = self.accounts else { throw CodexRuntimeFailure.loginFailed }
                    let credential = try CodexCredential(data: bytes)
                    try policy.validate(workspaceId: credential.workspaceId)
                    _ = try accounts.capture(bytes)
                    try self.observeLive()
                    self.message = "已保存本机 Codex 登录，项目和对话设置保持原样。"
                case "codexRemove":
                    try self.accounts?.remove(id: id!)
                    self.message = "已从 Pass 移除保存的账号，Codex 当前登录保持原样。"
                case "codexActivate": try await self.activate(id!)
                default: break
                }
            } catch { self.report(error) }
            self.busy = false
            self.reconcileObservation()
            self.operationTask = nil
            result(self.snapshot())
        }
        return true
    }

    func shutdown() async {
        stopping = true
        initializationTask?.cancel()
        loginTask?.cancel()
        await loginServer?.close()
        await loginTask?.value
        await initializationTask?.value
        await operationTask?.value
        watcher?.cancel(); watcher = nil
    }

    private func policy(_ client: CodexDesktopClient) async throws -> CodexAuthPolicy {
        guard let home else { throw CodexRuntimeFailure.unavailable }
        let server = CodexAppServer(executable: client.executable, home: home)
        do {
            try await server.start()
            let reply = try await server.request("config/read", params: ["includeLayers": false])
            guard let configuration = reply["config"] as? [String: Any] else { throw CodexRuntimeFailure.protocolError }
            let value = try CodexAuthPolicy(configuration)
            await server.close()
            return value
        } catch { await server.close(); throw error }
    }

    private func temporaryHome() throws -> URL {
        guard let file else { throw CodexRuntimeFailure.unavailable }
        var path = Array(file.root.appendingPathComponent("authorization-XXXXXX").path.utf8CString)
        guard let created = mkdtemp(&path) else { throw CodexRuntimeFailure.unavailable }
        return URL(fileURLWithPath: String(cString: created))
    }

    private func authorize() async {
        var server: CodexAppServer?, scratch: URL?
        do {
            try Task.checkCancellation()
            let client = try CodexDesktopClient.installed(), policy = try await self.policy(client)
            try Task.checkCancellation()
            let directory = try temporaryHome(); scratch = directory
            let child = CodexAppServer(executable: client.executable, home: directory, overrides: policy.loginOverrides)
            server = child; loginServer = child
            try await child.start()
            let login = try await child.request("account/login/start", params: ["type": "chatgpt"])
            guard let id = login["loginId"] as? String, let raw = login["authUrl"] as? String,
                let parts = URLComponents(string: raw), parts.scheme == "https",
                ["auth.openai.com", "chatgpt.com"].contains(parts.host ?? ""),
                parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443,
                let url = parts.url, NSWorkspace.shared.open(url) else { throw CodexRuntimeFailure.loginFailed }
            message = "请在浏览器中完成 Codex 官方授权；完成后会自动保存账号。"
            guard try await child.waitForLogin(id) else { throw CodexRuntimeFailure.loginFailed }
            try Task.checkCancellation()
            guard let bytes = try CodexAuthFile(root: directory).read(), let accounts else { throw CodexRuntimeFailure.loginFailed }
            let credential = try CodexCredential(data: bytes)
            try policy.validate(workspaceId: credential.workspaceId)
            _ = try accounts.capture(bytes)
            message = "已保存官方账号。点击切换后应用到 Codex，原项目和对话设置继续保留。"
        } catch { if Task.isCancelled { message = "已取消授权，Codex 当前登录保持原样。" } else { report(error) } }
        await server?.close()
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        loginPending = false; loginServer = nil; loginTask = nil
        reconcileObservation()
    }

    private func renew(_ credential: CodexCredential, client: CodexDesktopClient, policy: CodexAuthPolicy) async throws {
        let scratch = try temporaryHome()
        let server = CodexAppServer(executable: client.executable, home: scratch, overrides: policy.loginOverrides)
        do {
            let path = scratch.appendingPathComponent("auth.json")
            try credential.data.write(to: path, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            try await server.start()
            let reply = try await server.request("account/read", params: ["refreshToken": true])
            guard let account = reply["account"] as? [String: Any], account["type"] as? String == "chatgpt",
                let bytes = try CodexAuthFile(root: scratch).read() else { throw CodexRuntimeFailure.loginFailed }
            let fresh = try CodexCredential(data: bytes)
            guard fresh.id == credential.id else { throw CodexRuntimeFailure.loginFailed }
            try policy.validate(workspaceId: fresh.workspaceId)
            _ = try accounts?.capture(bytes)
            await server.close()
            try FileManager.default.removeItem(at: scratch)
        } catch {
            await server.close()
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
    }

    private func activate(_ id: String) async throws {
        guard let accounts, let authFile else { throw CodexRuntimeFailure.unavailable }
        let client = try CodexDesktopClient.installed(), policy = try await self.policy(client)
        try observeLive()
        let target = try accounts.credential(id: id)
        try policy.validate(workspaceId: target.workspaceId)
        if currentId != id { try await renew(target, client: client, policy: policy) }
        outcome = try await CodexActivation.run(workspaceId: target.workspaceId, quit: client.quit, policy: {
            let current = try CodexDesktopClient.installed()
            guard current.bundle == client.bundle else { throw CodexRuntimeFailure.unavailable }
            return try await self.policy(current)
        }, apply: {
            try accounts.activate(id: id, authFile: authFile, ensureStopped: client.ensureStopped)
        }, reopen: client.reopen)
        message = outcome == "opened" ? "已应用账号登录并重开 Codex，请核对客户端账号。项目和对话设置保留。" :
            "已应用账号登录，请打开 Codex 并核对账号。项目和对话设置保留。"
    }

    private func observeLive() throws {
        guard let authFile, let accounts else { throw CodexRuntimeFailure.unavailable }
        let data = try authFile.read()
        currentId = data.flatMap { try? CodexCredential(data: $0).id }
        if currentId != nil { try accounts.observe(data) }
        observedAt = ISO8601DateFormatter().string(from: Date())
    }

    private func reconcileObservation() {
        guard available, !stopping else { return }
        do { try observeLive() }
        catch { currentId = nil; report(error) }
    }

    private func watch(_ root: URL) throws {
        let fd = open(root.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CodexRuntimeFailure.unavailable }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
            eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, !self.busy, !self.loginPending, self.available else { return }
            do { try self.observeLive() } catch { self.report(error) }
        }
        source.setCancelHandler { close(fd) }
        watcher = source; source.resume()
    }

    private func report(_ error: Error, unavailable: Bool = false) {
        if unavailable { available = false }
        if let runtime = error as? CodexRuntimeFailure {
            switch runtime {
            case .unsupportedStore:
                available = false
                issue = "unsupportedStore"; message = "当前 Codex 使用的凭据存储暂不支持，Pass 没有修改它的设置。"
            case .restricted:
                issue = "restricted"; message = "此账号不符合 Codex 的登录方式或工作区限制，登录保持原样。"
            case .busy:
                message = "请先结束其他 Codex 命令行任务，并让桌面客户端正常退出后重试。"
            case .timeout:
                message = "Codex 操作超时，请稍后重试。"
            case .cancelled:
                message = "已取消本次 Codex 操作。"
            case .loginFailed:
                message = "Codex 登录未完成或授权需要更新，请重新通过官方窗口授权。"
            default:
                issue = "runtimeUnavailable"; message = "无法连接已安装的官方 Codex，请更新或重新打开官方客户端后重启 Pass。"
            }
        } else {
            if let failure = error as? CodexFailure, failure == .settingsUnavailable {
                message = "无法安全确认 Codex 的本机设置，未切换账号。请保留现有数据并核对客户端版本与当前登录。"
            } else if let failure = error as? CodexFailure, failure == .recoveryConflict {
                message = "上次切换的登录或本机设置存在冲突，已保留恢复记录；请先核对现有数据。"
            } else {
                message = "未能完成账号操作，请保留现有登录记录，核对文件访问和其他运行中的 Codex 后重试。"
            }
        }
        outcome = nil
    }
}
