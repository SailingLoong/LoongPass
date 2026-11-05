// LoongPass-owned CN grants only. No Qoder app Keychain/data-directory access.
// Add this file to Runner's Compile Sources; retain one instance for the channel.
import Cocoa
import FlutterMacOS
import Security
import CryptoKit
import Darwin

final class QoderFileStore {
    private let queue = DispatchQueue(label: "com.sailingloong.loongpass.qoder-account-files")
    private let maxBytes = 1_048_576
    private var channel: FlutterMethodChannel?
    private let grantLock = NSLock()
    private var grants: [String: (state: String, expires: Date, region: String)] = [:]
    private enum Failure: Error { case unavailable, malformed, changed }

    func register(with messenger: FlutterBinaryMessenger) {
        let ch = FlutterMethodChannel(name: "com.sailingloong.loongpass/qoder-accounts", binaryMessenger: messenger)
        channel = ch
        ch.setMethodCallHandler { [weak self] call, result in
            guard let self = self else {
                result(FlutterError(code: "storage_unavailable", message: nil, details: nil)); return
            }
            if call.method == "cancelGrant" {
                let args = call.arguments as? [String: Any] ?? [:]
                guard let nonce = args["nonce"] as? String else {
                    result(FlutterError(code: "storage_unavailable", message: nil, details: nil)); return
                }
                self.grantLock.lock()
                let state = self.grants[nonce]?.state
                let completed = state == "completed"
                let uncertain = state == "unknown"
                if let grant = self.grants[nonce], !completed && !uncertain {
                    self.grants[nonce] = ("cancelled", grant.expires, grant.region)
                }
                self.grantLock.unlock()
                result(["status": completed ? "completed" : uncertain ? "unknown" : "cancelled"])
                return
            }
            self.queue.async {
                let reply: Any
                do { reply = try self.execute(call.method, call.arguments as? [String: Any] ?? [:]) }
                catch { reply = FlutterError(code: "storage_unavailable", message: nil, details: nil) }
                DispatchQueue.main.async { result(reply) }
            }
        }
    }
    private func integer(_ value: Any?) throws -> Int {
        guard let n = value as? NSNumber,
              CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue == Double(n.int64Value),
              n.int64Value >= 0, n.int64Value < Int64.max else { throw Failure.malformed }
        return Int(n.int64Value)
    }
    private func read(_ region: String) throws -> (revision: Int, payload: String, exists: Bool) {
        guard let value = try AccountFile.named("Qoder-\(region)").read(name: "accounts.json") else { return (0, "{}", false) }
        guard let payload = value["payload"] as? String else { throw Failure.unavailable }
        return (try integer(value["revision"]), payload, true)
    }
    private func execute(_ method: String, _ args: [String: Any]) throws -> [String: Any] {
        guard let region = args["region"] as? String, ["cn", "global"].contains(region) else { throw Failure.unavailable }

        if method == "newGrant" {
            var entropy = [UInt8](repeating: 0, count: 32)
            defer { for i in entropy.indices { entropy[i] = 0 } }
            let status = entropy.withUnsafeMutableBytes {
                SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
            }
            guard status == errSecSuccess else { throw Failure.unavailable }
            func url64(_ data: Data) -> String {
                data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            }
            let nonce = UUID().uuidString.lowercased()
            grantLock.lock()
            grants = grants.filter { $0.value.expires > Date() }
            guard grants.count < 64 else { grantLock.unlock(); throw Failure.unavailable }
            grants[nonce] = ("waiting", Date().addingTimeInterval(300), region)
            grantLock.unlock()
            let verifier = url64(Data(entropy))
            let challenge = url64(Data(SHA256.hash(data: Data(verifier.utf8))))
            let files = try AccountFile.named("Qoder-\(region)")
            var installation = try files.read(name: "installation.json") ?? [:]
            if installation["machineId"] == nil {
                installation["machineId"] = UUID().uuidString.lowercased()
                try files.write(installation, name: "installation.json")
            }
            guard let machine = installation["machineId"] as? String, UUID(uuidString: machine) != nil else { throw Failure.unavailable }
            return ["verifier": verifier, "challenge": challenge,
                    "nonce": nonce, "machineId": machine]
        }
        guard method == "read" || method == "compareAndSet" || method == "commitGrant" else { throw Failure.unavailable }
        // Linearization boundary: cancellation either wins before this lock,
        // or observes a completed commit afterwards. It cannot undo a saved grant.
        let nonce = args["nonce"] as? String
        if method == "commitGrant" {
            grantLock.lock()
            guard let nonce = nonce, let grant = grants[nonce],
                  grant.state == "waiting", grant.region == region, grant.expires > Date() else {
                grantLock.unlock(); throw Failure.unavailable
            }
        }
        defer { if method == "commitGrant" { grantLock.unlock() } }
        do {
            let current = try read(region)
            if method == "read" { return ["revision": current.revision, "payload": current.payload] }
            let expected = try integer(args["expectedRevision"])
            guard expected == current.revision, expected < Int.max - 1,
                  let payload = args["payload"] as? String,
                  payload.utf8.count <= maxBytes,
                  (try JSONSerialization.jsonObject(with: Data(payload.utf8))) is [String: Any] else {
                throw Failure.changed
            }
            let bytes = try JSONSerialization.data(withJSONObject: ["revision": expected + 1, "payload": payload])
            guard bytes.count <= maxBytes else { throw Failure.malformed }
            if method == "commitGrant", let nonce = nonce, let grant = grants[nonce] {
                // If update/readback fails, cancellation must not claim that a
                // possibly saved grant was undone.
                grants[nonce] = ("unknown", grant.expires, grant.region)
            }
            try AccountFile.named("Qoder-\(region)").write(["revision": expected + 1, "payload": payload], name: "accounts.json")
            // Verify exact committed content. Failure is uncertain, never retry blindly.
            let saved = try read(region)
            guard saved.revision == expected + 1 && saved.payload == payload else { throw Failure.unavailable }
            if method == "commitGrant", let nonce = nonce, let grant = grants[nonce] {
                grants[nonce] = ("completed", grant.expires, grant.region)
            }
            return ["revision": saved.revision]
          }
        }

}
