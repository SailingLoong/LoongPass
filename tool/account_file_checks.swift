import Foundation
import Darwin

@main struct AccountFileChecks {
  static func main() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("loongpass-file-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AccountFile(root: root)
    try store.write(["test": "synthetic"], name: "credentials.json")
    let value = try store.read(name: "credentials.json")
    precondition(value?["test"] as? String == "synthetic")
    let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("credentials.json").path)
    precondition((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    do { _ = try AccountFile(root: root); fatalError("second writer admitted") } catch {}
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.json"), withDestinationURL: root.appendingPathComponent("credentials.json"))
    do { _ = try store.read(name: "link.json"); fatalError("symlink accepted") } catch {}
    print("PASS private JSON read/write, 0600, single writer, symlink rejection")
  }
}
