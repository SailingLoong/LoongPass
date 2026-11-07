import Foundation
import Darwin

enum CodexRuntimeFailure: Error, CustomStringConvertible {
    case unavailable, timeout, cancelled, loginFailed, unsupportedStore, restricted, protocolError, busy
    var description: String { "Codex operation unavailable" }
}

/// Effective values come from Codex's TOML/policy loader, never a second parser.
struct CodexAuthPolicy {
    private let workspace: String?
    init(_ configuration: [String: Any]) throws {
        guard configuration["cli_auth_credentials_store"] as? String == "file" else {
            throw CodexRuntimeFailure.unsupportedStore
        }
        if let method = configuration["forced_login_method"] as? String, method != "chatgpt" {
            throw CodexRuntimeFailure.restricted
        }
        workspace = configuration["forced_chatgpt_workspace_id"] as? String
    }
    func validate(workspaceId: String) throws {
        if let workspace, workspace != workspaceId { throw CodexRuntimeFailure.restricted }
    }
    var loginOverrides: [String] {
        var values = ["cli_auth_credentials_store=\"file\"", "forced_login_method=\"chatgpt\""]
        if let workspace, let encoded = try? JSONEncoder().encode(workspace), let value = String(data: encoded, encoding: .utf8) {
            values.append("forced_chatgpt_workspace_id=" + value)
        }
        return values
    }
}

enum CodexExecutable {
    static func resolve(manifest: Data, package: URL) throws -> URL {
        guard manifest.count <= 65_536,
            let value = try JSONSerialization.jsonObject(with: manifest) as? [String: Any],
            let entry = value["entrypoint"] as? String, !entry.isEmpty,
            !entry.hasPrefix("/"), !entry.contains("\\"),
            entry.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CodexRuntimeFailure.unavailable
        }
        let executable = package.appendingPathComponent(entry)
        guard executable.resolvingSymlinksInPath().path == executable.path,
            FileManager.default.isExecutableFile(atPath: executable.path) else { throw CodexRuntimeFailure.unavailable }
        return executable
    }
}

/// A private stdio child of the signed official client. It is never connected to
/// the running desktop's internal transport, and never logs RPC payloads.
@MainActor final class CodexAppServer {
    private struct Pending {
        let continuation: CheckedContinuation<[String: Any], Error>
        let timeout: Task<Void, Never>
    }
    private let executable: URL, home: URL
    private let timeout: TimeInterval
    private let overrides: [String]
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: Pending] = [:]
    private var completedLogins: [String: Bool] = [:]
    private var login: (String, CheckedContinuation<Bool, Error>, Task<Void, Never>)?
    private var closed = false
    private var closeCompleted = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    init(executable: URL, home: URL, timeout: TimeInterval = 20, overrides: [String] = []) {
        self.executable = executable; self.home = home; self.timeout = timeout; self.overrides = overrides
    }

    func start() async throws {
        guard process == nil, !closed else { throw CodexRuntimeFailure.unavailable }
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = executable
        child.arguments = overrides.flatMap { ["-c", $0] } + ["app-server"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        for name in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN"] { environment.removeValue(forKey: name) }
        child.environment = environment
        child.currentDirectoryURL = home
        child.standardInput = stdin; child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.receive(data) }
        }
        child.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.failAll(CodexRuntimeFailure.unavailable) }
        }
        process = child
        do {
            try child.run()
            _ = try await request("initialize", params: [
                "clientInfo": ["name": "loongpass", "version": "1.0.0"], "capabilities": [:],
            ])
            try send(["method": "initialized"])
        } catch {
            await close()
            throw error
        }
    }

    func request(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        guard !closed, process?.isRunning == true else { throw CodexRuntimeFailure.unavailable }
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(max(0.01, self?.timeout ?? 20) * 1_000_000_000)) }
                    catch { return }
                    self?.finish(id, .failure(CodexRuntimeFailure.timeout))
                }
                pending[id] = Pending(continuation: continuation, timeout: timer)
                do { try send(["method": method, "id": id, "params": params]) }
                catch { finish(id, .failure(CodexRuntimeFailure.unavailable)) }
                if Task.isCancelled { finish(id, .failure(CodexRuntimeFailure.cancelled)) }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.finish(id, .failure(CodexRuntimeFailure.cancelled)) }
        })
    }

    func waitForLogin(_ id: String, timeout: TimeInterval = 300) async throws -> Bool {
        if let result = completedLogins.removeValue(forKey: id) { return result }
        guard !closed, login == nil, process?.isRunning == true else { throw CodexRuntimeFailure.unavailable }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(max(0.01, timeout) * 1_000_000_000)) }
                    catch { return }
                    self?.finishLogin(.failure(CodexRuntimeFailure.timeout))
                }
                login = (id, continuation, timer)
                if Task.isCancelled { finishLogin(.failure(CodexRuntimeFailure.cancelled)) }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.finishLogin(.failure(CodexRuntimeFailure.cancelled)) }
        })
    }

    private func send(_ object: [String: Any]) throws {
        guard let input else { throw CodexRuntimeFailure.unavailable }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try input.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        guard !closed else { return }
        guard !data.isEmpty else { failAll(CodexRuntimeFailure.unavailable); return }
        buffer.append(data)
        guard buffer.count <= 4 * 1_048_576 else { failAll(CodexRuntimeFailure.protocolError); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]
            buffer.removeSubrange(...end)
            guard !line.isEmpty else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                failAll(CodexRuntimeFailure.protocolError); return
            }
            if let id = object["id"] as? Int, pending[id] != nil {
                if let result = object["result"] as? [String: Any] { finish(id, .success(result)) }
                else { finish(id, .failure(CodexRuntimeFailure.protocolError)) }
            } else if object["method"] as? String == "account/login/completed",
                let params = object["params"] as? [String: Any], let id = params["loginId"] as? String,
                let success = params["success"] as? Bool {
                if login?.0 == id { finishLogin(.success(success)) }
                else if completedLogins.count < 8 { completedLogins[id] = success }
            }
        }
    }

    private func finish(_ id: Int, _ result: Result<[String: Any], Error>) {
        guard let item = pending.removeValue(forKey: id) else { return }
        item.timeout.cancel(); item.continuation.resume(with: result)
    }
    private func finishLogin(_ result: Result<Bool, Error>) {
        guard let item = login else { return }
        login = nil; item.2.cancel(); item.1.resume(with: result)
    }
    private func failAll(_ error: Error) {
        for id in Array(pending.keys) { finish(id, .failure(error)) }
        finishLogin(.failure(error))
    }

    func close() async {
        if closed {
            if !closeCompleted { await withCheckedContinuation { closeWaiters.append($0) } }
            return
        }
        closed = true
        defer {
            closeCompleted = true
            let waiters = closeWaiters; closeWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        failAll(CodexRuntimeFailure.cancelled)
        output?.readabilityHandler = nil
        try? input?.close()
        if let process, process.isRunning {
            process.terminate()
            for _ in 0..<30 where process.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        try? output?.close()
        input = nil; output = nil; process = nil
        completedLogins.removeAll(); buffer.removeAll()
    }
}
