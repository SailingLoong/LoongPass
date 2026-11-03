import Cocoa
import Darwin
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var selectedURL: URL?
  private var pickerOpen = false
  private var backupRoot: URL?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.minSize = NSSize(width: 480, height: 600)
    self.title = "LoongPass"
    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "com.sailingloong.loongpass/files",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "WindowUnavailable", message: nil, details: nil))
        return
      }
      switch call.method {
      case "chooseBackupSource": self.chooseBackupSource(result)
      case "releaseBackupSource":
        self.releaseBackupSource()
        result(nil)
      case "revealBackup": self.revealBackup(call.arguments, result)
      default: result(FlutterMethodNotImplemented)
      }
    }
    super.awakeFromNib()
  }

  private func chooseBackupSource(_ result: @escaping FlutterResult) {
    guard !pickerOpen && selectedURL == nil else {
      result(FlutterError(code: "BackupBusy", message: nil, details: nil))
      return
    }
    pickerOpen = true
    let panel = NSOpenPanel()
    panel.title = "选择 ZCode 认证 JSON"
    panel.message = "只在本机保存原样备份，不修改源文件，不上传或切换账号。"
    panel.prompt = "选择并备份"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = false
    panel.beginSheetModal(for: self) { [weak self] response in
      guard let self = self else {
        if response == .OK { panel.url?.stopAccessingSecurityScopedResource() }
        result(nil)
        return
      }
      self.pickerOpen = false
      guard response == .OK, let url = panel.url else { result(nil); return }
      // NSOpenPanel supplies an implicit security-scoped grant. Keep its URL
      // until Dart finishes; balance it with exactly one stop, not another start.
      self.selectedURL = url
      do {
        let support = try FileManager.default.url(
          for: .applicationSupportDirectory, in: .userDomainMask,
          appropriateFor: nil, create: true)
        let root = try NativeBackupFolders.prepare(in: support)
        self.backupRoot = root
        result(["sourcePath": url.path, "privateRoot": root.path])
      } catch {
        self.releaseBackupSource()
        result(FlutterError(code: "PrivateDirectoryRequired", message: nil, details: nil))
      }
    }
  }

  private func releaseBackupSource() {
    selectedURL?.stopAccessingSecurityScopedResource()
    selectedURL = nil
  }

  private func revealBackup(_ arguments: Any?, _ result: FlutterResult) {
    guard let values = arguments as? [String: Any],
          let path = values["path"] as? String,
          let root = backupRoot else {
      result(FlutterError(code: "InvalidBackupPath", message: nil, details: nil))
      return
    }
    let url = URL(fileURLWithPath: path)
    // Only reveal a current, canonical file inside this application's root.
    guard url.resolvingSymlinksInPath().path == url.path,
          url.path.hasPrefix(root.path + "/"),
          FileManager.default.fileExists(atPath: url.path) else {
      result(FlutterError(code: "InvalidBackupPath", message: nil, details: nil))
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting([url])
    result(nil)
  }

  deinit { selectedURL?.stopAccessingSecurityScopedResource() }
}

enum NativeBackupFolders {
  enum Failure: Error { case privateDirectoryRequired }

  static func prepare(in applicationSupport: URL) throws -> URL {
    let base = applicationSupport.resolvingSymlinksInPath()
    let app = base.appendingPathComponent("LoongPass", isDirectory: true)
    let backups = app.appendingPathComponent("Backups", isDirectory: true)
    for directory in [app, backups] {
      let status = directory.path.withCString { mkdir($0, mode_t(0o700)) }
      guard status == 0 || errno == EEXIST else { throw Failure.privateDirectoryRequired }
      try validate(directory)
    }
    return backups
  }

  static func validate(_ directory: URL) throws {
    var info = stat()
    guard directory.path.withCString({ lstat($0, &info) }) == 0,
          info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
          info.st_uid == geteuid(), info.st_mode & mode_t(0o7777) == mode_t(0o700),
          directory.resolvingSymlinksInPath().path == directory.path else {
      throw Failure.privateDirectoryRequired
    }
    // Refuse unexpected inherited ACLs rather than silently changing permissions.
    guard let acl = directory.path.withCString({ acl_get_file($0, ACL_TYPE_EXTENDED) }) else {
      throw Failure.privateDirectoryRequired
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    guard acl_valid(acl) == 0 else { throw Failure.privateDirectoryRequired }
    var entry: acl_entry_t? = nil
    errno = 0
    let status = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
    let aclError = errno
    guard status == -1 && aclError == EINVAL else { throw Failure.privateDirectoryRequired }
  }
}
