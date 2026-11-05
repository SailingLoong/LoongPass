import Foundation
import Darwin

@main
struct WorkBuddyFileStoreChecks {
    static func check(_ condition: Bool) { precondition(condition) }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("loongpass-file-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let key = String(repeating: "a", count: 64)
        let record: [String: Any] = [
            "schema": 1, "revision": 1, "state": "active",
            "domain": "www.workbuddy.cn", "endpoint": "www.workbuddy.cn",
            "uid": "synthetic-account", "accessToken": "synthetic-access",
            "expiresAt": 1_800_000_000_000,
        ]
        do {
            let owner = try WorkBuddyVaultOwnership(privateRoot: root)
            let store = try WorkBuddyVault(ownership: owner)
            check(try store.savedKeys().isEmpty)
            check(try store.compareExchange(key, expected: nil, value: record))
            check(try store.read(key)?["uid"] as? String == "synthetic-account")
            check(try !store.compareExchange(key, expected: nil, value: record))
            let file = root.appendingPathComponent("accounts.json")
            let contents = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: [String: Any]]
            precondition(contents[key]?["accessToken"] as? String == "synthetic-access")
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        do {
            let store = try WorkBuddyVault(ownership: WorkBuddyVaultOwnership(privateRoot: root))
            check(try store.savedKeys() == [key])
            check(try store.read(key)?["uid"] as? String == "synthetic-account")
            check(try store.compareExchange(key, expected: 1,
                value: ["schema": 1, "revision": 2, "state": "revoked"]))
            let data = try Data(contentsOf: root.appendingPathComponent("accounts.json"))
            precondition(!String(decoding: data, as: UTF8.self).contains("synthetic-access"))
        }
        print("PASS plaintext JSON, private permissions, CAS, restart and credential removal")
    }
}
