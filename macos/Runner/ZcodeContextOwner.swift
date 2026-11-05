// Native-only context/lifecycle owner. Default discovery remains unavailable.
// No ProcessInfo.environment, settings read, credentials read or implicit launch.
import Cocoa
import Darwin

struct ZcodeOwnerApp: Codable, Equatable {
    var bundleId: String
    var bundlePath: String
    var executablePath: String
    // Selected executable physical identity; a directory-only stat is insufficient.
    var device: UInt64
    var inode: UInt64
}
struct ZcodeOwnerProcess: Codable, Equatable {
    var pid: Int32
    var uid: UInt32
    var startedSeconds: UInt64
    var startedMicroseconds: UInt32
    var executablePath: String
}
struct ZcodeOwnerRuntimeContext: Codable, Equatable {
    var origin: String
    var credentialPlatform: String
    var requestPlatform: String
}
struct ZcodeOwnerBinding: Codable {
    var app: ZcodeOwnerApp
    var contextId: String
    var uid: UInt32
    var main: ZcodeOwnerProcess?
    var runtimeContext: ZcodeOwnerRuntimeContext? = nil
}
struct ZcodeOwnerSnapshot: Codable {
    var app: ZcodeOwnerApp
    var contextId: String
    // The native producer must enumerate all possible writers, including orphan
    // helpers and other app copies sharing the data root. NSWorkspace alone is
    // not a complete process observation and must not set this flag to true.
    var complete: Bool
    var otherWriters: Bool
    var processes: [ZcodeOwnerProcess]
    // Re-observed by the same authoritative snapshot producer on every gate.
    // Omitted is only compatible with the historical switch-only binding.
    var runtimeContext: ZcodeOwnerRuntimeContext? = nil
}
struct ZcodeOwnerLaunchContract {
    enum Mode { case capturedLaunch, controlledLaunch }
    let contextId: String
    let mode: Mode
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let currentDirectoryURL: URL
}

private struct ZcodeOwnerDecisionRequest: Encodable {
    let action: String
    let binding: ZcodeOwnerBinding
    let snapshot: ZcodeOwnerSnapshot
    let launchContextId: String?
}
private struct ZcodeOwnerDecision: Decodable {
    let decision: String?
    let error: String?
    let target: ZcodeOwnerProcess?
}
private struct ZcodeOwnerFactApp: Decodable { let app: ZcodeOwnerApp }
private struct ZcodeOwnerMetadata: Decodable {
    let source: String?
    let contextId: String?
    let error: String?
    let runtimeContext: ZcodeOwnerRuntimeContext?
}

// One serialization path to the actual Rust decisions for both orchestration
// and the final pre-effect checks in the concrete macOS operations.
private func zcodeOwnerDecision(_ request: ZcodeOwnerDecisionRequest) throws -> ZcodeOwnerDecision {
    let data = try JSONEncoder().encode(request)
    let pointer = data.withUnsafeBytes { bytes in
        lp_zcode_owner_decide(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
    }
    guard let pointer = pointer else { throw ZcodeBridgeFailure.nativeContextUnavailable }
    defer { lp_zcode_free(pointer) }
    let result = try JSONDecoder().decode(ZcodeOwnerDecision.self, from: Data(bytes: pointer, count: strlen(pointer)))
    if let error = result.error {
        throw ZcodeBridgeFailure(rawValue: error) ?? .nativeContextUnavailable
    }
    return result
}

/// The owned buffer is erased at release. Swift/Data callers must also erase
/// their own input copies; this class cannot erase memory owned by a producer.
private final class ZcodeNativeOwnerBytes {
    let count: Int
    private let pointer: UnsafeMutablePointer<UInt8>
    init(_ data: Data) {
        count = data.count
        pointer = .allocate(capacity: max(1, count))
        data.copyBytes(to: pointer, count: count)
    }
    func withBytes<T>(_ action: (UnsafePointer<UInt8>, Int) -> T) -> T {
        action(UnsafePointer(pointer), count)
    }
    deinit {
        // memset_s is not optimized away as a dead store on the macOS target.
        _ = memset_s(pointer, max(1, count), 0, count)
        pointer.deallocate()
    }
}

final class ZcodeContextOwner: ZcodeLifecycleOwner {
    enum LifecycleIssue { case stopRefused, stopTimedOut, missingLaunchContract, reopenOutcomeUnknown }
    static let missingProductionContracts = [
        "effective ZCode runtime setting and launch environment",
        "early dataBaseDir bootstrap and ready-time settings application",
        "effective target endpoint origin and target process platform-architecture",
        "complete selected-context writer snapshot with process start identity",
        "verified captured launch or explicitly supplied controlled launch contract"
    ]

    // Intentionally blocked: static app code does not prove the user's effective
    // runtime setting, environment or original arguments. No guessed defaults.
    static func production() throws -> ZcodeContextOwner {
        throw ZcodeBridgeFailure.nativeContextUnavailable
    }

    private let stateLock = NSLock()
    private var binding: ZcodeOwnerBinding
    private var busy = false
    private let snapshot: () throws -> ZcodeOwnerSnapshot
    private let terminate: (ZcodeOwnerProcess) throws -> Bool
    private let launch: (ZcodeOwnerLaunchContract) throws -> ZcodeOwnerProcess
    private let launchContract: ZcodeOwnerLaunchContract?
    private let timeout: TimeInterval
    private let now: () -> TimeInterval
    private let schedule: (@escaping () -> Void) -> Void
    private(set) var lastLifecycleIssue: LifecycleIssue?

    /// All closures are native-only. Snapshot must be thread-safe and must not
    /// reenter this owner/bridge; terminate and launch are called only on main.
    /// Their implementations must revalidate exact identity immediately before
    /// the effect. No closure receives Flutter-supplied paths or context claims.
    init(binding: ZcodeOwnerBinding,
         snapshot: @escaping () throws -> ZcodeOwnerSnapshot,
         terminate: @escaping (ZcodeOwnerProcess) throws -> Bool,
         launch: @escaping (ZcodeOwnerLaunchContract) throws -> ZcodeOwnerProcess,
         launchContract: ZcodeOwnerLaunchContract? = nil,
         timeout: TimeInterval = 10,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping (@escaping () -> Void) -> Void = { work in
             DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
         }) {
        self.binding = binding
        self.snapshot = snapshot
        self.terminate = terminate
        self.launch = launch
        self.launchContract = launchContract
        self.timeout = max(0.1, timeout)
        self.now = now
        self.schedule = schedule
    }

    /// Native producer passes facts, not Flutter. Metadata/open use the same
    /// immutable input bytes. No seed/key is returned from Rust to Swift.
    func makeContext(nativeFacts: Data, nativeOptions: Data,
                     privateBackupRootURL: URL) throws -> ZcodeContext {
        let facts = ZcodeNativeOwnerBytes(nativeFacts)
        let options = ZcodeNativeOwnerBytes(nativeOptions)
        let pointer = facts.withBytes { lp_zcode_owner_metadata($0, $1) }
        guard let pointer = pointer else { throw ZcodeBridgeFailure.nativeContextUnavailable }
        defer { lp_zcode_free(pointer) }
        let metadata = try JSONDecoder().decode(ZcodeOwnerMetadata.self, from: Data(bytes: pointer, count: strlen(pointer)))
        let expected = currentBinding()
        let suppliedApp = try JSONDecoder().decode(ZcodeOwnerFactApp.self, from: nativeFacts).app
        guard suppliedApp == expected.app else { throw ZcodeBridgeFailure.sourceChanged }
        guard metadata.error == nil, let source = metadata.source, let contextId = metadata.contextId,
              contextId == expected.contextId,
              metadata.runtimeContext == expected.runtimeContext else { throw ZcodeBridgeFailure.sourceChanged }
        // Options are native-only, but verify the displayed backup root matches
        // the very same options passed to Rust rather than carrying two roots.
        guard let json = try JSONSerialization.jsonObject(with: nativeOptions) as? [String: Any],
              json["backupRoot"] as? String == privateBackupRootURL.path else {
            throw ZcodeBridgeFailure.invalidArguments
        }
        return ZcodeContext(sourceCredentialsURL: URL(fileURLWithPath: source),
            privateBackupRootURL: privateBackupRootURL, contextTag: contextId,
            nativeOpener: { gate, userdata in
                facts.withBytes { factsPointer, factsCount in
                    options.withBytes { optionsPointer, optionsCount in
                        lp_zcode_owner_open(factsPointer, factsCount, optionsPointer, optionsCount, gate, userdata)
                    }
                }
            })
    }

    private func currentBinding() -> ZcodeOwnerBinding {
        stateLock.lock(); defer { stateLock.unlock() }
        return binding
    }
    private func decide(_ action: String, binding: ZcodeOwnerBinding? = nil,
                        launchContextId: String? = nil) throws -> ZcodeOwnerDecision {
        let request = ZcodeOwnerDecisionRequest(action: action, binding: binding ?? currentBinding(),
            snapshot: try snapshot(), launchContextId: launchContextId)
        return try zcodeOwnerDecision(request)
    }
    func checkStopped() throws {
        stateLock.lock()
        let occupied = busy
        let selected = binding
        stateLock.unlock()
        // Context verification precedes writer status inside the shared Rust
        // decision. Never report WritersActive for an unverified context.
        let result = try decide("checkStopped", binding: selected)
        guard !occupied, result.decision == "stopped" else {
            throw ZcodeBridgeFailure.nativeContextUnavailable
        }
    }
    private func begin() throws {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !busy else { throw ZcodeBridgeFailure.lockBusy }
        busy = true
        lastLifecycleIssue = nil
    }
    private func finish(_ result: Result<Void, Error>, _ completion: (Result<Void, Error>) -> Void) {
        stateLock.lock(); busy = false; stateLock.unlock()
        completion(result)
    }
    func requestStop(completion: @escaping (Result<Void, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        do { try begin() } catch { completion(.failure(error)); return }
        do {
            let decision = try decide("stop")
            if decision.decision == "stopped" { finish(.success(()), completion); return }
            guard decision.decision == "terminate", let target = decision.target,
                  try decide("stop").target == target else { throw ZcodeBridgeFailure.sourceChanged }
            guard try terminate(target) else {
                lastLifecycleIssue = .stopRefused
                throw ZcodeBridgeFailure.writersActive
            }
            pollStopped(deadline: now() + timeout, completion: completion)
        } catch { finish(.failure(error), completion) }
    }
    private func pollStopped(deadline: TimeInterval, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            guard try decide("checkStopped").decision == "stopped" else {
                throw ZcodeBridgeFailure.nativeContextUnavailable
            }
            finish(.success(()), completion)
        } catch ZcodeBridgeFailure.writersActive {
            guard now() < deadline else {
                lastLifecycleIssue = .stopTimedOut
                finish(.failure(ZcodeBridgeFailure.writersActive), completion)
                return
            }
            schedule { [self] in pollStopped(deadline: deadline, completion: completion) }
        } catch { finish(.failure(error), completion) }
    }
    func reopen(completion: @escaping (Result<Void, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        do { try begin() } catch { completion(.failure(error)); return }
        do {
            guard let contract = launchContract else {
                lastLifecycleIssue = .missingLaunchContract
                throw ZcodeBridgeFailure.nativeContextUnavailable
            }
            let old = currentBinding()
            guard contract.executableURL.isFileURL,
                  contract.executableURL.path == old.app.executablePath,
                  contract.currentDirectoryURL.isFileURL,
                  contract.currentDirectoryURL.path.hasPrefix("/"),
                  !contract.arguments.contains(where: { $0.contains("\0") }),
                  !contract.environment.contains(where: { $0.key.isEmpty || $0.key.contains("=") || $0.key.contains("\0") || $0.value.contains("\0") }),
                  try decide("reopen", launchContextId: contract.contextId).decision == "reopen" else {
                throw ZcodeBridgeFailure.nativeContextUnavailable
            }
            // No inferred arguments or host-environment merge. The operation is
            // explicit. A failed observation after launch may mean it did launch.
            lastLifecycleIssue = .reopenOutcomeUnknown
            let process = try launch(contract)
            guard process != old.main else { throw ZcodeBridgeFailure.sourceChanged }
            var next = old
            next.main = process
            guard try decide("checkRunning", binding: next).decision == "running" else {
                throw ZcodeBridgeFailure.nativeContextUnavailable
            }
            stateLock.lock(); binding = next; stateLock.unlock()
            lastLifecycleIssue = nil
            finish(.success(()), completion)
        } catch { finish(.failure(error), completion) }
    }
}

/// Normal macOS operations, usable only with an authoritative native identity
/// provider. This does not enumerate processes, infer context or install itself.
/// A launch observation failure is an uncertain launch, never a retry instruction.
struct ZcodeMacLifecycleOperations {
    let binding: ZcodeOwnerBinding
    let snapshot: () throws -> ZcodeOwnerSnapshot
    let observeIdentity: (Int32) throws -> ZcodeOwnerProcess?
    private var app: ZcodeOwnerApp { binding.app }

    func terminate(_ expected: ZcodeOwnerProcess) throws -> Bool {
        guard try observeIdentity(expected.pid) == expected,
              let running = NSRunningApplication(processIdentifier: expected.pid),
              running.bundleIdentifier == app.bundleId,
              running.bundleURL?.path == app.bundlePath,
              running.executableURL?.path == expected.executablePath else {
            throw ZcodeBridgeFailure.sourceChanged
        }
        var selected = binding
        selected.main = expected
        let final = try zcodeOwnerDecision(ZcodeOwnerDecisionRequest(action: "stop", binding: selected,
            snapshot: try snapshot(), launchContextId: nil))
        guard final.decision == "terminate", final.target == expected else {
            throw ZcodeBridgeFailure.sourceChanged
        }
        return running.terminate() // Graceful quit only; no forceTerminate/kill.
    }
    func launch(_ contract: ZcodeOwnerLaunchContract) throws -> ZcodeOwnerProcess {
        guard contract.executableURL.path == app.executablePath else {
            throw ZcodeBridgeFailure.sourceChanged
        }
        let process = Process()
        process.executableURL = contract.executableURL
        process.arguments = contract.arguments
        process.environment = contract.environment // Complete supplied environment.
        process.currentDirectoryURL = contract.currentDirectoryURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Required authoritative fresh observation at the actual effect boundary,
        // after process configuration. A prior owner decision cannot authorize a
        // replaced app/context. Without this producer the adapter cannot be built.
        let final = try zcodeOwnerDecision(ZcodeOwnerDecisionRequest(action: "reopen", binding: binding,
            snapshot: try snapshot(), launchContextId: contract.contextId))
        guard final.decision == "reopen" else { throw ZcodeBridgeFailure.nativeContextUnavailable }
        try process.run()
        guard let observed = try observeIdentity(process.processIdentifier),
              observed.executablePath == app.executablePath else {
            throw ZcodeBridgeFailure.nativeContextUnavailable
        }
        return observed
    }
}
