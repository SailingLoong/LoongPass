import Foundation
import Darwin

@main struct AppDataDirectoryChecks {
    static func main() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("loongpass-migration-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: base) }
        func directory(_ path: String) throws -> URL {
            let url = base.appendingPathComponent(path)
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return url
        }
        func refused(_ operation: () throws -> Void) {
            do { try operation(); fatalError("unsafe migration admitted") } catch {}
        }
        let support = try directory("support")
        let legacy = try directory("legacy/LoongPass")
        let scope = try directory("legacy/LoongPass/WorkBuddy")
        let bytes = Data("synthetic credential and claim journal".utf8)
        let original = scope.appendingPathComponent("accounts.json")
        try bytes.write(to: original)
        chmod(original.path, 0o600)
        refused { _ = try AppDataDirectory.prepare(support: support, legacy: legacy, ensureIdle: { throw AppDataDirectory.Failure.busy }) }
        precondition(fm.fileExists(atPath: original.path))
        var owner: AccountFile? = try AccountFile(root: scope)
        refused { _ = try AppDataDirectory.prepare(support: support, legacy: legacy, ensureIdle: {}) }
        withExtendedLifetime(owner) {}
        precondition(fm.fileExists(atPath: original.path))
        owner = nil
        let moved = try AppDataDirectory.prepare(support: support, legacy: legacy, ensureIdle: {})
        precondition(!fm.fileExists(atPath: legacy.path))
        let preserved = try Data(contentsOf: moved.appendingPathComponent("WorkBuddy/accounts.json"))
        precondition(preserved == bytes)
        let restarted = try AppDataDirectory.prepare(support: support, legacy: legacy, ensureIdle: {})
        precondition(restarted == moved)
        _ = try directory("legacy/LoongPass")
        refused { _ = try AppDataDirectory.prepare(support: support, legacy: legacy, ensureIdle: {}) }
        let afterConflict = try Data(contentsOf: moved.appendingPathComponent("WorkBuddy/accounts.json"))
        precondition(afterConflict == bytes)
        try fm.removeItem(at: legacy)
        try fm.createSymbolicLink(at: legacy, withDestinationURL: moved)
        refused { _ = try AppDataDirectory.prepare(support: support, legacy: legacy, ensureIdle: {}) }
        let freshSupport = base.appendingPathComponent("fresh")
        let fresh = try AppDataDirectory.prepare(support: freshSupport, legacy: base.appendingPathComponent("absent"), ensureIdle: {})
        let attributes = try fm.attributesOfItem(atPath: fresh.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        print("PASS atomic account migration, preserved bytes, busy owner, conflict, symlink, fresh install and restart")
    }
}
