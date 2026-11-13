import Foundation
import Sparkle

@main struct UpdateDriverChecks {
  static func main() {
    let driver = AppUpdateUserDriver()
    var installed = 0
    var skipped = 0
    driver.showDownloadInitiated(cancellation: {})
    precondition(driver.phase == .downloading && driver.progress == nil && !driver.canInstall)
    driver.showDownloadDidReceiveData(ofLength: 25)
    precondition(driver.progress == nil)
    driver.showDownloadDidReceiveExpectedContentLength(100)
    precondition(driver.progress == 0.25)
    driver.showDownloadDidReceiveData(ofLength: 100)
    precondition(driver.progress == 1)
    driver.showDownloadDidStartExtractingUpdate()
    precondition(driver.phase == .preparing && !driver.canInstall && driver.progress == nil)
    driver.showReady(toInstallAndRelaunch: { choice in
      if choice == .install { installed += 1 }
      if choice == .skip { skipped += 1 }
    })
    precondition(installed == 0 && driver.canInstall && driver.canSkip)
    precondition(driver.install())
    precondition(driver.phase == .installing && installed == 1 && !driver.install() && !driver.skip())
    driver.showReady(toInstallAndRelaunch: { choice in if choice == .skip { skipped += 1 } })
    precondition(driver.skip() && skipped == 1 && !driver.canInstall && !driver.skip())
    // The automatic native driver continuation survives a UI-cycle dismissal.
    driver.ready(version: "2.0.0", install: { installed += 1 })
    driver.dismissUpdateInstallation()
    precondition(driver.phase == .ready && driver.canInstall && !driver.canSkip)
    precondition(driver.install() && installed == 2 && !driver.install())
    driver.ready(version: "2.0.1", install: { installed += 1 })
    driver.fail("signature fixture failure")
    precondition(driver.phase == .error && !driver.canInstall && !driver.install() && installed == 2)
    var acknowledged = 0
    driver.showUpdateNotFoundWithError(NSError(domain: "fixture", code: 1, userInfo: [SPUNoUpdateFoundReasonKey: SPUNoUpdateFoundReason.onLatestVersion.rawValue]), acknowledgement: { acknowledged += 1 })
    precondition(driver.phase == .upToDate && acknowledged == 1)
    driver.showUpdaterError(NSError(domain: "fixture", code: 2), acknowledgement: { acknowledged += 1 })
    precondition(driver.phase == .error && acknowledged == 2)
    driver.showUpdateNotFoundWithError(NSError(domain: "fixture", code: 1,
      userInfo: [SPUNoUpdateFoundReasonKey: SPUNoUpdateFoundReason.hardwareDoesNotSupportARM64.rawValue]), acknowledgement: {})
    if driver.phase != .error || driver.error == nil {
      print("FAIL unsupported hardware was reported as already up-to-date")
      exit(1)
    }
    driver.showDownloadDidStartExtractingUpdate()
    driver.dismissUpdateInstallation()
    driver.finishCycle(error: NSError(domain: "fixture", code: Int(SUError.installationAuthorizeLaterError.rawValue)))
    if !driver.ownsCandidate || driver.phase != .error {
      print("FAIL deferred authorization lost the retained native candidate")
      exit(1)
    }
    driver.automaticUpdates = { false }
    driver.show(SPUUpdatePermissionRequest(systemProfile: []), reply: { response in
      precondition(!response.automaticUpdateChecks && !response.sendSystemProfile)
    })
    print("Sparkle 2.10.1 user-driver lifecycle checks passed")
  }
}
