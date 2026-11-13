import Cocoa
import Sparkle

/// Sparkle supplies every lifecycle event and continuation; this driver owns no
/// transport, signature verifier, installer or scheduling policy.
final class AppUpdateUserDriver: NSObject, SPUUserDriver {
  var changed: (() -> Void)?
  var automaticUpdates: () -> Bool = { false }
  private(set) var phase: UpdatePhase = .idle
  private(set) var offeredVersion: String?
  private(set) var progress: Double?
  private(set) var error: String?
  private var expected: UInt64 = 0
  private var received: UInt64 = 0
  private var installHandler: (() -> Void)?
  private var skipHandler: (() -> Void)?
  // Automatic Sparkle installations retain their driver via the delegate.
  private var automaticInstallation = false
  var canInstall: Bool { phase == .ready && installHandler != nil }
  var canSkip: Bool { phase == .ready && skipHandler != nil }
  var ownsCandidate: Bool { [.downloading, .preparing, .ready, .installing].contains(phase) }

  func transition(_ phase: UpdatePhase, version: String? = nil, progress: Double? = nil) {
    self.phase = phase
    if let version { offeredVersion = version }
    self.progress = progress
    error = nil
    changed?()
  }

  func fail(_ message: String) {
    installHandler = nil
    skipHandler = nil
    automaticInstallation = false
    error = message
    phase = .error
    progress = nil
    changed?()
  }

  func ready(version: String, install: @escaping () -> Void) {
    automaticInstallation = true
    installHandler = install
    skipHandler = nil // Sparkle's automatic driver has no cancel continuation.
    transition(.ready, version: version)
  }

  @discardableResult func install() -> Bool {
    guard canInstall, let action = installHandler else { return false }
    installHandler = nil
    skipHandler = nil
    transition(.installing)
    action()
    return true
  }

  @discardableResult func skip() -> Bool {
    guard canSkip, let action = skipHandler else { return false }
    installHandler = nil
    skipHandler = nil
    automaticInstallation = false
    offeredVersion = nil
    transition(.idle)
    action()
    return true
  }

  func show(_ request: SPUUpdatePermissionRequest,
                                  reply: @escaping (SUUpdatePermissionResponse) -> Void) {
    reply(SUUpdatePermissionResponse(automaticUpdateChecks: automaticUpdates(), sendSystemProfile: false))
  }
  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { transition(.checking) }

  func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                       reply: @escaping (SPUUserUpdateChoice) -> Void) {
    offeredVersion = appcastItem.displayVersionString
    guard !appcastItem.isInformationOnlyUpdate else {
      fail("此版本需通过官网下载，请查看 loongpass.com。")
      reply(.dismiss)
      return
    }
    if state.stage == .installing {
      installHandler = { reply(.install) }
      skipHandler = { reply(.skip) }
      transition(.ready)
    } else {
      transition(state.stage == .notDownloaded ? .downloading : .preparing)
      reply(.install) // Download/prepare now; the ready callback still waits for the user.
    }
  }

  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
  func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
    transition(.upToDate)
    acknowledgement()
  }
  func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
    fail(error.localizedDescription)
    acknowledgement()
  }
  func showDownloadInitiated(cancellation: @escaping () -> Void) {
    expected = 0
    received = 0
    transition(.downloading)
  }
  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
    expected = expectedContentLength
    downloadProgress()
  }
  func showDownloadDidReceiveData(ofLength length: UInt64) {
    received += length
    downloadProgress()
  }
  private func downloadProgress() {
    transition(.downloading, progress: expected > 0 ? min(1, Double(received) / Double(expected)) : nil)
  }
  func showDownloadDidStartExtractingUpdate() { transition(.preparing) }
  func showExtractionReceivedProgress(_ progress: Double) { transition(.preparing, progress: progress) }
  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    automaticInstallation = false
    installHandler = { reply(.install) }
    skipHandler = { reply(.skip) }
    transition(.ready)
  }
  func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                            retryTerminatingApplication: @escaping () -> Void) {
    transition(.installing)
  }
  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
    installHandler = nil
    skipHandler = nil
    automaticInstallation = false
    transition(.idle)
    acknowledgement()
  }
  func dismissUpdateInstallation() {
    // A prepared automatic installation can outlive the UI update cycle.
    guard !automaticInstallation else { return }
    installHandler = nil
    skipHandler = nil
    if ownsCandidate { offeredVersion = nil; transition(.idle) }
  }
  func showUpdateInFocus() {} // The application already shows status inline.
}
