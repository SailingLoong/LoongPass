// Synthetic-only macOS test candidate. Never resolve real credentials or apps.
import Cocoa
import FlutterMacOS
import XCTest
@testable import LoongPass

final class ZcodeSwitchBridgeTests: XCTestCase {
    private let id = String(repeating: "a", count: 64)

    private func onMain<T>(_ action: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try action() }
        return try DispatchQueue.main.sync(execute: action)
    }

    private func reply(_ bridge: ZcodeSwitchBridge, _ method: String,
                       _ arguments: Any? = nil) -> Any? {
        let done = expectation(description: method)
        var value: Any?
        let run = {
            bridge.handle(call: FlutterMethodCall(methodName: method, arguments: arguments)) {
                value = $0
                XCTAssertTrue(Thread.isMainThread)
                done.fulfill()
            }
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
        wait(for: [done], timeout: 2)
        return value
    }

    func testOwnerStartsUnavailableAndEveryAccountActionIsBlocked() {
        let bridge = ZcodeSwitchBridge()
        let status = reply(bridge, "status") as? [String: Any]
        XCTAssertEqual(status?["available"] as? Bool, false)
        XCTAssertEqual(status?["reason"] as? String, "NativeContextUnavailable")
        for method in ["captureCurrent", "captureSelected", "restoreSelected", "requestStop", "reopen"] {
            XCTAssertEqual((reply(bridge, method) as? FlutterError)?.code, "NativeContextUnavailable")
        }
        XCTAssertEqual((reply(bridge, "switchAccount", ["accountId": id, "expectedRevision": id]) as? FlutterError)?.code,
                       "NativeContextUnavailable")
        XCTAssertEqual((reply(bridge, "restore", ["operationId": id]) as? FlutterError)?.code,
                       "NativeContextUnavailable")
    }

    func testConfiguredStatusUsesNativeGateButDoesNotReadSyntheticPaths() throws {
        // These paths deliberately need not exist: C status is file-read-free.
        let cases: [(Error?, String)] = [
            (nil, "NativeCaptureRequired"),
            (ZcodeBridgeFailure.writersActive, "WritersActive"),
            (ZcodeBridgeFailure.sourceChanged, "SourceChanged"),
            (ZcodeBridgeFailure.nativeContextUnavailable, "NativeContextUnavailable"),
            (NSError(domain: "not returned", code: 123), "NativeContextUnavailable")
        ]
        for (failure, expected) in cases {
            let bridge = ZcodeSwitchBridge()
            let owner = GateOnlyLifecycle(failure: failure)
            let context = ZcodeContext(
                sourceCredentialsURL: URL(fileURLWithPath: "/synthetic/not-read/credentials.json"),
                privateBackupRootURL: URL(fileURLWithPath: "/synthetic/not-read/backups"),
                contextTag: "synthetic-context", existingSecret: "synthetic-secret")
            try onMain { try bridge.configure(context: context, lifecycle: owner) }
            let status = reply(bridge, "status") as? [String: Any]
            XCTAssertEqual(status?["available"] as? Bool, false)
            XCTAssertEqual(status?["reason"] as? String, expected)
            try onMain { try bridge.release() }
        }
    }

    func testDartCannotConfigureSupplyPathsSecretsOrStoppedClaims() {
        let bridge = ZcodeSwitchBridge()
        for method in ["configure", "release", "setContext", "anything"] {
            XCTAssertEqual((reply(bridge, method) as? FlutterError)?.code, "UnsupportedMethod")
        }
        for method in ["status", "captureCurrent", "captureSelected", "restoreSelected", "requestStop", "reopen"] {
            let invalid: [Any] = [["path": "/tmp/not-used"], ["secret": "synthetic"], ["stopped": true], ["unexpected": "x"], true, []]
            for arguments in invalid {
                let error = reply(bridge, method, arguments) as? FlutterError
                XCTAssertEqual(error?.code, "InvalidArguments")
                XCTAssertNil(error?.message)
                XCTAssertNil(error?.details)
            }
        }
    }

    func testSwitchAndRestoreRequireOnlyExactOpaqueLowercaseIds() {
        let bridge = ZcodeSwitchBridge()
        let invalidSwitch: [Any] = [[:], ["accountId": id], ["accountId": id, "expectedRevision": id, "path": "/tmp/no"],
                                   ["accountId": id.uppercased(), "expectedRevision": id],
                                   ["accountId": id, "expectedRevision": String(repeating: "0", count: 63)]]
        for arguments in invalidSwitch {
            XCTAssertEqual((reply(bridge, "switchAccount", arguments) as? FlutterError)?.code, "InvalidArguments")
        }
        let invalidRestore: [Any] = [[:], ["operationId": id, "path": "/tmp/no"], ["operationId": "../x"], ["operationId": 1]]
        for arguments in invalidRestore {
            XCTAssertEqual((reply(bridge, "restore", arguments) as? FlutterError)?.code, "InvalidArguments")
        }
    }

    func testDecoderRedactsNativeErrorStringsAndPreservesCommitUncertainty() throws {
        let raw = Data(#"{"error":"Storage","message":"secret text","path":"/private/source"}"#.utf8)
        let error = ZcodeWireReply.decode(raw, method: "captureCurrent") as? FlutterError
        XCTAssertEqual(error?.code, "Storage")
        XCTAssertNil(error?.message)
        XCTAssertNil(error?.details)
        let uncertain = ZcodeWireReply.decode(Data(#"{"error":"CommitUncertain"}"#.utf8), method: "switchAccount") as? FlutterError
        XCTAssertEqual(uncertain?.code, "CommitUncertain")
        XCTAssertEqual((uncertain?.details as? [String: String])?["outcome"], "unknown")
        XCTAssertNil(uncertain?.message)
        let lost = ZcodeWireReply.decode(Data("invalid JSON".utf8), method: "restore") as? FlutterError
        XCTAssertEqual(lost?.code, "CommitUncertain")
    }

    func testDecoderOnlyReturnsSafeMetadataFields() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "accountId": id, "revision": id, "family": "zai", "label": "Synthetic",
            "secret": "must not escape", "source": "/private/source"
        ])
        let capture = ZcodeWireReply.decode(data, method: "captureCurrent") as? [String: Any]
        XCTAssertEqual(Set(capture?.keys.map { $0 } ?? []), Set(["accountId", "revision", "family", "label"]))
        XCTAssertEqual(capture?["accountId"] as? String, id)
        XCTAssertEqual(capture?["family"] as? String, "zai")
        let badStatus = ZcodeWireReply.decode(Data(#"{"available":1,"reason":"secret"}"#.utf8), method: "status") as? FlutterError
        XCTAssertEqual(badStatus?.code, "Storage")
    }

    func testAlreadyRestoredAndPreRenameRecoveryRemainUnchanged() throws {
        for method in ["restore", "restoreSelected"] {
            let data = try JSONSerialization.data(withJSONObject: ["outcome": "unchanged", "operationId": id])
            let value = ZcodeWireReply.decode(data, method: method) as? [String: Any]
            XCTAssertEqual(value?["outcome"] as? String, "unchanged")
            XCTAssertEqual(value?["operationId"] as? String, id)
        }
    }

    func testStatusPreservesNativeCaptureRequirementWithoutReadingFiles() {
        let value = ZcodeWireReply.decode(Data(#"{"available":false,"reason":"NativeCaptureRequired"}"#.utf8), method: "status") as? [String: Any]
        XCTAssertEqual(value?["available"] as? Bool, false)
        XCTAssertEqual(value?["reason"] as? String, "NativeCaptureRequired")
    }

    func testLostWriteReplyStaysBlockedUntilExplicitRecoverySucceeds() {
        var safety = ZcodeReplySafety()
        let lost = ZcodeWireReply.decode(Data("not-json".utf8), method: "switchAccount")
        _ = safety.observe(lost, method: "switchAccount")
        XCTAssertEqual((safety.blockedReply(method: "status") as? [String: Any])?["reason"] as? String, "CommitUncertain")
        for method in ["switchAccount", "captureCurrent", "captureSelected"] {
            XCTAssertEqual((safety.blockedReply(method: method) as? FlutterError)?.code, "CommitUncertain")
        }
        XCTAssertNil(safety.blockedReply(method: "restore"))
        XCTAssertNil(safety.blockedReply(method: "restoreSelected"))
        _ = safety.observe(ZcodeWireReply.error(.recoveryChanged), method: "restore")
        XCTAssertNotNil(safety.blockedReply(method: "switchAccount"))
        _ = safety.observe(["outcome": "unchanged", "operationId": id], method: "restoreSelected")
        XCTAssertNil(safety.blockedReply(method: "switchAccount"))
    }

    func testCancelledPickerNeverIndicatesUnknownMutation() {
        let error = ZcodeWireReply.error(.cancelled)
        XCTAssertEqual(error.code, "Cancelled")
        XCTAssertNil(error.message)
        XCTAssertNil(error.details)
    }

    func testLifecycleCompletionRepliesOnceEvenAfterOwnerBridgeDeallocates() {
        let done = expectation(description: "single teardown reply")
        DispatchQueue.main.async {
            var bridge: ZcodeSwitchBridge? = ZcodeSwitchBridge()
            let owner = SuspendedLifecycle()
            let context = ZcodeContext(
                sourceCredentialsURL: URL(fileURLWithPath: "/synthetic/not-read/credentials.json"),
                privateBackupRootURL: URL(fileURLWithPath: "/synthetic/not-read/backups"),
                contextTag: "synthetic-context", existingSecret: "synthetic-secret")
            var replies = 0
            do {
                try bridge?.configure(context: context, lifecycle: owner)
                bridge?.handle(call: FlutterMethodCall(methodName: "requestStop", arguments: nil)) { value in
                    replies += 1
                    XCTAssertEqual((value as? FlutterError)?.code, "NativeContextUnavailable")
                }
                weak var weakBridge = bridge
                bridge = nil
                XCTAssertNil(weakBridge)
                owner.complete?(.failure(ZcodeBridgeFailure.writersActive))
                owner.complete?(.failure(ZcodeBridgeFailure.writersActive))
                DispatchQueue.main.async {
                    XCTAssertEqual(replies, 1)
                    done.fulfill()
                }
            } catch { XCTFail("Unexpected native setup failure"); done.fulfill() }
        }
        wait(for: [done], timeout: 2)
    }

    func testNativeReleaseAndReconfigureAreRejectedUntilLifecycleCompletes() throws {
        // Native fakes exercise ownership only; no real app stop/reopen is called.
        let done = expectation(description: "native-only ownership")
        DispatchQueue.main.async {
            let bridge = ZcodeSwitchBridge()
            let owner = SuspendedLifecycle()
            let context = ZcodeContext(
                sourceCredentialsURL: URL(fileURLWithPath: "/synthetic/not-read/credentials.json"),
                privateBackupRootURL: URL(fileURLWithPath: "/synthetic/not-read/backups"),
                contextTag: "synthetic-context", existingSecret: "synthetic-secret")
            do {
                try bridge.configure(context: context, lifecycle: owner)
                bridge.handle(call: FlutterMethodCall(methodName: "requestStop", arguments: nil)) { value in
                    XCTAssertEqual((value as? FlutterError)?.code, "WritersActive")
                    XCTAssertTrue(Thread.isMainThread)
                    do { try bridge.release() } catch { XCTFail("Expected completed bridge release") }
                    done.fulfill()
                }
                XCTAssertEqual(owner.stopRequests, 1)
                XCTAssertEqual(owner.reopenRequests, 0)
                XCTAssertThrowsError(try bridge.release()) {
                    XCTAssertEqual(($0 as? ZcodeBridgeFailure)?.rawValue, "LockBusy")
                }
                XCTAssertThrowsError(try bridge.configure(context: context, lifecycle: owner))
                bridge.handle(call: FlutterMethodCall(methodName: "reopen", arguments: nil)) { value in
                    XCTAssertEqual((value as? FlutterError)?.code, "LockBusy")
                }
                owner.complete?(.failure(ZcodeBridgeFailure.writersActive))
                // A buggy native owner calling back twice must not reply twice or clear a later operation.
                owner.complete?(.failure(ZcodeBridgeFailure.storage))
            } catch { XCTFail("Unexpected native setup failure"); done.fulfill() }
        }
        wait(for: [done], timeout: 2)
    }
}

private final class SuspendedLifecycle: ZcodeLifecycleOwner {
    var stopRequests = 0
    var reopenRequests = 0
    var complete: ((Result<Void, Error>) -> Void)?
    func checkStopped() throws { throw ZcodeBridgeFailure.writersActive }
    func requestStop(completion: @escaping (Result<Void, Error>) -> Void) {
        stopRequests += 1
        complete = completion
    }
    func reopen(completion: @escaping (Result<Void, Error>) -> Void) {
        reopenRequests += 1
        complete = completion
    }
}

private final class GateOnlyLifecycle: ZcodeLifecycleOwner {
    let failure: Error?
    init(failure: Error?) { self.failure = failure }
    func checkStopped() throws { if let failure = failure { throw failure } }
    func requestStop(completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(ZcodeBridgeFailure.nativeContextUnavailable))
    }
    func reopen(completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(ZcodeBridgeFailure.nativeContextUnavailable))
    }
}
