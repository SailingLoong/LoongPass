import Foundation

private enum CheckFailure: Error { case staleGrant }

@main struct CodexRenewalChecks {
    @MainActor static func main() async throws {
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf:
            URL(fileURLWithPath: "test/fixtures/codex_account_contract.json"))) as! [String: Any]
        let entries = fixture["credentials"] as! [[String: Any]]
        func bytes(_ name: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: entries.first { $0["name"] as? String == name }!["document"]!)
        }
        let initial = try bytes("b"), rotated = try bytes("b-rotated")
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("loongpass-codex-renewal-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("child")
        let source = #"""
        #!/usr/bin/python3
        import sys,json,signal,time,base64
        mode=json.load(open('fixture-mode.json'))
        def finish(*args):
            with open('auth.json','wb') as f: f.write(base64.b64decode(mode['final']))
            open('shutdown-complete','w').close()
            if mode['behavior']=='cancel': time.sleep(.2)
            sys.exit(0)
        signal.signal(signal.SIGTERM,finish)
        for line in sys.stdin:
            q=json.loads(line)
            if 'id' not in q: continue
            if q['method']=='account/read' and mode['behavior']=='eof': finish()
            value={'account':{'type':'chatgpt'}} if q['method']=='account/read' else {}
            print(json.dumps({'id':q['id'],'result':value}),flush=True)
        finish()
        """#
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        for behavior in ["cancel", "eof"] {
            let home = root.appendingPathComponent(behavior), saved = root.appendingPathComponent("saved-" + behavior)
            for directory in [home, saved] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
            }
            let accounts = try CodexAccounts(file: AccountFile(root: saved))
            let id = try accounts.capture(initial)
            try JSONSerialization.data(withJSONObject: ["behavior": behavior,
                "final": rotated.base64EncodedString()]).write(to: home.appendingPathComponent("fixture-mode.json"))
            let job = Task { @MainActor in
                try await CodexRenewal.run(executable: script, home: home, credential: CodexCredential(data: initial),
                    policy: CodexAuthPolicy(["cli_auth_credentials_store": "file"])) { _ = try accounts.capture($0) }
            }
            if behavior == "cancel" {
                let deadline = Date().addingTimeInterval(5)
                while !FileManager.default.fileExists(atPath: home.appendingPathComponent("shutdown-complete").path) {
                    guard Date() < deadline else { throw CheckFailure.staleGrant }
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                job.cancel()
            }
            do { try await job.value; throw CheckFailure.staleGrant }
            catch is CancellationError {} catch CodexRuntimeFailure.cancelled {} catch CodexRuntimeFailure.unavailable {}
            guard try accounts.credential(id: id).data == rotated else { throw CheckFailure.staleGrant }
        }
        print("Codex renewal checks passed: cancellation and lost response preserve the final grant durably")
    }
}
