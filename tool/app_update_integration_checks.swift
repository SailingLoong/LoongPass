import Cocoa
import FlutterMacOS

final class UpdateMessenger: NSObject, FlutterBinaryMessenger {
  let codec = FlutterStandardMethodCodec.sharedInstance()
  var handler: FlutterBinaryMessageHandler?
  var snapshots: [[String: Any]] = []

  func send(onChannel channel: String, message: Data?) {
    if let message, let state = codec.decodeMethodCall(message).arguments as? [String: Any] {
      snapshots.append(state)
    }
  }
  func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply?) {
    send(onChannel: channel, message: message)
    callback?(codec.encodeSuccessEnvelope(nil))
  }
  func setMessageHandlerOnChannel(_ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler?) -> FlutterBinaryMessengerConnection {
    self.handler = handler
    return 1
  }
  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) { handler = nil }
  func state() -> [String: Any] {
    var result: [String: Any] = [:]
    handler?(codec.encode(FlutterMethodCall(methodName: UpdateContract.state, arguments: nil))) { data in
      if let data { result = self.codec.decodeEnvelope(data) as? [String: Any] ?? [:] }
    }
    return result
  }
}

@main struct UpdateIntegrationChecks {
  static func main() {
    _ = NSApplication.shared
    let mode = CommandLine.arguments[1]
    let defaults = UserDefaults.standard
    let identifier = Bundle.main.bundleIdentifier!
    precondition(identifier.hasPrefix("com.sailingloong.smoke.update-"))
    if mode != "restart" {
      defaults.removePersistentDomain(forName: identifier)
      if mode == "checks-off" { defaults.set(false, forKey: "SUEnableAutomaticChecks") }
      if mode == "downloads-off" { defaults.set(false, forKey: "SUAutomaticallyUpdate") }
    }
    let messenger = UpdateMessenger()
    let owner = AppUpdater()
    owner.register(with: messenger)
    let expected = ["fresh", "restart", "schedule"].contains(mode)
    guard messenger.state()[UpdateContract.automaticUpdates] as? Bool == expected else {
      print("FAIL automatic preference changed during \(mode)"); exit(1)
    }
    if !expected {
      print("PASS legacy opt-out preserved: \(mode)")
      return
    }
    let deadline = Date(timeIntervalSinceNow: 8)
    while Date() < deadline {
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
      if mode == "schedule" {
        let state = messenger.state()
        if let last = state[UpdateContract.lastCheckAt] as? NSNumber,
           let next = state[UpdateContract.nextCheckAt] as? NSNumber {
          guard abs(next.int64Value - last.int64Value - 3_600_000) < 3_000 else {
            print("FAIL native hourly schedule interval"); exit(1)
          }
          print("PASS native next check is one hour after the last check")
          return
        }
        continue
      }
      if messenger.snapshots.contains(where: {
        ($0[UpdateContract.downloadedBytes] as? NSNumber)?.int64Value ?? 0 > 0 &&
          ($0[UpdateContract.progress] as? NSNumber)?.doubleValue ?? 0 > 0
      }) {
        print("PASS native scheduled download exposes bytes and progress: \(mode)")
        return
      }
    }
    print("FAIL scheduled download had no byte progress: \(mode), phases=\(messenger.snapshots.compactMap { $0[UpdateContract.phase] })")
    exit(1)
  }
}
