import AppKit
import CoreGraphics
import Foundation

// The release app uses the logged-in user's data. Exercise it on the fresh CI user.
guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
      CommandLine.arguments.count == 2,
      let bundle = Bundle(url: URL(fileURLWithPath: CommandLine.arguments[1])),
      let executable = bundle.executableURL else { exit(2) }

func windowSize(for pid: pid_t) -> CGSize? {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    for window in windows {
        guard window[kCGWindowOwnerPID as String] as? Int32 == pid,
              window[kCGWindowLayer as String] as? Int == 0,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? Double, width >= 480,
              let height = bounds["Height"] as? Double, height >= 400 else { continue }
        return CGSize(width: width, height: height)
    }
    return nil
}

func checkWindow() throws {
    let app = Process()
    app.executableURL = executable
    try app.run()
    defer { if app.isRunning { app.terminate() } }
    let timeout = Date().addingTimeInterval(30)
    while app.isRunning && Date() < timeout {
        if let size = windowSize(for: app.processIdentifier) {
            print("macOS release window: \(Int(size.width)) x \(Int(size.height)), build \(bundle.object(forInfoDictionaryKey: "CFBundleVersion") ?? "")")
            return
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    throw NSError(domain: "LoongPassWindowChecks", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "The release process did not present its main window."
    ])
}

try checkWindow()
