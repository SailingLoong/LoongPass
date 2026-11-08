import Foundation
import CryptoKit
import Darwin

/// Safe to cross the desktop channel. No underlying I/O or authentication
/// payload is included in a failure.
enum CodexFailure: Error, Equatable, LocalizedError {
    case unavailable, invalidCredential, accountNotFound, unsafePath, busy, sourceChanged, recoveryConflict, settingsUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Codex account storage is unavailable."
        case .invalidCredential: return "A consistent official Codex login is required."
        case .accountNotFound: return "The saved Codex account is unavailable."
        case .unsafePath: return "The Codex authentication location is unsafe."
        case .busy: return "Codex authentication has an active writer."
        case .sourceChanged: return "Codex authentication changed during activation."
        case .recoveryConflict: return "An interrupted Codex activation needs attention."
        case .settingsUnavailable: return "Codex local settings could not be safely preserved."
        }
    }
}

private func codexDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Identity is the official user plus workspace, never the email address.
/// Parsing supplies a local projection; the official CLI validates and renews
/// credentials. Preserve its entire original document, including unknown fields.
struct CodexCredential {
    let data: Data
    let id: String
    let email: String
    let workspaceId: String
    let userId: String
    let plan: String
    let rendererOwnerKey: String

    init(data: Data) throws {
        do {
            guard !data.isEmpty, data.count <= 1_048_576,
                  let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  document["OPENAI_API_KEY"] == nil || document["OPENAI_API_KEY"] is NSNull,
                  document["auth_mode"] == nil || document["auth_mode"] is NSNull || document["auth_mode"] as? String == "chatgpt",
                  let tokens = document["tokens"] as? [String: Any],
                  let idToken = Self.text(tokens["id_token"]),
                  let accessToken = Self.text(tokens["access_token"]),
                  Self.text(tokens["refresh_token"]) != nil else { throw CodexFailure.invalidCredential }
            let idClaims = try Self.claims(idToken), accessClaims = try Self.claims(accessToken)
            let namespace = "https://api.openai.com/auth"
            let idAuth = idClaims[namespace] as? [String: Any] ?? [:]
            let accessAuth = accessClaims[namespace] as? [String: Any] ?? [:]
            let user = try Self.identity([idAuth["chatgpt_user_id"], idAuth["user_id"],
                                          accessAuth["chatgpt_user_id"], accessAuth["user_id"]])
            let workspace = try Self.identity([tokens["account_id"], idAuth["chatgpt_account_id"],
                                               accessAuth["chatgpt_account_id"]])
            guard let email = Self.text(idClaims["email"]), email.utf8.count <= 320 else {
                throw CodexFailure.invalidCredential
            }
            if let profile = accessClaims["https://api.openai.com/profile"] as? [String: Any],
               let accessEmail = profile["email"],
               Self.text(accessEmail)?.lowercased() != email.lowercased() { throw CodexFailure.invalidCredential }
            self.data = data
            self.userId = user
            self.workspaceId = workspace
            self.email = email
            self.plan = Self.text(idAuth["chatgpt_plan_type"]) ?? Self.text(accessAuth["chatgpt_plan_type"]) ?? ""
            let owner = codexDigest(try JSONSerialization.data(withJSONObject: [user, workspace]))
            self.rendererOwnerKey = owner
            self.id = "codex-" + owner
        } catch { throw CodexFailure.invalidCredential }
    }

    private static func text(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 65_536,
              text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text
    }

    private static func identity(_ values: [Any?]) throws -> String {
        var result: String?
        for value in values {
            guard let value, !(value is NSNull) else { continue }
            guard let text = text(value), text.utf8.count <= 512,
                  result == nil || result == text else { throw CodexFailure.invalidCredential }
            result = text
        }
        guard let result else { throw CodexFailure.invalidCredential }
        return result
    }

    private static func claims(_ token: String) throws -> [String: Any] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { throw CodexFailure.invalidCredential }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CodexFailure.invalidCredential }
        return claims
    }
}

private func codexSanitized<T>(_ action: () throws -> T) throws -> T {
    do { return try action() }
    catch let failure as CodexFailure { throw failure }
    catch { throw CodexFailure.unavailable }
}

private func codexStopped(_ ensureStopped: () throws -> Void) throws {
    do { try ensureStopped() }
    catch let failure as CodexFailure { throw failure }
    catch { throw CodexFailure.busy }
}

/// Descriptor-bound access to authentication and the audited local renderer
/// preferences. Databases, configuration and whole profiles are never copied.
final class CodexAuthFile {
    private let root: URL

    fileprivate struct Root {
        let fd: Int32
        let device: dev_t
        let inode: ino_t
        let path: String
    }

    fileprivate struct FileState: Equatable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let owner: uid_t
        let links: nlink_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int

        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; mode = value.st_mode
            owner = value.st_uid; links = value.st_nlink; size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
        }
    }

    fileprivate struct Snapshot: Equatable {
        let data: Data?
        let state: FileState?
        var digest: String { data.map(codexDigest) ?? "absent" }
    }

    init(root: URL) { self.root = root }

    private func safeDirectory(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFDIR && info.st_uid == geteuid() && info.st_mode & 0o022 == 0
    }

    fileprivate func validate(_ opened: Root, failure: CodexFailure = .sourceChanged) throws {
        var named = stat(), held = stat()
        guard root.isFileURL, root.standardizedFileURL.path == root.path,
              root.resolvingSymlinksInPath().path == root.path,
              lstat(root.path, &named) == 0, safeDirectory(named),
              fstat(opened.fd, &held) == 0, safeDirectory(held),
              named.st_dev == opened.device, named.st_ino == opened.inode,
              held.st_dev == opened.device, held.st_ino == opened.inode else { throw failure }
    }

    fileprivate func withRoot<T>(exclusive: Bool, _ action: (Root) throws -> T) throws -> T {
        try codexSanitized {
            guard root.isFileURL, root.standardizedFileURL.path == root.path,
                  root.resolvingSymlinksInPath().path == root.path else { throw CodexFailure.unsafePath }
            let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw CodexFailure.unsafePath }
            defer { close(fd) }
            var held = stat()
            guard fstat(fd, &held) == 0, safeDirectory(held) else { throw CodexFailure.unsafePath }
            let opened = Root(fd: fd, device: held.st_dev, inode: held.st_ino, path: root.path)
            try validate(opened, failure: .unsafePath)
            // AccountFile already excludes another LoongPass owner. The root
            // flock also excludes a second adapter using a different store.
            if exclusive, flock(fd, LOCK_EX | LOCK_NB) != 0 { throw CodexFailure.busy }
            defer { if exclusive { flock(fd, LOCK_UN) } }
            return try action(opened)
        }
    }

    fileprivate func snapshot(_ opened: Root, name: String = "auth.json") throws -> Snapshot {
        let settings = name == CodexLocalSettings.fileName || name.hasPrefix(".loongpass-settings-")
        guard name == "auth.json" || name == CodexLocalSettings.fileName || Self.validStage(name) else {
            throw CodexFailure.unsafePath
        }
        let maximumBytes = settings ? CodexLocalSettings.maximumBytes : 1_048_576
        let forbiddenPermissions: mode_t = settings ? 0o022 : 0o077
        try validate(opened)
        let fd = openat(opened.fd, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT {
            try validate(opened)
            return Snapshot(data: nil, state: nil)
        }
        guard fd >= 0 else { throw CodexFailure.unsafePath }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var before = stat(), after = stat(), named = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(), before.st_nlink == 1, before.st_mode & forbiddenPermissions == 0,
              before.st_size >= 0, before.st_size <= maximumBytes else { throw CodexFailure.unsafePath }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(16_384, maximumBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else { throw CodexFailure.unsafePath }
        }
        guard data.count == before.st_size, fstat(fd, &after) == 0,
              fstatat(opened.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              FileState(before) == FileState(after), FileState(after) == FileState(named) else { throw CodexFailure.sourceChanged }
        try validate(opened)
        return Snapshot(data: data, state: FileState(after))
    }

    func read() throws -> Data? {
        try withRoot(exclusive: false) { try snapshot($0).data }
    }

    private static func validStage(_ name: String) -> Bool {
        for prefix in [".loongpass-auth-", ".loongpass-settings-"] {
            if name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil { return true }
        }
        return false
    }

    fileprivate func discardStage(_ stage: String, digest: String, in opened: Root) throws {
        guard Self.validStage(stage) else { throw CodexFailure.recoveryConflict }
        do {
            let pending = try snapshot(opened, name: stage)
            guard pending.data != nil else { return }
            guard pending.digest == digest, try snapshot(opened, name: stage) == pending else {
                throw CodexFailure.recoveryConflict
            }
            try validate(opened)
            guard unlinkat(opened.fd, stage, 0) == 0, fsync(opened.fd) == 0 else { throw CodexFailure.unavailable }
        } catch { throw CodexFailure.recoveryConflict }
    }

    fileprivate func replace(_ data: Data, expected: Snapshot, stage: String, in opened: Root,
                             name: String = "auth.json", ensureStopped: () throws -> Void) throws {
        guard Self.validStage(stage), name == "auth.json" || name == CodexLocalSettings.fileName,
            data.count <= (name == "auth.json" ? 1_048_576 : CodexLocalSettings.maximumBytes) else { throw CodexFailure.unsafePath }
        try validate(opened)
        let fd = openat(opened.fd, stage, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CodexFailure.unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var staged = stat()
        guard fstat(fd, &staged) == 0 else { throw CodexFailure.unavailable }
        defer {
            var named = stat()
            if fstatat(opened.fd, stage, &named, AT_SYMLINK_NOFOLLOW) == 0,
               named.st_dev == staged.st_dev, named.st_ino == staged.st_ino { unlinkat(opened.fd, stage, 0) }
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        if name == CodexLocalSettings.fileName, let mode = expected.state?.mode {
            guard fchmod(fd, mode & 0o777) == 0 else { throw CodexFailure.unavailable }
            try handle.synchronize()
        }
        try codexStopped(ensureStopped)
        do {
            try validate(opened)
            guard try snapshot(opened, name: name) == expected,
                  try snapshot(opened, name: stage).data == data else { throw CodexFailure.sourceChanged }
        } catch { throw CodexFailure.sourceChanged }
        var named = stat()
        guard fstatat(opened.fd, stage, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == staged.st_dev, named.st_ino == staged.st_ino else { throw CodexFailure.sourceChanged }
        try validate(opened)
        // Codex does not participate in our lock; the runtime checks its writers
        // again immediately before each atomic replacement.
        let renamed = expected.data == nil
            ? renameatx_np(opened.fd, stage, opened.fd, name, UInt32(RENAME_EXCL))
            : renameat(opened.fd, stage, opened.fd, name)
        guard renamed == 0 else { throw errno == EEXIST ? CodexFailure.sourceChanged : CodexFailure.unavailable }
        guard fsync(opened.fd) == 0 else { throw CodexFailure.unavailable }
        guard try snapshot(opened, name: name).data == data else { throw CodexFailure.sourceChanged }
    }
}

/// Native owner for saved official logins. The private AccountFile is the only
/// durable credential store. Paired switches additionally retain the exact local
/// settings preimage privately so a refused authentication write can roll it back.
final class CodexAccounts {
    private let file: AccountFile
    private let lock = NSLock()
    private var saved: [String: CodexCredential] = [:]
    private let accountsName = "accounts.json"
    private let journalName = "switch.json"

    init(file: AccountFile) throws {
        self.file = file
        try codexSanitized {
            guard let document = try file.read(name: accountsName) else { return }
            guard document["schema"] as? Int == 1,
                  let values = document["credentials"] as? [String: String] else { throw CodexFailure.unavailable }
            for (id, encoded) in values {
                guard let data = Data(base64Encoded: encoded) else { throw CodexFailure.unavailable }
                let credential = try CodexCredential(data: data)
                guard credential.id == id else { throw CodexFailure.unavailable }
                saved[id] = credential
            }
        }
    }

    private func synchronized<T>(_ action: () throws -> T) throws -> T {
        guard lock.try() else { throw CodexFailure.busy }
        defer { lock.unlock() }
        return try codexSanitized(action)
    }

    func summaries(currentId: String?) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return saved.values.sorted {
            if $0.email != $1.email { return $0.email < $1.email }
            if $0.workspaceId != $1.workspaceId { return $0.workspaceId < $1.workspaceId }
            return $0.id < $1.id
        }.map { ["id": $0.id, "email": $0.email, "workspaceId": $0.workspaceId,
                 "plan": $0.plan, "isCurrent": $0.id == currentId] }
    }

    private func save(_ next: [String: CodexCredential]) throws {
        try file.write(["schema": 1, "credentials": next.mapValues { $0.data.base64EncodedString() }], name: accountsName)
        saved = next
    }

    @discardableResult
    private func captureUnlocked(_ credential: CodexCredential) throws -> String {
        if saved[credential.id]?.data != credential.data {
            var next = saved
            next[credential.id] = credential
            try save(next)
        }
        return credential.id
    }

    @discardableResult
    func capture(_ data: Data) throws -> String {
        try synchronized { try captureUnlocked(CodexCredential(data: data)) }
    }

    func credential(id: String) throws -> CodexCredential {
        try synchronized {
            guard let credential = saved[id] else { throw CodexFailure.accountNotFound }
            return credential
        }
    }

    func remove(id: String) throws {
        try synchronized {
            guard saved[id] != nil else { throw CodexFailure.accountNotFound }
            var next = saved
            next.removeValue(forKey: id)
            try save(next)
        }
    }

    func observe(_ data: Data?) throws {
        try synchronized {
            guard let data else { return }
            let credential = try CodexCredential(data: data)
            if saved[credential.id] != nil { try captureUnlocked(credential) }
        }
    }

    private func recover(authFile: CodexAuthFile, root: CodexAuthFile.Root, ensureStopped: () throws -> Void) throws {
        guard var journal = try file.read(name: journalName) else { return }
        guard [1, 2].contains(journal["schema"] as? Int ?? 0), let state = journal["state"] as? String,
              ["prepared", "applied", "aborted"].contains(state) else { throw CodexFailure.recoveryConflict }
        guard state == "prepared" else { return }
        guard journal["root"] as? String == root.path,
              journal["device"] as? String == String(root.device),
              journal["inode"] as? String == String(root.inode),
              let before = journal["before"] as? String,
              let after = journal["after"] as? String,
              let stage = journal["stage"] as? String else { throw CodexFailure.recoveryConflict }
        let current = try authFile.snapshot(root).digest
        if journal["schema"] as? Int == 2 {
            guard let settings = journal["settings"] as? [String: Any],
                let encoded = settings["before"] as? String, let original = Data(base64Encoded: encoded),
                original.count <= CodexLocalSettings.maximumBytes,
                let beforeDigest = settings["beforeDigest"] as? String, codexDigest(original) == beforeDigest,
                let afterDigest = settings["afterDigest"] as? String,
                let settingsStage = settings["stage"] as? String else { throw CodexFailure.recoveryConflict }
            let observed = try authFile.snapshot(root, name: CodexLocalSettings.fileName)
            if current == before {
                guard observed.digest == beforeDigest || observed.digest == afterDigest else { throw CodexFailure.recoveryConflict }
                if observed.digest != beforeDigest {
                    try authFile.replace(original, expected: observed, stage: ".loongpass-settings-\(UUID())", in: root,
                        name: CodexLocalSettings.fileName, ensureStopped: ensureStopped)
                }
            } else {
                guard current == after, observed.digest == afterDigest else { throw CodexFailure.recoveryConflict }
            }
            try authFile.discardStage(settingsStage, digest: afterDigest, in: root)
        }
        // Authentication is never rolled back from an older token snapshot.
        if current == after { journal["state"] = "applied" }
        else if current == before { journal["state"] = "aborted" }
        else { throw CodexFailure.recoveryConflict }
        try authFile.discardStage(stage, digest: after, in: root)
        try file.write(journal, name: journalName)
    }

    func activate(id: String, authFile: CodexAuthFile, ensureStopped: () throws -> Void) throws {
        try synchronized {
            guard saved[id] != nil else { throw CodexFailure.accountNotFound }
            try authFile.withRoot(exclusive: true) { root in
                try codexStopped(ensureStopped)
                try recover(authFile: authFile, root: root, ensureStopped: ensureStopped)
                let before = try authFile.snapshot(root)
                let source = try before.data.map { try CodexCredential(data: $0) }
                if let source { try captureUnlocked(source) }
                // Resolve after capture so selecting the already-current identity
                // retains its newest outgoing credentials, not an earlier copy.
                guard let target = saved[id] else { throw CodexFailure.accountNotFound }
                let stage = ".loongpass-auth-\(UUID().uuidString)"
                let preferences = try authFile.snapshot(root, name: CodexLocalSettings.fileName)
                let nextPreferences = try preferences.data.map { data in
                    var rendererSource = source
                    // A closed desktop can retain owner A after auth advances
                    // to B. Preferences follow their own known renderer owner;
                    // outgoing authentication still follows the live auth file.
                    if let owner = try CodexLocalSettings.activeOwner(data: data) {
                        guard let known = saved.values.first(where: { $0.rendererOwnerKey == owner }) else {
                            throw CodexFailure.settingsUnavailable
                        }
                        rendererSource = known
                    }
                    return try CodexLocalSettings.transfer(data: data, source: rendererSource, target: target)
                }
                let settingsChanged = nextPreferences != preferences.data
                let settingsStage = ".loongpass-settings-\(UUID())"
                var journal: [String: Any] = ["schema": 1, "state": "prepared", "root": root.path,
                    "device": String(root.device), "inode": String(root.inode),
                    "before": before.digest, "after": codexDigest(target.data), "stage": stage]
                if settingsChanged, let original = preferences.data, let nextPreferences {
                    journal["schema"] = 2
                    journal["settings"] = ["before": original.base64EncodedString(), "beforeDigest": preferences.digest,
                        "afterDigest": codexDigest(nextPreferences), "stage": settingsStage]
                }
                try file.write(journal, name: journalName)
                do {
                    if settingsChanged, let nextPreferences {
                        try authFile.replace(nextPreferences, expected: preferences, stage: settingsStage, in: root,
                            name: CodexLocalSettings.fileName) {
                            try codexStopped(ensureStopped)
                            guard try authFile.snapshot(root) == before else { throw CodexFailure.sourceChanged }
                        }
                    }
                    try authFile.replace(target.data, expected: before, stage: stage, in: root) {
                        try codexStopped(ensureStopped)
                        if let nextPreferences {
                            guard try authFile.snapshot(root, name: CodexLocalSettings.fileName).data == nextPreferences else {
                                throw CodexFailure.sourceChanged
                            }
                        }
                    }
                    journal["state"] = "applied"
                    try file.write(journal, name: journalName)
                } catch {
                    try? recover(authFile: authFile, root: root, ensureStopped: ensureStopped)
                    throw error
                }
            }
        }
    }
}
