import Cocoa
import FlutterMacOS

@main
@MainActor
class AppDelegate: FlutterAppDelegate {
  private var terminationPending = false
  let codexAccounts = CodexBridge()

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminationPending else { return .terminateLater }
    terminationPending = true
    Task { @MainActor in
      await self.codexAccounts.shutdown()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
