import Cocoa
import FlutterMacOS
import Sparkle

/// Native Sparkle owns scheduling, persistence, validation and installation.
final class AppUpdater: NSObject, SPUUpdaterDelegate {
  private var updater: SPUUpdater!
  private let driver = AppUpdateUserDriver()
  private var channel: FlutterMethodChannel?
  private var observations: [NSKeyValueObservation] = []
  private var synchronizingPreferences = false
  private var revision = 0
  private let betaPreference = "LoongPassReceiveBetaUpdates"
  private var receiveBetaUpdates: Bool { UserDefaults.standard.bool(forKey: betaPreference) }
  private var canChangeChannel: Bool { !updater.sessionInProgress && !driver.ownsCandidate }
  private var canCheck: Bool { updater.canCheckForUpdates && !driver.ownsCandidate }

  func register(with messenger: FlutterBinaryMessenger) {
    guard updater == nil else { return }
    updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
    driver.changed = { [weak self] in self?.publish() }
    driver.automaticUpdates = { [weak self] in self?.updater.automaticallyChecksForUpdates ?? false }
    // Preserve a previous opt-out of either checks or downloads.
    setAutomaticUpdates(updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates)
    let channel = FlutterMethodChannel(name: UpdateContract.channel, binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterError(code: "unavailable", message: nil, details: nil)); return }
      switch call.method {
      case UpdateContract.state: break
      case UpdateContract.check:
        guard self.canCheck else { result(self.busy()); return }
        self.updater.checkForUpdates()
      case UpdateContract.install:
        guard self.driver.install() else { result(self.busy()); return }
      case UpdateContract.skip:
        guard self.driver.skip() else { result(self.busy()); return }
      case UpdateContract.setAutomaticUpdates, UpdateContract.setReceiveBetaUpdates:
        guard let value = call.arguments as? Bool else {
          result(FlutterError(code: "invalid_setting", message: nil, details: nil)); return
        }
        if call.method == UpdateContract.setAutomaticUpdates { self.setAutomaticUpdates(value) }
        else {
          guard self.canChangeChannel else { result(self.busy()); return }
          UserDefaults.standard.set(value, forKey: self.betaPreference)
          self.updater.resetUpdateCycleAfterShortDelay()
          self.publish()
        }
      default: result(FlutterMethodNotImplemented); return
      }
      result(self.state())
    }
    observations = [
      updater.observe(\.canCheckForUpdates) { [weak self] _, _ in self?.publish() },
      updater.observe(\.sessionInProgress) { [weak self] _, _ in self?.publish() },
      updater.observe(\.automaticallyChecksForUpdates) { [weak self] updater, _ in
        self?.setAutomaticUpdates(updater.automaticallyChecksForUpdates)
      },
      updater.observe(\.automaticallyDownloadsUpdates) { [weak self] updater, _ in
        self?.setAutomaticUpdates(updater.automaticallyDownloadsUpdates)
      },
    ]
    do {
      try updater.start()
      if updater.automaticallyChecksForUpdates {
        driver.transition(.checking)
        updater.checkForUpdatesInBackground()
      }
    } catch { driver.fail(error.localizedDescription) }
  }

  private func busy() -> FlutterError { FlutterError(code: "busy", message: nil, details: nil) }
  private func state() -> [String: Any] {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
    return [UpdateContract.revision: revision, UpdateContract.version: "\(version) (\(build))",
      UpdateContract.phase: driver.phase.rawValue,
      UpdateContract.offeredVersion: driver.offeredVersion as Any? ?? NSNull(),
      UpdateContract.progress: driver.progress as Any? ?? NSNull(),
      UpdateContract.error: driver.error as Any? ?? NSNull(),
      UpdateContract.canCheck: canCheck, UpdateContract.canChangeChannel: canChangeChannel,
      UpdateContract.canInstall: driver.canInstall, UpdateContract.canSkip: driver.canSkip,
      UpdateContract.installOnQuit: true, UpdateContract.receiveBetaUpdates: receiveBetaUpdates,
      UpdateContract.automaticUpdates: updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates]
  }
  private func setAutomaticUpdates(_ value: Bool) {
    guard !synchronizingPreferences else { return }
    synchronizingPreferences = true
    updater.automaticallyChecksForUpdates = value
    updater.automaticallyDownloadsUpdates = value
    synchronizingPreferences = false
    publish()
  }
  func feedURLString(for updater: SPUUpdater) -> String? {
    Bundle.main.object(forInfoDictionaryKey: receiveBetaUpdates ? "SUFeedURL" : "LoongPassStableFeedURL") as? String
  }
  func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem,
               updateCheck: SPUUpdateCheck) throws {
    if !receiveBetaUpdates && item.displayVersionString.contains("-") {
      throw NSError(domain: UpdateContract.channel, code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "已关闭 Beta 版更新，请重新检查正式版更新。"])
    }
  }
  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    driver.transition(.downloading, version: item.displayVersionString)
  }
  func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
    driver.transition(.downloading, version: item.displayVersionString)
  }
  func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
    driver.transition(.preparing, version: item.displayVersionString)
  }
  func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) { driver.transition(.upToDate) }
  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
    let code = (error as NSError).code
    if code != Int(SUError.noUpdateError.rawValue) && code != Int(SUError.installationAuthorizeLaterError.rawValue) {
      driver.fail(error.localizedDescription)
    }
  }
  func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
               immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
    driver.ready(version: item.displayVersionString, install: immediateInstallHandler)
    // Keep Sparkle's automatic driver alive: its immediate continuation weakly
    // captures that driver, and would be lost if we returned false here.
    return true
  }
  private func publish() {
    revision += 1
    channel?.invokeMethod(UpdateContract.stateChanged, arguments: state())
  }
}
