import Foundation
import Darwin

@main struct CodexRuntimeChecks {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("loongpass-codex-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("server")
        let source = #"""
        #!/usr/bin/python3
        import sys,json,signal,time,os
        delayed=False
        for line in sys.stdin:
            q=json.loads(line)
            if 'id' not in q: continue
            method=q['method']
            if method=='hang': continue
            if method=='eof': break
            if method=='initialize': value={}
            elif method=='delayedClose':
                delayed=True
                def stop(*args):
                    open('stopping','w').close()
                    time.sleep(0.3)
                    sys.exit(0)
                signal.signal(signal.SIGTERM,stop)
                value={'pid':os.getpid()}
            elif method=='account/login/start':
                print(json.dumps({'method':'account/login/completed','params':{'loginId':'synthetic-login','success':True}}),flush=True)
                value={'loginId':'synthetic-login','authUrl':'https://auth.openai.com/authorize'}
            else: value={'echo':q['params']}
            print(json.dumps({'id':9999,'result':{'wrong':True}}),flush=True)
            print(json.dumps({'id':q['id'],'result':value}),flush=True)
        if delayed:
            while True: signal.pause()
        """#
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        print("Codex runtime stage: initialize and correlated requests")
        let server = CodexAppServer(executable: script, home: root, timeout: 3)
        try await server.start()
        let response = try await server.request("echo", params: ["meaning": 42])
        precondition((response["echo"] as? [String: Any])?["meaning"] as? Int == 42)
        let login = try await server.request("account/login/start", params: ["type": "chatgpt"])
        precondition(login["loginId"] as? String == "synthetic-login")
        let loggedIn = try await server.waitForLogin("synthetic-login")
        precondition(loggedIn)
        do { _ = try await server.request("hang"); preconditionFailure("Timeout not enforced") }
        catch CodexRuntimeFailure.timeout {}
        await server.close()
        print("Codex runtime stage: EOF")
        let ended = CodexAppServer(executable: script, home: root, timeout: 3)
        try await ended.start()
        do { _ = try await ended.request("eof"); preconditionFailure("EOF left a request pending") }
        catch CodexRuntimeFailure.unavailable {}
        await ended.close()

        print("Codex runtime stage: competing close")
        let delayed = CodexAppServer(executable: script, home: root, timeout: 3)
        try await delayed.start()
        let child = try await delayed.request("delayedClose")
        let pid = child["pid"] as! Int32
        let firstClose = Task { @MainActor in await delayed.close() }
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("stopping").path) {
            guard Date() < deadline else { preconditionFailure("Closing handshake missing") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await delayed.close()
        precondition(kill(pid, 0) != 0, "Concurrent close returned while its child was still alive")
        await firstClose.value

        let policy = try CodexAuthPolicy(["cli_auth_credentials_store": "file", "forced_chatgpt_workspace_id": "workspace-a"])
        try policy.validate(workspaceId: "workspace-a")
        do { try policy.validate(workspaceId: "workspace-b"); preconditionFailure("Workspace restriction ignored") }
        catch CodexRuntimeFailure.restricted {}
        for store in ["auto", "keyring", "ephemeral", "future"] {
            do { _ = try CodexAuthPolicy(["cli_auth_credentials_store": store]); preconditionFailure("Unsupported storage accepted") }
            catch CodexRuntimeFailure.unsupportedStore {}
        }
        do { _ = try CodexAuthPolicy(["cli_auth_credentials_store": "file", "forced_login_method": "api"]); preconditionFailure("Login restriction ignored") }
        catch CodexRuntimeFailure.restricted {}
        let executable = root.appendingPathComponent("bin/codex")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: false)
        try Data("test".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let manifest = Data(#"{"layoutVersion":1,"entrypoint":"bin/codex"}"#.utf8)
        let resolved = try CodexExecutable.resolve(manifest: manifest, package: root)
        precondition(resolved == executable)
        do { _ = try CodexExecutable.resolve(manifest: Data(#"{"entrypoint":"../outside"}"#.utf8), package: root); preconditionFailure("Escaping entrypoint accepted") }
        catch CodexRuntimeFailure.unavailable {}
        print("Codex runtime checks passed: correlation, login notification, timeout, EOF, policies and manifest boundary")
    }
}
