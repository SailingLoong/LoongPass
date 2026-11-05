import Foundation
import FlutterMacOS
import Security
import Darwin

/// Register with the existing files channel: if MiniMaxKeychain.handle(call: call,
/// result: result) { return }. No automatic registration or credential access.
enum MiniMaxKeychain {
    private static let service = "com.sailingloong.loongpass.minimax"
    private static var journalRoot: URL?
    private enum Failure: Error { case journal }

    // Host invokes on Flutter's platform thread. Unknown methods are untouched.
    static func handle(call: FlutterMethodCall, result: FlutterResult) -> Bool {
        switch call.method {
        case "prepareMiniMaxJournal":
            do {
                let root = try prepareJournal()
                journalRoot = root
                result(root.path)
            } catch { fail("journal_unavailable", result) }
            return true
        case "syncMiniMaxJournal":
            do {
                guard let root = journalRoot else { throw Failure.journal }
                try syncJournal(root)
                result(nil)
            } catch { fail("journal_unavailable", result) }
            return true
        case "minimaxKeychainRead", "minimaxKeychainWrite", "minimaxKeychainDelete":
            break
        default: return false
        }
        guard let args = call.arguments as? [String: Any],
              let id = args["id"] as? String, validID(id) else {
            fail("invalid_arguments", result)
            return true
        }
        switch call.method {
        case "minimaxKeychainRead": read(id, result)
        case "minimaxKeychainWrite":
            guard let token = args["accessToken"] as? String, validToken(token) else {
                fail("invalid_credential", result)
                return true
            }
            write(id, token, result)
        default: delete(id, result)
        }
        return true
    }

    private static func validID(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "cn" || parts[0] == "global",
              parts[1].utf8.count == 64 else { return false }
        return parts[1].utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func validToken(_ value: String) -> Bool {
        let bytes = value.utf8
        return !bytes.isEmpty && bytes.count <= 16384 &&
            bytes.allSatisfy { (33...126).contains($0) }
    }

    private static func query(_ id: String) -> [String: Any] {
        // Standard macOS login Keychain: no new provisioning/signing gate.
        // ThisDeviceOnly accessibility requires the data-protection Keychain on
        // macOS; it cannot honestly be promised for this legacy backend.
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: id,
                kSecAttrSynchronizable as String: false,
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }

    private static func read(_ id: String, _ result: FlutterResult) {
        var request = query(id)
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = withoutInteraction { SecItemCopyMatching(request as CFDictionary, &item) }
        if status == errSecItemNotFound { result(nil); return }
        guard status == errSecSuccess else { failStatus(status, result); return }
        guard let data = item as? Data, data.count <= 16384,
              let token = String(data: data, encoding: .utf8), validToken(token) else {
            fail("invalid_credential", result); return
        }
        result(token)
    }

    private static func write(_ id: String, _ token: String, _ result: FlutterResult) {
        // Authorization belongs to the host. Save ONLY the access token.
        let request = query(id)
        let changes: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        let status = withoutInteraction {
            var status = SecItemUpdate(request as CFDictionary, changes as CFDictionary)
            if status == errSecItemNotFound {
                var addition = request
                addition[kSecValueData as String] = Data(token.utf8)
                status = SecItemAdd(addition as CFDictionary, nil)
                if status == errSecDuplicateItem {
                    status = SecItemUpdate(request as CFDictionary, changes as CFDictionary)
                }
            }
            return status
        }
        guard status == errSecSuccess else { failStatus(status, result); return }
        result(nil)
    }

    private static func delete(_ id: String, _ result: FlutterResult) {
        let status = withoutInteraction { SecItemDelete(query(id) as CFDictionary) }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            failStatus(status, result); return
        }
        result(nil)
    }

    private static func failStatus(_ status: OSStatus, _ result: FlutterResult) {
        fail(status == errSecInteractionNotAllowed || status == errSecInteractionRequired || status == errSecAuthFailed ||
             status == errSecUserCanceled ? "keychain_locked" : "keychain_unavailable", result)
    }

    private static func withoutInteraction(_ operation: () -> OSStatus) -> OSStatus {
        // Per-query UI flags alone do not establish legacy Keychain behavior.
        // Every LoongPass legacy Keychain bridge uses this same process lock.
        return LoongPassKeychainLock.withLock {
            var previous = DarwinBoolean(false)
            guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
                  SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
                return errSecInteractionNotAllowed
            }
            let status = operation()
            let restored = SecKeychainSetUserInteractionAllowed(previous.boolValue)
            return restored == errSecSuccess ? status : errSecInteractionNotAllowed
        }
    }

    private static func fail(_ code: String, _ result: FlutterResult) {
        result(FlutterError(code: code, message: nil, details: nil))
    }

    private static func prepareJournal() throws -> URL {
        // Never open auth files or the journal itself (Dart owns its file lock).
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: false).resolvingSymlinksInPath()
        try validateDirectory(support, privateOnly: false)
        let app = support.appendingPathComponent("LoongPass", isDirectory: true)
        let root = app.appendingPathComponent("MiniMax", isDirectory: true)
        for directory in [app, root] {
            let status = directory.path.withCString { mkdir($0, mode_t(0o700)) }
            guard status == 0 || errno == EEXIST else { throw Failure.journal }
            try validateDirectory(directory, privateOnly: true)
        }
        return root
    }

    private static func validateDirectory(_ directory: URL, privateOnly: Bool) throws {
        var info = stat()
        guard directory.path.withCString({ lstat($0, &info) }) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == geteuid(),
              directory.resolvingSymlinksInPath().path == directory.path,
              !privateOnly || info.st_mode & mode_t(0o7777) == mode_t(0o700) else {
            throw Failure.journal
        }
        if privateOnly {
            // Share the FD-pinned, absent-ACL-aware validation used by the
            // other app-owned private journal directories.
            try NativeBackupFolders.validate(directory)
        }
    }

    private static func syncJournal(_ root: URL) throws {
        let app = root.deletingLastPathComponent()
        guard root.lastPathComponent == "MiniMax", app.lastPathComponent == "LoongPass" else {
            throw Failure.journal
        }
        for directory in [root, app, app.deletingLastPathComponent()] {
            try validateDirectory(directory, privateOnly: directory != app.deletingLastPathComponent())
            let fd = directory.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard fd >= 0 else { throw Failure.journal }
            var info = stat()
            let ownedDirectory = fstat(fd, &info) == 0 && info.st_uid == geteuid() &&
                info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            let synced = ownedDirectory ? fsync(fd) : -1
            let closed = close(fd)
            guard synced == 0 && closed == 0 else { throw Failure.journal }
        }
    }
}
