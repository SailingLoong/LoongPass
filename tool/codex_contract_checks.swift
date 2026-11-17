import Foundation

@main struct CodexContractChecks {
    static func main() throws {
        let path = URL(fileURLWithPath: "test/fixtures/codex_account_contract.json")
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        var credentials: [String: CodexCredential] = [:]
        for entry in fixture["credentials"] as! [[String: Any]] {
            let bytes = try JSONSerialization.data(withJSONObject: entry["document"]!)
            if entry["invalid"] as? Bool == true {
                do { _ = try CodexCredential(data: bytes); preconditionFailure("Inconsistent identity accepted") }
                catch CodexFailure.invalidCredential {}
            } else {
                let credential = try CodexCredential(data: bytes)
                precondition(credential.id == entry["expectedId"] as? String)
                precondition(credential.rendererOwnerKey == entry["expectedOwner"] as? String)
                precondition(credential.data == bytes)
                credentials[entry["name"] as! String] = credential
            }
        }
        for entry in fixture["settings"] as! [[String: Any]] {
            let bytes = try JSONSerialization.data(withJSONObject: entry["document"]!)
            let source = credentials[entry["source"] as! String]!
            let target = credentials[entry["target"] as! String]!
            if entry["invalid"] as? Bool == true {
                do {
                    _ = try CodexLocalSettings.transfer(data: bytes, source: source, target: target)
                    preconditionFailure("Unrecognized renderer state accepted")
                } catch CodexFailure.settingsUnavailable {}
            } else {
                if let expectedOwner = entry["expectedActiveOwner"] {
                    let owner = try CodexLocalSettings.activeOwner(data: bytes)
                    precondition(owner == (expectedOwner as? String), "Renderer owner was not recognized")
                }
                let output = try CodexLocalSettings.transfer(data: bytes, source: source, target: target)
                let actual = try JSONSerialization.jsonObject(with: output) as! [String: Any]
                precondition(NSDictionary(dictionary: actual).isEqual(to: entry["expected"] as! [String: Any]))
            }
        }
        let legacy = Data((fixture["legacySettings"] as! String).utf8)
        let unchanged = try CodexLocalSettings.transfer(data: legacy, source: credentials["a"], target: credentials["b"]!)
        precondition(unchanged == legacy)
        print("Codex shared contract passed on macOS: identities, unknown fields, local-state isolation and legacy bytes")
    }
}
