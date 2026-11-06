import Cocoa
import FlutterMacOS
import Sparkle

/// Sparkle is the sole owner of update scheduling, persistence and installation.
/// The Flutter bridge exposes settings and explicit actions, never credentials.
final class AppUpdater: NSObject, SPUUpdaterDelegate {
  private var controller: SPUStandardUpdaterController!
  private var channel: FlutterMethodChannel?
  private var observations: [NSKeyValueObservation] = []

  private var synchronizingPreferences = false
  private var updatePending = false
  private let betaPreference = "LoongPassReceiveBetaUpdates"
  private var receiveBetaUpdates: Bool { UserDefaults.standard.bool(forKey: betaPreference) }
  private var canChangeChannel: Bool {
    !controller.updater.sessionInProgress && !updatePending
  }

  func register(with messenger: FlutterBinaryMessenger) {
    guard controller == nil else { return }
    controller = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    // Preserve a previous opt-out of either automatic checks or downloads.
    setAutomaticUpdates(controller.updater.automaticallyChecksForUpdates &&
                        controller.updater.automaticallyDownloadsUpdates)
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
      case "setAutomaticUpdates", "setReceiveBetaUpdates":
        guard let value = call.arguments as? Bool else {
          result(FlutterError(code: "invalid_setting", message: nil, details: nil)); return
        }
        if call.method == "setAutomaticUpdates" { self.setAutomaticUpdates(value) }
        else {
          guard self.canChangeChannel else {
            result(FlutterError(code: "busy", message: nil, details: nil)); return
          }
          UserDefaults.standard.set(value, forKey: self.betaPreference)
          updater.resetUpdateCycleAfterShortDelay()
        }
      default: result(FlutterMethodNotImplemented); return
      }
      result(self.state())
    }
    observations = [
      controller.updater.observe(\.canCheckForUpdates) { [weak self] _, _ in self?.publish() },
      controller.updater.observe(\.sessionInProgress) { [weak self] _, _ in self?.publish() },
      controller.updater.observe(\.automaticallyChecksForUpdates) { [weak self] updater, _ in
        self?.setAutomaticUpdates(updater.automaticallyChecksForUpdates)
      },
      controller.updater.observe(\.automaticallyDownloadsUpdates) { [weak self] updater, _ in
        self?.setAutomaticUpdates(updater.automaticallyDownloadsUpdates)
      },
    ]
    controller.startUpdater()
  }

  private func state() -> [String: Any] {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
    return ["version": "\(version) (\(build))",
     "canCheck": controller.updater.canCheckForUpdates,
     "canChangeChannel": canChangeChannel,
     "receiveBetaUpdates": receiveBetaUpdates,
     "automaticUpdates": controller.updater.automaticallyChecksForUpdates &&
                         controller.updater.automaticallyDownloadsUpdates]
  }

  private func setAutomaticUpdates(_ value: Bool) {
    guard !synchronizingPreferences else { return }
    synchronizingPreferences = true
    controller.updater.automaticallyChecksForUpdates = value
    controller.updater.automaticallyDownloadsUpdates = value
    synchronizingPreferences = false
    publish()
  }

  func feedURLString(for updater: SPUUpdater) -> String? {
    let key = receiveBetaUpdates ? "SUFeedURL" : "LoongPassStableFeedURL"
    return (Bundle.main.object(forInfoDictionaryKey: key) as! String)
  }

  func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem,
               updateCheck: SPUUpdateCheck) throws {
    // Validate newly discovered candidates. Resumed candidates retain their channel
    // because updatePending prevents switching until they are installed or discarded.
    if !receiveBetaUpdates && item.displayVersionString.contains("-") {
      throw NSError(domain: "com.sailingloong.loongpass.updates", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "已关闭 Beta 版更新，请重新检查正式版更新。"])
    }
  }

  func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
    updatePending = true
    publish()
  }

  func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
               forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
    if choice == .skip { updatePending = false }
    else if state.stage != .notDownloaded { updatePending = true }
    publish()
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
    // Sparkle retains a downloaded candidate only when authorization is deferred.
    if (error as NSError).code != Int(SUError.installationAuthorizeLaterError.rawValue) {
      updatePending = false
    }
    publish()
  }

  func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
               immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
    // Sparkle can end its session while an installer still waits for app exit.
    updatePending = true
    publish()
    return false
  }

  private func publish() { channel?.invokeMethod("stateChanged", arguments: state()) }
}
