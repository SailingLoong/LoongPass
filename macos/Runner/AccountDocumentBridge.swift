import Foundation
import FlutterMacOS

/// Method handlers run on Flutter's platform thread; the file primitive also
/// holds a lifetime process lock. Revision CAS rejects stale document writes.
enum AccountDocumentBridge {
    static func handle(call: FlutterMethodCall, result: FlutterResult) -> Bool {
        guard ["readAccountDocument", "writeAccountDocument", "privateAccountDirectory"].contains(call.method) else { return false }
        do {
            guard let args = call.arguments as? [String: Any],
                let scope = args["scope"] as? String,
                AccountFile.documentScopes.contains(scope) else { throw AccountFile.Failure.unavailable }
            let file = try AccountFile.named(scope)
            if call.method == "privateAccountDirectory" {
                result(["path": file.root.path]); return true
            }
            let current = try file.read(name: "accounts.json") ?? ["revision": 0, "payload": "{}"]
            guard let revision = current["revision"] as? Int, revision >= 0,
                let payload = current["payload"] as? String else { throw AccountFile.Failure.unavailable }
            if call.method == "readAccountDocument" {
                result(["revision": revision, "payload": payload]); return true
            }
            guard let expected = args["expectedRevision"] as? Int, expected == revision,
                revision < Int.max - 1,
                let next = args["payload"] as? String, let bytes = next.data(using: .utf8),
                bytes.count <= 4 * 1024 * 1024,
                (try JSONSerialization.jsonObject(with: bytes)) is [String: Any] else { throw AccountFile.Failure.unavailable }
            try file.write(["revision": revision + 1, "payload": next], name: "accounts.json")
            result(["revision": revision + 1])
        } catch { result(FlutterError(code: "storage_unavailable", message: nil, details: nil)) }
        return true
    }
}
