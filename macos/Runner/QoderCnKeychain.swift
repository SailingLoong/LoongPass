// LoongPass-owned CN grants only. No Qoder app Keychain/data-directory access.
// Add this file to Runner's Compile Sources; retain one instance for the channel.
import Cocoa
import FlutterMacOS
import Security
import CryptoKit
import Darwin

final class QoderCnKeychain {
    private let queue = DispatchQueue(label: "com.sailingloong.loongpass.qoder-cn-keychain")
    private let service = "com.sailingloong.loongpass.qoder-cn"
    private let account = "independent-grants-v1"
    private let maxBytes = 1_048_576
    private var channel: FlutterMethodChannel?
    private let grantLock = NSLock()
    private var grants: [String: (state: String, expires: Date)] = [:]
    private enum Failure: Error { case unavailable, malformed, changed }

    func register(with messenger: FlutterBinaryMessenger) {
        let ch = FlutterMethodChannel(name: "com.sailingloong.loongpass/qoder-cn", binaryMessenger: messenger)
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
                    self.grants[nonce] = ("cancelled", grant.expires)
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
    private func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false,
         kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }
    private func integer(_ value: Any?) throws -> Int {
        guard let n = value as? NSNumber,
              CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue == Double(n.int64Value),
              n.int64Value >= 0, n.int64Value < Int64.max else { throw Failure.malformed }
        return Int(n.int64Value)
    }
    private func read() throws -> (revision: Int, payload: String, exists: Bool) {
        var query = baseQuery(); query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return (0, "{}", false) }
        guard status == errSecSuccess, let bytes = item as? Data, bytes.count <= maxBytes,
              let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let payload = value["payload"] as? String else { throw Failure.unavailable }
        return (try integer(value["revision"]), payload, true)
    }
    /// This advisory lock serializes this bridge across cooperating app processes.
    /// It is not a claim of protection against a malicious process under this UID.
    private func withLock<T>(_ action: () throws -> T) throws -> T {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let root = support.appendingPathComponent("com.sailingloong.loongpass.qoder-cn", isDirectory: true)
        if mkdir(root.path, 0o700) != 0 && errno != EEXIST { throw Failure.unavailable }
        var dir = stat()
        guard lstat(root.path, &dir) == 0,
              (dir.st_mode & S_IFMT) == S_IFDIR, dir.st_uid == getuid(),
              dir.st_mode & 0o077 == 0 else { throw Failure.unavailable }
        let fd = open(root.appendingPathComponent("owner.lock").path,
                      O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid(), st.st_nlink == 1, st.st_mode & 0o077 == 0,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure.unavailable }
        defer { flock(fd, LOCK_UN) }
        return try action()
    }
    private func execute(_ method: String, _ args: [String: Any]) throws -> [String: Any] {
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
            grants[nonce] = ("waiting", Date().addingTimeInterval(300))
            grantLock.unlock()
            let verifier = url64(Data(entropy))
            let challenge = url64(Data(SHA256.hash(data: Data(verifier.utf8))))
            return ["verifier": verifier, "challenge": challenge,
                    "nonce": nonce, "machineId": UUID().uuidString.lowercased()]
        }
        guard method == "read" || method == "compareAndSet" || method == "commitGrant" else { throw Failure.unavailable }
        // Linearization boundary: cancellation either wins before this lock,
        // or observes a completed commit afterwards. It cannot undo a saved grant.
        let nonce = args["nonce"] as? String
        if method == "commitGrant" {
            grantLock.lock()
            guard let nonce = nonce, let grant = grants[nonce],
                  grant.state == "waiting", grant.expires > Date() else {
                grantLock.unlock(); throw Failure.unavailable
            }
        }
        defer { if method == "commitGrant" { grantLock.unlock() } }
        return try withoutInteraction {
          try withLock {
            let current = try read()
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
                grants[nonce] = ("unknown", grant.expires)
            }
            let status: OSStatus
            if current.exists {
                status = SecItemUpdate(baseQuery() as CFDictionary,
                    [kSecValueData as String: bytes] as CFDictionary)
            } else {
                var query = baseQuery()
                query[kSecValueData as String] = bytes
                // Classic macOS login Keychain; no unsupported iOS accessibility attribute.
                status = SecItemAdd(query as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw Failure.unavailable }
            // Verify exact committed content. Failure is uncertain, never retry blindly.
            let saved = try read()
            guard saved.revision == expected + 1 && saved.payload == payload else { throw Failure.unavailable }
            if method == "commitGrant", let nonce = nonce, let grant = grants[nonce] {
                grants[nonce] = ("completed", grant.expires)
            }
            return ["revision": saved.revision]
          }
        }
    }

    // Legacy file-based Keychains do not consistently honor per-query UI flags.
    // Suppress interaction only in this process, under the shared bridge lock,
    // and restore the previous flag on both success and failure.
    private func withoutInteraction<T>(_ operation: () throws -> T) throws -> T {
        return try LoongPassKeychainLock.withLock {
            var previous = DarwinBoolean(false)
            guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
                  SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
                throw Failure.unavailable
            }
            let outcome: Result<T, Error>
            do { outcome = .success(try operation()) }
            catch { outcome = .failure(error) }
            guard SecKeychainSetUserInteractionAllowed(previous.boolValue) == errSecSuccess else {
                throw Failure.unavailable
            }
            return try outcome.get()
        }
    }
}
