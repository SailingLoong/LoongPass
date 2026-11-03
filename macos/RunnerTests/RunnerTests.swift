import Cocoa
import Darwin
import FlutterMacOS
import XCTest
@testable import LoongPass

class RunnerTests: XCTestCase {
  private var temporary: URL!

  override func setUpWithError() throws {
    temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("loongpass-native-test-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: temporary)
  }

  func testCreatesPrivateOwnedFoldersAndReusesThem() throws {
    let root = try NativeBackupFolders.prepare(in: temporary)
    XCTAssertEqual(root.lastPathComponent, "Backups")
    try NativeBackupFolders.validate(root)
    XCTAssertEqual(try NativeBackupFolders.prepare(in: temporary), root)
  }

  func testExistingPublicFolderIsRejectedWithoutChangingPermissions() throws {
    let app = temporary.appendingPathComponent("LoongPass", isDirectory: true)
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o755])
    XCTAssertThrowsError(try NativeBackupFolders.prepare(in: temporary))
    let attrs = try FileManager.default.attributesOfItem(atPath: app.path)
    XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent("Backups").path))
  }

  func testExistingSymlinkIsRejectedWithoutWritingIntoTarget() throws {
    let target = temporary.appendingPathComponent("target", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    let alias = temporary.appendingPathComponent("LoongPass")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
    XCTAssertThrowsError(try NativeBackupFolders.prepare(in: temporary))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
  }

  func testExistingFileIsRejectedAndPreserved() throws {
    let file = temporary.appendingPathComponent("LoongPass")
    let bytes = Data("synthetic unchanged".utf8)
    try bytes.write(to: file)
    XCTAssertThrowsError(try NativeBackupFolders.prepare(in: temporary))
    XCTAssertEqual(try Data(contentsOf: file), bytes)
  }

  func testExistingOwnerACLIsRejectedWithoutCreatingBackupDirectory() throws {
    let app = temporary.appendingPathComponent("LoongPass", isDirectory: true)
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    let text = "!#acl 1\nuser:::\(geteuid()):allow:readsecurity\n"
    guard let acl = text.withCString({ acl_from_text($0) }) else {
      XCTFail("Cannot create synthetic owner-only ACL")
      return
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    XCTAssertEqual(app.path.withCString { acl_set_file($0, ACL_TYPE_EXTENDED, acl) }, 0)
    XCTAssertThrowsError(try NativeBackupFolders.prepare(in: temporary))
    XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent("Backups").path))
  }

  func testSpecialModeBitsAreRejectedWithoutChangingThem() throws {
    let app = temporary.appendingPathComponent("LoongPass", isDirectory: true)
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    XCTAssertEqual(app.path.withCString { chmod($0, mode_t(0o2700)) }, 0)
    XCTAssertThrowsError(try NativeBackupFolders.prepare(in: temporary))
    var info = stat()
    XCTAssertEqual(app.path.withCString { lstat($0, &info) }, 0)
    XCTAssertEqual(info.st_mode & mode_t(0o7777), mode_t(0o2700))
  }

}
