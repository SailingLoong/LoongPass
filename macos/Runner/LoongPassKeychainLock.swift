import Foundation

/// One process-wide lock for synchronous legacy Keychain operations in all
/// LoongPass bridges. Never nest this lock or await while holding it.
/// This serializes callers; it does not modify Keychain permissions or ACLs.
enum LoongPassKeychainLock {
    private static let lock = NSLock()
    static func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
