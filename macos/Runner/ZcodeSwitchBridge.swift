// Thin native-only ownership boundary. This file does not discover a ZCode
// installation, read a key, stop an app, or configure itself from Flutter.
import Cocoa
import CoreFoundation
import FlutterMacOS

typealias ZcodeNativeOpener = (lp_zcode_gate?, UnsafeMutableRawPointer?) -> UInt64

struct ZcodeContext {
    fileprivate let sourceCredentialsURL: URL
    fileprivate let privateBackupRootURL: URL
    fileprivate let contextTag: String
    fileprivate let existingSecret: String
    fileprivate let nativeOpener: ZcodeNativeOpener?

    init(sourceCredentialsURL: URL, privateBackupRootURL: URL,
         contextTag: String, existingSecret: String) {
        self.sourceCredentialsURL = sourceCredentialsURL
        self.privateBackupRootURL = privateBackupRootURL
        self.contextTag = contextTag
        self.existingSecret = existingSecret
        self.nativeOpener = nil
    }

    // Native-only explicit-facts factory. No seed or resolver method crosses
    // Flutter; the Rust opener derives the same key context internally.
    init(sourceCredentialsURL: URL, privateBackupRootURL: URL,
         contextTag: String, nativeOpener: @escaping ZcodeNativeOpener) {
        self.sourceCredentialsURL = sourceCredentialsURL
        self.privateBackupRootURL = privateBackupRootURL
        self.contextTag = contextTag
        self.existingSecret = ""
        self.nativeOpener = nativeOpener
    }
}

/// The concrete native owner must prove the effective context and stopped
/// writers throughout each transaction. Merely conforming is NOT that proof.
/// checkStopped runs synchronously on the serial native queue at every Rust
/// source boundary. It must be thread-safe and must not reenter this bridge/ABI.
/// Resolve and compare the effective ZCode context BEFORE checking writers.
/// Throw writersActive only after context is proven current; network promotion
/// calls may accept that specific state without requiring the app to stop.
/// Throw writersActive for proven active writers, sourceChanged for changed
/// native context, and nativeContextUnavailable for missing/inconclusive proof.
/// All other errors also fail closed as NativeContextUnavailable.
/// requestStop/reopen are invoked on main, only for explicit Flutter calls.
protocol ZcodeLifecycleOwner: AnyObject {
    func checkStopped() throws
    func requestStop(completion: @escaping (Result<Void, Error>) -> Void)
    func reopen(completion: @escaping (Result<Void, Error>) -> Void)
}

/// Native-only seam, NOT an implementation or proof of availability. A future
/// owner must call the reviewed Rust promotion Worker with native approved plan
/// IDs, a stable account/context binding, a cross-process durable Store and an
/// authenticated Transport. No UI approval, pending flag or credential is input.
/// Both methods run synchronously on the existing serial queue. They must not
/// reenter the bridge, dispatch synchronously to main, or start detached work.
/// availability is local capability/context proof, not an HTTP request.
/// run must return only a completed Worker view; its Store retains pending before
/// any POST. automatic is intent only, never permission or a retry instruction.
protocol ZcodePromotionOwner: AnyObject {
    func availability() throws -> Bool
    func run(accountId: String, claim: Bool, automatic: Bool) throws -> [String: Any]
}

enum ZcodeBridgeFailure: String, Error {
    case writersActive = "WritersActive", sourceChanged = "SourceChanged"
    case unsafePath = "UnsafePath", invalidCredential = "InvalidCredential"
    case lockBusy = "LockBusy", storage = "Storage", recoveryChanged = "RecoveryChanged"
    case commitUncertain = "CommitUncertain", nativeContextUnavailable = "NativeContextUnavailable"
    case nativeCaptureRequired = "NativeCaptureRequired", cancelled = "Cancelled"
    case invalidArguments = "InvalidArguments", unsupportedMethod = "UnsupportedMethod"
    case unknownAccount = "UnknownAccount", unknownOperation = "UnknownOperation"
    case invalidResponse = "InvalidResponse", nativeUnavailable = "NativeUnavailable"
    case loginExpired = "LoginExpired"
}

final class ZcodeSwitchBridge {
    // State is main-thread-confined. A busy token covers panels, C calls, and
    // asynchronous lifecycle completions, including their main-thread reply.
    private let queue = DispatchQueue(label: "com.sailingloong.loongpass.zcode")
    private var channel: FlutterMethodChannel?
    private weak var window: NSWindow?
    private var session: ZcodeNativeSession?
    private var operation: UUID?
    private var promotionOwner: ZcodePromotionOwner?
    private var nativeGeneration = UUID()
    private var registration = UUID()
    // A malformed/throwing claim may already have posted. This defensive latch
    // has no Flutter reset and survives native owner reinstallation. It is NOT
    // a replacement for the future Worker's durable cross-process pending state.
    private var promotionUncertain = false

    func register(with messenger: FlutterBinaryMessenger, window: NSWindow) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.window = window
        let registration = UUID()
        self.registration = registration
        channel?.setMethodCallHandler(nil)
        let channel = FlutterMethodChannel(name: "com.sailingloong.loongpass/zcode", binaryMessenger: messenger)
        self.channel = channel
        channel.setMethodCallHandler { [weak self] call, result in
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.registration == registration else {
                    result(ZcodeWireReply.error(.nativeContextUnavailable)); return
                }
                self.handle(call: call, result: result)
            }
        }
    }

    /// Native host API only. No files are accessed until an explicit method.
    /// Installing an owner does not itself establish stopped writers.
    func configure(context: ZcodeContext, lifecycle: ZcodeLifecycleOwner) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        guard operation == nil else { throw ZcodeBridgeFailure.lockBusy }
        guard context.sourceCredentialsURL.isFileURL, context.privateBackupRootURL.isFileURL,
              context.sourceCredentialsURL.path.hasPrefix("/"), context.privateBackupRootURL.path.hasPrefix("/"),
              !context.contextTag.isEmpty,
              context.nativeOpener != nil || !context.existingSecret.isEmpty else {
            throw ZcodeBridgeFailure.invalidArguments
        }
        let previous = session
        let next = ZcodeNativeSession(context: context, lifecycle: lifecycle)
        session = next
        // Same native session/account catalogue and Rust Worker, no second state
        // machine. Missing optional native promotion config remains unavailable.
        promotionOwner = ZcodeRustPromotionOwner(session: next)
        nativeGeneration = UUID()
        queue.async { previous?.close() }
    }

    /// Native host teardown only; never a Flutter method. Reject, do not race,
    /// when a callback, picker, or C transaction still owns this session.
    func release() throws {
        dispatchPrecondition(condition: .onQueue(.main))
        guard operation == nil else { throw ZcodeBridgeFailure.lockBusy }
        let previous = session
        session = nil
        promotionOwner = nil
        nativeGeneration = UUID()
        queue.async { previous?.close() }
    }

    /// Native host API only. No concrete owner is installed by the default app.
    /// Installing a delegate does not implement the Rust Store/Transport gap.
    func configurePromotionOwner(_ owner: ZcodePromotionOwner?) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        guard operation == nil else { throw ZcodeBridgeFailure.lockBusy }
        promotionOwner = owner
        nativeGeneration = UUID()
    }

    func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        dispatchPrecondition(condition: .onQueue(.main))
        let request: [String: Any]
        switch call.method {
        case "status", "promotionStatus", "captureCurrent", "captureSelected", "restoreSelected", "requestStop", "reopen":
            guard call.arguments == nil || (call.arguments as? [String: Any])?.isEmpty == true else {
                result(ZcodeWireReply.error(.invalidArguments)); return
            }
            request = ["method": call.method]
        case "previewPromotions", "claimPromotions":
            let claim = call.method == "claimPromotions"
            let keys: Set<String> = claim ? ["accountId", "automatic"] : ["accountId"]
            guard let args = call.arguments as? [String: Any], Set(args.keys) == keys,
                  let id = args["accountId"] as? String, ZcodeWireReply.isID(id),
                  !claim || ZcodePromotionWireReply.boolean(args["automatic"]) != nil else {
                result(ZcodeWireReply.error(.invalidArguments)); return
            }
            request = ["method": call.method, "accountId": id,
                       "automatic": claim ? ZcodePromotionWireReply.boolean(args["automatic"])! : false]
        case "switchAccount":
            guard let args = call.arguments as? [String: Any], Set(args.keys) == Set(["accountId", "expectedRevision"]),
                  let id = args["accountId"] as? String, ZcodeWireReply.isID(id),
                  let revision = args["expectedRevision"] as? String, ZcodeWireReply.isID(revision) else {
                result(ZcodeWireReply.error(.invalidArguments)); return
            }
            request = ["method": call.method, "accountId": id, "expectedRevision": revision]
        case "restore":
            guard let args = call.arguments as? [String: Any], Set(args.keys) == Set(["operationId"]),
                  let id = args["operationId"] as? String, ZcodeWireReply.isID(id) else {
                result(ZcodeWireReply.error(.invalidArguments)); return
            }
            request = ["method": call.method, "operationId": id]
        default:
            result(ZcodeWireReply.error(.unsupportedMethod)); return
        }
        guard operation == nil else { result(ZcodeWireReply.error(.lockBusy)); return }
        if ["promotionStatus", "previewPromotions", "claimPromotions"].contains(call.method) {
            promotion(request: request, method: call.method, result: result)
            return
        }
        guard let session = session else {
            if call.method == "status" {
                result(["available": false, "reason": "NativeContextUnavailable"])
            } else { result(ZcodeWireReply.error(.nativeContextUnavailable)) }
            return
        }
        let token = UUID()
        operation = token
        switch call.method {
        case "captureSelected", "restoreSelected":
            choose(method: call.method, session: session, token: token, result: result)
        case "requestStop", "reopen":
            lifecycle(method: call.method, session: session, token: token, result: result)
        default:
            run(request: request, method: call.method, session: session, token: token, result: result)
        }
    }

    private func promotion(request: [String: Any], method: String, result: @escaping FlutterResult) {
        guard let owner = promotionOwner else {
            if method == "promotionStatus" {
                result(["available": false, "reason": ZcodeBridgeFailure.nativeContextUnavailable.rawValue])
            } else {
                result(ZcodeWireReply.error(.nativeContextUnavailable))
            }
            return
        }
        if promotionUncertain && method != "previewPromotions" {
            if method == "promotionStatus" {
                result(["available": false, "reason": ZcodeBridgeFailure.commitUncertain.rawValue])
            } else {
                result(ZcodePromotionWireReply.unknownResult())
            }
            return
        }
        let token = UUID()
        let generation = nativeGeneration
        let registration = self.registration
        let wasUncertain = promotionUncertain
        operation = token
        queue.async { [self, owner] in
            var uncertain = false
            let value: Any
            do {
                let available = try owner.availability()
                if method == "promotionStatus" {
                    if available { value = ["available": true] }
                    else { value = ["available": false, "reason": ZcodeBridgeFailure.nativeContextUnavailable.rawValue] }
                } else if !available {
                    value = ZcodeWireReply.error(.nativeContextUnavailable)
                } else {
                    // Availability is checked before entering the possibly
                    // mutating method. Every subsequent error is uncertain.
                    let claim = method == "claimPromotions"
                    uncertain = claim
                    let raw = try owner.run(accountId: request["accountId"] as! String,
                                            claim: claim, automatic: request["automatic"] as! Bool)
                    if var safe = ZcodePromotionWireReply.sanitize(raw),
                       !claim || !["unknown", "claimable"].contains(safe["status"] as? String ?? "unknown") {
                        // The original Worker remains the reconciliation
                        // authority. Preview can inspect its durable pending
                        // state; a UI result cannot reset this session's latch.
                        if wasUncertain { safe["canClaim"] = false }
                        value = safe
                        uncertain = false
                    } else {
                        if claim { value = ZcodePromotionWireReply.unknownResult() }
                        else { value = ZcodeWireReply.error(.storage) }
                    }
                }
            } catch {
                let failure = (error as? ZcodeBridgeFailure) ?? .nativeContextUnavailable
                if method == "promotionStatus" {
                    value = ["available": false, "reason": failure.rawValue]
                } else {
                    if uncertain { value = ZcodePromotionWireReply.unknownResult() }
                    else { value = ZcodeWireReply.error(failure) }
                }
            }
            DispatchQueue.main.async { [self, owner] in
                guard self.operation == token else { return }
                // Retain the owner through its synchronous work and reply. A
                // queued result may not enter a replacement channel/context.
                if uncertain { self.promotionUncertain = true }
                guard self.nativeGeneration == generation, self.promotionOwner === owner,
                      self.registration == registration else {
                    self.finish(token: token, value: ZcodeWireReply.error(.nativeContextUnavailable), result: result)
                    return
                }
                self.finish(token: token, value: value, result: result)
            }
        }
    }

    private func choose(method: String, session: ZcodeNativeSession, token: UUID,
                        result: @escaping FlutterResult) {
        guard let window = window else {
            finish(token: token, value: ZcodeWireReply.error(.nativeContextUnavailable), result: result); return
        }
        let restore = method == "restoreSelected"
        let panel = NSOpenPanel()
        panel.title = restore ? "选择 ZCode 恢复操作目录" : "选择 ZCode 认证 JSON"
        panel.message = restore ? "只对所选操作进行条件恢复；源文件有新变化时拒绝覆盖。" : "仅导入所选文件中的账号，不切换当前账号。"
        panel.prompt = restore ? "选择并恢复" : "选择并导入"
        panel.canChooseFiles = !restore
        panel.canChooseDirectories = restore
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        let generation = nativeGeneration
        let registration = self.registration
        panel.beginSheetModal(for: window) { [self, session] response in
            guard response == .OK, let selectedURL = panel.url else {
                self.finish(token: token, value: ZcodeWireReply.error(.cancelled), result: result); return
            }
            guard self.operation == token, self.session === session,
                  self.nativeGeneration == generation, self.registration == registration else {
                selectedURL.stopAccessingSecurityScopedResource()
                self.finish(token: token, value: ZcodeWireReply.error(.nativeContextUnavailable), result: result)
                return
            }
            // Match MainFlutterWindow's existing NSOpenPanel pattern: the panel
            // supplies an implicit grant. Retain its exact URL through C work,
            // then balance it with one stop. Do not start a second grant.
            self.run(request: ["method": method, "path": selectedURL.path], method: method,
                session: session, token: token, selectedURL: selectedURL, result: result)
        }
    }

    private func lifecycle(method: String, session: ZcodeNativeSession, token: UUID,
                           result: @escaping FlutterResult) {
        var completionReceived = false // Read and written only on main.
        let generation = nativeGeneration
        let registration = self.registration
        let completion: (Result<Void, Error>) -> Void = { [weak self, weak session] outcome in
            DispatchQueue.main.async { [weak self, weak session] in
                guard !completionReceived else { return }
                completionReceived = true
                guard let self = self else { result(ZcodeWireReply.error(.nativeContextUnavailable)); return }
                guard self.operation == token else { return }
                guard let session = session, self.session === session, self.nativeGeneration == generation,
                      self.registration == registration else {
                    self.finish(token: token, value: ZcodeWireReply.error(.nativeContextUnavailable), result: result)
                    return
                }
                switch outcome {
                case .failure(let error):
                    self.finish(token: token, value: ZcodeWireReply.error(
                        (error as? ZcodeBridgeFailure) ?? .nativeContextUnavailable), result: result)
                case .success:
                    guard let current = self.session else {
                        self.finish(token: token, value: ZcodeWireReply.error(.nativeContextUnavailable), result: result); return
                    }
                    self.run(request: ["method": "status"], method: "status", session: current,
                             token: token, result: result)
                }
            }
        }
        if method == "requestStop" { session.lifecycle.requestStop(completion: completion) }
        else { session.lifecycle.reopen(completion: completion) }
    }

    private func run(request: [String: Any], method: String, session: ZcodeNativeSession,
                     token: UUID, selectedURL: URL? = nil, result: @escaping FlutterResult) {
        // Strong captures keep callback userdata and security scope alive until
        // the synchronous C call completes. Configuration cannot change while busy.
        let generation = nativeGeneration
        let registration = self.registration
        queue.async { [self, session] in
            let reply = session.call(request: request, method: method)
            DispatchQueue.main.async {
                selectedURL?.stopAccessingSecurityScopedResource()
                guard self.session === session, self.nativeGeneration == generation,
                      self.registration == registration else {
                    self.finish(token: token, value: ZcodeWireReply.error(.nativeContextUnavailable), result: result)
                    return
                }
                self.finish(token: token, value: reply, result: result)
            }
        }
    }

    private func finish(token: UUID, value: Any?, result: FlutterResult) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard operation == token else { return }
        operation = nil
        result(value)
    }

    deinit {
        let previous = session
        queue.async { previous?.close() }
    }
}

/// Strict projection of the reviewed Worker's view. No raw response, plans,
/// prior-instance IDs, credentials, errors, or paths cross into Flutter.
enum ZcodePromotionWireReply {
    private static let statuses: Set<String> = [
        "unknown", "claimable", "claimed", "noClaim", "verificationRequired",
        "loginExpired", "resultPending", "cancelled"
    ]
    private static let reasons: Set<String> = [
        "confirmResult", "loginExpired", "openOfficialClient", "notDue", "verifyAgain",
        "alreadyClaimed", "noServerOffer", "activitySelectionRequired"
    ]

    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func label(_ value: Any) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 256,
              text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              text.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return text
    }

    private static func unixSeconds(_ value: Any) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType)),
              number.doubleValue >= 0,
              number.doubleValue <= 253_402_300_799 else { return nil }
        // Explicit seconds, bounded to Unix epoch...year 9999. Millisecond dates and
        // floats fail closed instead of being silently converted.
        return number.int64Value
    }

    // The bridge cannot prove that a malformed owner persisted pending. Report
    // unknown, not the Worker's durable resultPending state, and invent no plan ID.
    static func unknownResult() -> [String: Any] {
        ["status": "unknown", "canClaim": false, "reason": "confirmResult",
         "windowPolicy": "serverPreview", "exactOfferWindow": NSNull()]
    }

    static func sanitize(_ value: [String: Any]) -> [String: Any]? {
        guard let status = value["status"] as? String, statuses.contains(status),
              let canClaim = boolean(value["canClaim"]), !canClaim || status == "claimable",
              value["windowPolicy"] as? String == "serverPreview",
              value["exactOfferWindow"] is NSNull else { return nil }
        var safe: [String: Any] = ["status": status, "canClaim": canClaim,
                                  "windowPolicy": "serverPreview", "exactOfferWindow": NSNull()]
        for key in ["planId", "planName"] {
            if let raw = value[key], !(raw is NSNull) {
                guard let text = label(raw) else { return nil }
                safe[key] = text
            }
        }
        if ["claimable", "claimed", "verificationRequired", "resultPending"].contains(status),
           safe["planId"] == nil { return nil }
        if let raw = value["reason"], !(raw is NSNull) {
            guard let reason = raw as? String, reasons.contains(reason) else { return nil }
            safe["reason"] = reason
        }
        for key in ["startsAt", "endsAt", "checkedAt"] {
            if let raw = value[key], !(raw is NSNull) {
                guard let seconds = unixSeconds(raw) else { return nil }
                safe[key] = seconds
            }
        }
        return safe
    }
}

private let zcodeGate: lp_zcode_gate = { userdata in
    guard let userdata = userdata else { return 3 }
    let session = Unmanaged<ZcodeNativeSession>.fromOpaque(userdata).takeUnretainedValue()
    do { try session.lifecycle.checkStopped(); return 0 }
    catch ZcodeBridgeFailure.writersActive { return 1 }
    catch ZcodeBridgeFailure.sourceChanged { return 2 }
    catch { return 3 }
}

private final class ZcodeNativeSession {
    private let context: ZcodeContext
    let lifecycle: ZcodeLifecycleOwner
    private var handle: UInt64 = 0 // Access only on the bridge's serial queue.
    private var safety = ZcodeReplySafety()

    init(context: ZcodeContext, lifecycle: ZcodeLifecycleOwner) {
        self.context = context
        self.lifecycle = lifecycle
    }

    func call(request: [String: Any], method: String) -> Any {
        if let blocked = safety.blockedReply(method: method) { return blocked }
        do {
            if handle == 0 {
                let userdata = Unmanaged.passUnretained(self).toOpaque()
                if let open = context.nativeOpener {
                    handle = open(zcodeGate, userdata)
                } else {
                    // Legacy explicit-native initializer remains for the frozen
                    // synthetic tests. Production must supply accurate facts.
                    let config = try JSONSerialization.data(withJSONObject: [
                        "source": context.sourceCredentialsURL.path,
                        "backupRoot": context.privateBackupRootURL.path,
                        "context": context.contextTag, "secret": context.existingSecret
                    ])
                    handle = config.withUnsafeBytes { bytes in
                        lp_zcode_open(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                                      zcodeGate, userdata)
                    }
                }
                guard handle != 0 else { return ZcodeWireReply.error(.nativeContextUnavailable) }
            }
            let data = try JSONSerialization.data(withJSONObject: request)
            let pointer = data.withUnsafeBytes { bytes in
                lp_zcode_call(handle, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
            }
            guard let pointer = pointer else {
                return safety.observe(ZcodeWireReply.unreadable(method: method), method: method)
            }
            defer { lp_zcode_free(pointer) }
            guard let json = String(validatingUTF8: pointer) else {
                return safety.observe(ZcodeWireReply.unreadable(method: method), method: method)
            }
            return safety.observe(ZcodeWireReply.decode(Data(json.utf8), method: method), method: method)
        } catch { return ZcodeWireReply.error(.invalidArguments) }
    }

    func close() {
        if handle != 0 { lp_zcode_close(handle); handle = 0 }
    }
}

private final class ZcodeRustPromotionOwner: ZcodePromotionOwner {
    private weak var session: ZcodeNativeSession?
    init(session: ZcodeNativeSession) { self.session = session }
    func availability() throws -> Bool {
        guard let session = session else { throw ZcodeBridgeFailure.nativeContextUnavailable }
        let reply = session.call(request: ["method": "promotionStatus"], method: "promotionStatus")
        if let failure = reply as? FlutterError {
            throw ZcodeBridgeFailure(rawValue: failure.code) ?? .nativeContextUnavailable
        }
        guard let value = reply as? [String: Any],
              let available = ZcodePromotionWireReply.boolean(value["available"]) else {
            throw ZcodeBridgeFailure.nativeContextUnavailable
        }
        if !available {
            guard let reason = value["reason"] as? String,
                  let failure = ZcodeBridgeFailure(rawValue: reason) else {
                throw ZcodeBridgeFailure.nativeContextUnavailable
            }
            throw failure
        }
        return true
    }
    func run(accountId: String, claim: Bool, automatic: Bool) throws -> [String: Any] {
        guard let session = session else { throw ZcodeBridgeFailure.nativeContextUnavailable }
        let method = claim ? "claimPromotions" : "previewPromotions"
        var request: [String: Any] = ["method": method, "accountId": accountId]
        if claim { request["automatic"] = automatic }
        let reply = session.call(request: request, method: method)
        if let failure = reply as? FlutterError {
            throw ZcodeBridgeFailure(rawValue: failure.code) ?? .storage
        }
        guard let value = reply as? [String: Any] else { throw ZcodeBridgeFailure.storage }
        return value
    }
}

/// A lost/malformed post-write reply can be uncertain even if Rust completed.
/// Keep this session blocked until an explicit conditional recovery succeeds.
struct ZcodeReplySafety {
    private var uncertain = false
    func blockedReply(method: String) -> Any? {
        guard uncertain else { return nil }
        if method == "status" { return ["available": false, "reason": "CommitUncertain"] }
        if method == "restore" || method == "restoreSelected" { return nil }
        return ZcodeWireReply.error(.commitUncertain)
    }
    mutating func observe(_ reply: Any, method: String) -> Any {
        if let error = reply as? FlutterError {
            if error.code == "CommitUncertain" { uncertain = true }
        } else if (method == "restore" || method == "restoreSelected"),
                  let value = reply as? [String: Any], let outcome = value["outcome"] as? String,
                  ["restored", "unchanged"].contains(outcome) {
            uncertain = false
        }
        return reply
    }
}

/// Never return raw C errors, arbitrary objects, secrets, or paths to Flutter.
enum ZcodeWireReply {
    static func isID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func error(_ code: ZcodeBridgeFailure) -> FlutterError {
        FlutterError(code: code.rawValue, message: nil,
                     details: code == .commitUncertain ? ["outcome": "unknown"] : nil)
    }
    static func unreadable(method: String) -> FlutterError {
        error(["switchAccount", "restore", "restoreSelected"].contains(method) ? .commitUncertain : .storage)
    }
    static func decode(_ data: Data, method: String) -> Any {
        guard let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return unreadable(method: method)
        }
        if let rawError = value["error"] {
            guard let raw = rawError as? String, let code = ZcodeBridgeFailure(rawValue: raw) else {
                return unreadable(method: method)
            }
            return error(code)
        }
        switch method {
        case "status", "promotionStatus":
            guard let available = value["available"] as? NSNumber,
                  CFGetTypeID(available) == CFBooleanGetTypeID() else { return unreadable(method: method) }
            if available.boolValue { return ["available": true] }
            guard let raw = value["reason"] as? String, let reason = ZcodeBridgeFailure(rawValue: raw) else {
                return unreadable(method: method)
            }
            return ["available": false, "reason": reason.rawValue]
        case "previewPromotions", "claimPromotions":
            return ZcodePromotionWireReply.sanitize(value) ?? unreadable(method: method)
        case "captureCurrent", "captureSelected":
            guard let id = value["accountId"] as? String, isID(id),
                  let revision = value["revision"] as? String, isID(revision),
                  let family = value["family"] as? String, ["zai", "bigmodel"].contains(family) else {
                return unreadable(method: method)
            }
            var safe: [String: Any] = ["accountId": id, "revision": revision, "family": family]
            if let label = value["label"] as? String { safe["label"] = label }
            return safe
        case "switchAccount", "restore", "restoreSelected":
            let allowed = method == "switchAccount" ? ["switched", "unchanged"] : ["restored", "unchanged"]
            guard let outcome = value["outcome"] as? String, allowed.contains(outcome) else {
                return unreadable(method: method)
            }
            if let id = value["operationId"] as? String, isID(id) {
                return ["outcome": outcome, "operationId": id]
            }
            if value["operationId"] is NSNull { return ["outcome": outcome, "operationId": NSNull()] }
            return unreadable(method: method)
        default: return error(.unsupportedMethod)
        }
    }
}
