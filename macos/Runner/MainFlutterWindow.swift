import Cocoa
import Darwin
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private let appUpdater = AppUpdater()
  private let zcodeSwitchBridge = ZcodeSwitchBridge()
  private let zcodeCaptcha = ZcodeCaptchaWindow()
  private let qoderFileStore = QoderFileStore()
  private let workBuddyDesktop = WorkBuddyDesktopBridge()
  private var selectedURL: URL?
  private var pickerOpen = false
  private var backupRoot: URL?
  private var qoderRoot: URL?
  private var workBuddyRoot: URL?
  private var workBuddySavedVault:WorkBuddyVault?

  override func awakeFromNib() {
    // Resolve/migrate before Flutter can start any account owner or journal.
    do { _ = try AppDataDirectory.applicationSupport() }
    catch {
      let alert = NSAlert()
      alert.messageText = "无法打开 LoongPass 账号数据"
      alert.informativeText = "请退出其他 LoongPass 版本，并允许系统请求的原账号目录访问。若新旧目录都有数据，请保留两处数据并联系维护者；应用不会自动合并或覆盖账号。"
      alert.runModal()
      NSApp.terminate(nil); return
    }
    // Dedicated temporary identity probe. These process-local switches are read
    // by Flutter 3.47.9's macOS engine before initialization; never modify SDK or
    // shell configuration. Override inherited debug switches, fail before engine
    // creation if the no-service setup cannot be installed.
    if Bundle.main.bundleIdentifier == "com.sailingloong.loongpass.workbuddy.identityrelease" {
      guard setenv("FLUTTER_ENGINE_SWITCHES", "2", 1) == 0,
            setenv("FLUTTER_ENGINE_SWITCH_1", "disable-vm-service", 1) == 0,
            setenv("FLUTTER_ENGINE_SWITCH_2", "disable-vm-service-publication", 1) == 0 else {
        NSApp.terminate(nil); return
      }
    }
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.minSize = NSSize(width: 480, height: 600)
    self.title = "LoongPass"
    RegisterGeneratedPlugins(registry: flutterViewController)
    appUpdater.register(with: flutterViewController.engine.binaryMessenger)

    // Register only: no production owner, discovery, configuration or launch.
    zcodeSwitchBridge.register(with: flutterViewController.engine.binaryMessenger, window: self)
    qoderFileStore.register(with: flutterViewController.engine.binaryMessenger)
    let channel = FlutterMethodChannel(
      name: "com.sailingloong.loongpass/files",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "WindowUnavailable", message: nil, details: nil))
        return
      }
      if AccountDocumentBridge.handle(call: call, result: result) { return }
      if self.workBuddyDesktop.handle(call, result: result) { return }
      if WorkBuddyNativeAccess.rejectIfDisabled(call, result) { return }
      if WorkBuddyVault.handle(call: call, result: result,production:{try self.approvedWorkBuddyVault()}) { return }
      switch call.method {
      case "verifyZcodeClaim":
        do {
          guard let args = call.arguments as? [String: Any] else { throw ZcodeCaptchaWindow.Failure.unavailable }
          try self.zcodeCaptcha.present(args, parent: self) { result($0) }
        } catch { result(FlutterError(code: "verification_unavailable", message: nil, details: nil)) }
      case "zcodeRequestContext":
        do { result(try ZcodeRequestContext.observe()) }
        catch { result(FlutterError(code: "device_required", message: nil, details: nil)) }
      case "openZcodeAuthorization":
        do {
          guard let args = call.arguments as? [String: Any], let raw = args["url"] as? String else {
            throw ZcodeRequestContext.Failure.unavailable
          }
          let url = try ZcodeRequestContext.authorizationURL(raw)
          guard NSWorkspace.shared.open(url) else { throw ZcodeRequestContext.Failure.unavailable }
          result(nil)
        } catch { result(FlutterError(code: "authorization_unavailable", message: nil, details: nil)) }
      case "chooseTraeAuthorization":
        guard !self.pickerOpen else { result(FlutterError(code: "ImportBusy", message: nil, details: nil)); return }
        self.pickerOpen = true
        let panel = NSOpenPanel()
        panel.title = "读取 TRAE CN 当前登录"
        panel.message = "选择 TRAE CN 的 User/globalStorage/storage.json；仅读取当前授权及匹配设备信息，不改写官方文件。"
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if let home = getpwuid(getuid())?.pointee.pw_dir {
          panel.directoryURL = URL(fileURLWithPath: String(cString: home)).appendingPathComponent("Library/Application Support/Trae CN/User/globalStorage")
        }
        panel.nameFieldStringValue = "storage.json"
        panel.beginSheetModal(for: self) { response in
          self.pickerOpen = false
          guard response == .OK, let url = panel.url else { result(nil); return }
          let accessed = url.startAccessingSecurityScopedResource()
          defer { if accessed { url.stopAccessingSecurityScopedResource() } }
          do { result(try TraeLocalAuthorization.read(url)) }
          catch { result(FlutterError(code: "trae_source_unavailable", message: nil, details: nil)) }
        }
      case "signTraeRefresh":
        do {
          guard let args = call.arguments as? [String: Any],
                let privateKey = args["privateKeyPEM"] as? String,
                let refresh = args["refreshToken"] as? String else { throw TraeLocalAuthorization.Failure.unavailable }
          result(try TraeLocalAuthorization.refreshProof(privatePEM: privateKey, refreshToken: refresh))
        } catch { result(FlutterError(code: "trae_device_unavailable", message: nil, details: nil)) }
      case "openTraeAuthorization":
        guard let args = call.arguments as? [String: Any], let raw = args["url"] as? String,
              let parts = URLComponents(string: raw), let url = parts.url,
              parts.scheme == "https", parts.host == "www.trae.cn", parts.path == "/authorization",
              parts.port == nil || parts.port == 443, parts.user == nil, parts.password == nil, parts.fragment == nil,
              !(parts.queryItems ?? []).contains(where: { $0.name.lowercased().contains("token") || $0.name == "code_verifier" }) else {
          result(FlutterError(code: "InvalidAuthorizationURL", message: nil, details: nil)); return
        }
        if NSWorkspace.shared.open(url) { result(nil) }
        else { result(FlutterError(code: "BrowserUnavailable", message: nil, details: nil)) }
      case "chooseMiniMaxImportSource": self.chooseMiniMaxSource(result)
      case "openWorkBuddyAuthorization", "openWorkBuddyIdentityAuthorization":
        guard let args = call.arguments as? [String: Any],
              let raw = args["url"] as? String, raw.utf8.count <= 16_384,
              let url = URL(string: raw),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", ["www.codebuddy.cn", "www.workbuddy.cn"].contains(parts.host ?? ""),
              parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              let query = parts.queryItems,
              query.filter({ $0.name == "state" }).count == 1,
              let state = query.first(where: { $0.name == "state" })?.value,
              !state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              state.utf8.count <= 4096,
              state.rangeOfCharacter(from: .controlCharacters) == nil,
              !query.contains(where: { $0.name.lowercased().contains("token") || $0.name.lowercased().contains("password") }) else {
          result(FlutterError(code: "InvalidAuthorizationURL", message: nil, details: nil)); return
        }
        if NSWorkspace.shared.open(url) { result(nil) }
        else { result(FlutterError(code: "BrowserUnavailable", message: nil, details: nil)) }
      case "openMiniMaxAuthorization":
        guard let args = call.arguments as? [String: Any],
              let region = args["region"] as? String,
              let raw = args["url"] as? String, let url = URL(string: raw),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              (region == "cn" ? ["account.minimax.cn", "agent.minimaxi.com", "agent.minimax.cn", "code.minimax.cn"] : region == "global" ? ["account.minimax.io", "agent.minimax.io", "code.minimax.io"] : []).contains(parts.host ?? ""),
              !(parts.queryItems ?? []).contains(where: { $0.name.lowercased().contains("token") || ["device_code", "code_verifier"].contains($0.name.lowercased()) }) else {
          result(FlutterError(code: "InvalidAuthorizationURL", message: nil, details: nil)); return
        }
        if NSWorkspace.shared.open(url) { result(nil) }
        else { result(FlutterError(code: "BrowserUnavailable", message: nil, details: nil)) }
      case "openQoderAuthorization":
        guard let args = call.arguments as? [String: Any],
              let raw = args["url"] as? String,
              let url = URL(string: raw),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https",
              let region = args["region"] as? String,
              parts.host == (region == "cn" ? "qoder.cn" : region == "global" ? "qoder.com" : ""),
              parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.path == "/device/selectAccounts" else {
          result(FlutterError(code: "InvalidAuthorizationURL", message: nil, details: nil)); return
        }
        if NSWorkspace.shared.open(url) { result(nil) }
        else { result(FlutterError(code: "BrowserUnavailable", message: nil, details: nil)) }
      case "chooseBackupSource": self.chooseSource(result, backup: true)
      case "chooseQoderImportSource": self.chooseSource(result, backup: false)
      case "releaseBackupSource", "releaseSelectedSource":
        self.releaseBackupSource()
        result(nil)
      case "revealBackup": self.revealBackup(call.arguments, result)
      case "prepareWorkBuddyJournal":
        do {
          let support = try AppDataDirectory.applicationSupport()
          let root = try NativeQoderFolders.prepare(in: support.resolvingSymlinksInPath(), child: "WorkBuddy")
          self.workBuddyRoot = root
          result(root.path)
        } catch {
          result(FlutterError(code: "NativeJournalUnavailable", message: nil, details: nil))
        }
      case "syncWorkBuddyJournal":
        do {
          guard let root = self.workBuddyRoot else { throw NativeBackupFolders.Failure.privateDirectoryRequired }
          try NativeQoderFolders.sync(root, child: "WorkBuddy")
          result(nil)
        } catch {
          result(FlutterError(code: "NativeJournalUnavailable", message: nil, details: nil))
        }
      case "prepareQoderJournal":
        do {
          let support = try AppDataDirectory.applicationSupport()
          let root = try NativeQoderFolders.prepare(in: support.resolvingSymlinksInPath())
          self.qoderRoot = root
          result(root.path)
        } catch {
          result(FlutterError(code: "NativeJournalUnavailable", message: nil, details: nil))
        }
      case "syncQoderJournal":
        do {
          guard let root = self.qoderRoot else { throw NativeBackupFolders.Failure.privateDirectoryRequired }
          try NativeQoderFolders.sync(root)
          result(nil)
        } catch {
          result(FlutterError(code: "NativeJournalUnavailable", message: nil, details: nil))
        }
      default: result(FlutterMethodNotImplemented)
      }
    }
    super.awakeFromNib()
  }

  private func chooseMiniMaxSource(_ result: @escaping FlutterResult) {
    guard !pickerOpen && selectedURL == nil else {
      result(FlutterError(code: "ImportBusy", message: nil, details: nil)); return
    }
    pickerOpen = true
    let panel = NSOpenPanel()
    panel.title = "选择 MiniMax 账号凭据文件"
    panel.message = "只读取所选文件；验证会将令牌发送至你确认的 MiniMax 官方区域接口。保存钥匙串会再次确认。"
    panel.prompt = "选择并验证"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = false
    panel.beginSheetModal(for: self) { [weak self] response in
      guard let self = self else {
        if response == .OK { panel.url?.stopAccessingSecurityScopedResource() }
        result(nil); return
      }
      self.pickerOpen = false
      guard response == .OK, let url = panel.url else { result(nil); return }
      self.selectedURL = url
      result(url.path)
    }
  }

  private func chooseSource(_ result: @escaping FlutterResult, backup: Bool) {
    guard !pickerOpen && selectedURL == nil else {
      result(FlutterError(code: "BackupBusy", message: nil, details: nil))
      return
    }
    pickerOpen = true
    let panel = NSOpenPanel()
    panel.title = backup ? "选择 ZCode 认证 JSON" : "选择已有 Qoder 账号配置 JSON"
    panel.message = backup
      ? "只在本机保存原样备份，不修改源文件，不上传或切换账号。"
      : "只读取所选 Qoder 配置，临时保留在本机内存。不会上传、登录或领取，不改原文件。"
    panel.prompt = backup ? "选择并备份" : "选择并导入"
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
      if !backup { result(url.path); return }
      do {
        let support = try AppDataDirectory.applicationSupport()
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

  private func approvedWorkBuddyVault()throws->WorkBuddyVault{
    guard WorkBuddyNativeAccess.enabled,WorkBuddyVault.persistentAccessValidated else{throw WorkBuddyVault.Failure.unavailable}
    if let current=workBuddySavedVault{return current}
    let support=try AppDataDirectory.applicationSupport()
    let root=try NativeQoderFolders.prepare(in:support.resolvingSymlinksInPath(),child:"WorkBuddy")
    let ownership=try WorkBuddyVaultOwnership(privateRoot:root)
    let vault=try WorkBuddyVault(ownership:ownership)
    workBuddySavedVault=vault;return vault
  }

  deinit { selectedURL?.stopAccessingSecurityScopedResource() }
}

// Independent native fail-closed boundary. No environment, method argument or
// another platform's validation flag can enable these production operations.
enum WorkBuddyMemoryIdentityAccess { static let approved=true }

enum WorkBuddyNativeAccess {
  static let enabled = true
  static func rejectIfDisabled(_ call: FlutterMethodCall, _ result: FlutterResult) -> Bool {
    if call.method=="openWorkBuddyIdentityAuthorization" {
      guard !WorkBuddyMemoryIdentityAccess.approved else { return false }
      result(FlutterError(code:"WorkBuddyIdentityUnavailable",message:nil,details:nil));return true
    }
    guard call.method.contains("WorkBuddy"), !enabled else { return false }
    result(FlutterError(code: "WorkBuddyUnavailable", message: nil, details: nil))
    return true
  }
}

enum NativeBackupFolders {
  enum Failure: Error { case privateDirectoryRequired }

  static func prepare(in applicationSupport: URL, child: String = "Backups") throws -> URL {
    guard child == "Backups" || child == "Qoder" || child == "WorkBuddy" else { throw Failure.privateDirectoryRequired }
    let base = applicationSupport.resolvingSymlinksInPath()
    let app = base.appendingPathComponent("LoongPass", isDirectory: true)
    let backups = app.appendingPathComponent(child, isDirectory: true)
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
    // acl_get_file conflates an absent ACL property with ENOENT. Inspect the
    // property only after a successful metadata read on a pinned directory FD.
    // Refuse every metadata failure, non-empty ACL, or changed directory.
    let fd = directory.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
    guard fd >= 0 else { throw Failure.privateDirectoryRequired }
    defer { close(fd) }
    guard let security = filesec_init() else { throw Failure.privateDirectoryRequired }
    defer { filesec_free(security) }
    var opened = stat()
    guard fstatx_np(fd, &opened, security) == 0,
          opened.st_dev == info.st_dev, opened.st_ino == info.st_ino,
          opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
          opened.st_uid == geteuid(), opened.st_mode & mode_t(0o7777) == mode_t(0o700) else {
      throw Failure.privateDirectoryRequired
    }
    var present: Int32 = 0
    guard filesec_query_property(security, FILESEC_ACL, &present) == 0 else {
      throw Failure.privateDirectoryRequired
    }
    if present == 0 { return }
    var value: acl_t?
    guard filesec_get_property(security, FILESEC_ACL, &value) == 0, let acl = value else {
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


// This bridge does not open the intent file. Closing another descriptor for that
// same inode would release Dart's process-wide POSIX advisory record lock.
enum NativeQoderFolders {
  static func prepare(in applicationSupport: URL, child: String = "Qoder") throws -> URL {
    // Same existing directory owner for the two separate non-secret journals.
    guard child == "Qoder" || child == "WorkBuddy" else {
      throw NativeBackupFolders.Failure.privateDirectoryRequired
    }
    var info = stat()
    guard applicationSupport.path.withCString({ lstat($0, &info) }) == 0,
          info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
          info.st_uid == geteuid(),
          applicationSupport.resolvingSymlinksInPath().path == applicationSupport.path else {
      throw NativeBackupFolders.Failure.privateDirectoryRequired
    }
    return try NativeBackupFolders.prepare(in: applicationSupport, child: child)
  }

  static func sync(_ root: URL, child: String = "Qoder") throws {
    let app = root.deletingLastPathComponent()
    guard (child == "Qoder" || child == "WorkBuddy"),
          root.lastPathComponent == child, app.lastPathComponent == "LoongPass" else {
      throw NativeBackupFolders.Failure.privateDirectoryRequired
    }
    try NativeBackupFolders.validate(root)
    try NativeBackupFolders.validate(app)
    // Flush the journal directory entry, then both newly created parent entries.
    // This is fsync durability, not a claim of tested hardware/power-loss safety.
    for directory in [root, app, app.deletingLastPathComponent()] {
      guard directory.resolvingSymlinksInPath().path == directory.path else {
        throw NativeBackupFolders.Failure.privateDirectoryRequired
      }
      let fd = directory.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
      guard fd >= 0 else { throw NativeBackupFolders.Failure.privateDirectoryRequired }
      let synced = fsync(fd)
      let closed = close(fd)
      guard synced == 0 && closed == 0 else { throw NativeBackupFolders.Failure.privateDirectoryRequired }
    }
  }
}
