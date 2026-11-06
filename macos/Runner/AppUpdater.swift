import Cocoa
import FlutterMacOS
import Sparkle

/// Sparkle is the sole owner of update scheduling, persistence and installation.
/// The Flutter bridge exposes settings and explicit actions, never credentials.
final class AppUpdater: NSObject {
  private var controller: SPUStandardUpdaterController!
  private var channel: FlutterMethodChannel?
  private var observations: [NSKeyValueObservation] = []

  func register(with messenger: FlutterBinaryMessenger) {
    guard controller == nil else { return }
    controller = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    let channel = FlutterMethodChannel(name: "com.sailingloong.loongpass/updates",
                                       binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterError(code: "unavailable", message: nil, details: nil)); return }
      let updater = self.controller.updater
      switch call.method {
      case "state": break
      case "check":
        guard updater.canCheckForUpdates else {
          result(FlutterError(code: "busy", message: nil, details: nil)); return
        }
        self.controller.checkForUpdates(nil)
      case "setAutomaticChecks", "setAutomaticDownloads":
        guard let value = call.arguments as? Bool else {
          result(FlutterError(code: "invalid_setting", message: nil, details: nil)); return
        }
        if call.method == "setAutomaticChecks" { updater.automaticallyChecksForUpdates = value }
        else { updater.automaticallyDownloadsUpdates = value }
      default: result(FlutterMethodNotImplemented); return
      }
      result(self.state())
    }
    observations = [
      controller.updater.observe(\.canCheckForUpdates) { [weak self] _, _ in self?.publish() },
      controller.updater.observe(\.automaticallyChecksForUpdates) { [weak self] _, _ in self?.publish() },
      controller.updater.observe(\.automaticallyDownloadsUpdates) { [weak self] _, _ in self?.publish() },
    ]
    controller.startUpdater()
  }

  private func state() -> [String: Any] {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
    return ["version": "\(version) (\(build))",
     "canCheck": controller.updater.canCheckForUpdates,
     "automaticChecks": controller.updater.automaticallyChecksForUpdates,
     "automaticDownloads": controller.updater.automaticallyDownloadsUpdates]
  }

  private func publish() { channel?.invokeMethod("stateChanged", arguments: state()) }
}
