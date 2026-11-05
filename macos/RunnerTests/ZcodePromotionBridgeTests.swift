// Synthetic-only candidates. These tests have NOT been compiled or run here.
import Cocoa
import FlutterMacOS
import XCTest
@testable import LoongPass

final class ZcodePromotionBridgeTests: XCTestCase {
    private let id = String(repeating: "b", count: 64)

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

    func testNilOwnerFailsClosedAndCannotBeConfiguredFromFlutter() {
        let bridge = ZcodeSwitchBridge()
        let status = reply(bridge, "promotionStatus", [:]) as? [String: Any]
        XCTAssertEqual(status?["available"] as? Bool, false)
        XCTAssertEqual(status?["reason"] as? String, "NativeContextUnavailable")
        XCTAssertEqual((reply(bridge, "previewPromotions", ["accountId": id]) as? FlutterError)?.code,
                       "NativeContextUnavailable")
        XCTAssertEqual((reply(bridge, "claimPromotions", ["accountId": id, "automatic": false]) as? FlutterError)?.code,
                       "NativeContextUnavailable")
        for method in ["configurePromotionOwner", "approvePlans", "setPromotionPending"] {
            XCTAssertEqual((reply(bridge, method, [:]) as? FlutterError)?.code, "UnsupportedMethod")
        }
    }

    func testArgumentsCannotSupplyApprovalSecretsPendingStateOrNumericBooleans() {
        let bridge = ZcodeSwitchBridge()
        let invalid: [(String, Any)] = [
            ("promotionStatus", ["accountId": id]),
            ("previewPromotions", [:]),
            ("previewPromotions", ["accountId": id.uppercased()]),
            ("previewPromotions", ["accountId": id, "approved": true]),
            ("claimPromotions", ["accountId": id]),
            ("claimPromotions", ["accountId": id, "automatic": 1]),
            ("claimPromotions", ["accountId": id, "automatic": "true"]),
            ("claimPromotions", ["accountId": id, "automatic": false, "planId": "midnight"]),
            ("claimPromotions", ["accountId": id, "automatic": false, "pending": false]),
            ("claimPromotions", ["accountId": id, "automatic": false, "secret": "not-accepted"])
        ]
        for (method, arguments) in invalid {
            XCTAssertEqual((reply(bridge, method, arguments) as? FlutterError)?.code, "InvalidArguments")
        }
    }

    func testNativeDelegateRunsOffMainWithOpaqueAccountAndAutomaticFlag() throws {
        let bridge = ZcodeSwitchBridge()
        let owner = SyntheticPromotionOwner()
        try onMain { try bridge.configurePromotionOwner(owner) }
        XCTAssertEqual((reply(bridge, "promotionStatus", [:]) as? [String: Any])?["available"] as? Bool, true)
        let preview = reply(bridge, "previewPromotions", ["accountId": id]) as? [String: Any]
        XCTAssertEqual(preview?["status"] as? String, "claimable")
        XCTAssertEqual(preview?["canClaim"] as? Bool, true)
        XCTAssertEqual(preview?["checkedAt"] as? Int64, 1_793_811_000)
        XCTAssertEqual(preview?["windowPolicy"] as? String, "serverPreview")
        XCTAssertTrue(preview?["exactOfferWindow"] is NSNull)
        XCTAssertNil(preview?["token"])
        owner.output["status"] = "claimed"
        owner.output["canClaim"] = false
        let claimed = reply(bridge, "claimPromotions", ["accountId": id, "automatic": true]) as? [String: Any]
        XCTAssertEqual(claimed?["status"] as? String, "claimed")
        XCTAssertEqual(owner.calls.map { $0.0 }, [id, id])
        XCTAssertEqual(owner.calls.map { $0.1 }, [false, true])
        XCTAssertEqual(owner.calls.map { $0.2 }, [false, true])
        try onMain { try bridge.configurePromotionOwner(nil) }
    }

    func testMalformedClaimIsUnknownAndNeverRetriedEvenAfterOwnerReinstallation() throws {
        let bridge = ZcodeSwitchBridge()
        let owner = SyntheticPromotionOwner()
        owner.output = ["status": "claimed", "canClaim": true, "token": "must-not-escape"]
        try onMain { try bridge.configurePromotionOwner(owner) }
        let result = reply(bridge, "claimPromotions", ["accountId": id, "automatic": false]) as? [String: Any]
        XCTAssertEqual(result?["status"] as? String, "unknown")
        XCTAssertNil(result?["planId"])
        XCTAssertEqual(Set(result?.keys.map { $0 } ?? []),
                       Set(["status", "canClaim", "reason", "windowPolicy", "exactOfferWindow"]))
        XCTAssertEqual(result?["canClaim"] as? Bool, false)
        XCTAssertEqual(result?["reason"] as? String, "confirmResult")
        XCTAssertEqual(owner.calls.count, 1)
        owner.output = SyntheticPromotionOwner.safeReply()
        let preview = reply(bridge, "previewPromotions", ["accountId": id]) as? [String: Any]
        XCTAssertEqual(preview?["canClaim"] as? Bool, false)
        XCTAssertEqual(owner.calls.count, 2)
        try onMain { try bridge.configurePromotionOwner(owner) }
        _ = reply(bridge, "claimPromotions", ["accountId": id, "automatic": false])
        XCTAssertEqual(owner.calls.count, 2)
        let status = reply(bridge, "promotionStatus", [:]) as? [String: Any]
        XCTAssertEqual(status?["available"] as? Bool, false)
        XCTAssertEqual(status?["reason"] as? String, "CommitUncertain")
    }

    func testSanitizerRejectsUnknownStatusReasonUnboundedLabelsAndMilliseconds() {
        let valid = SyntheticPromotionOwner.safeReply()
        for (key, value) in [("status", "success" as Any), ("reason", "secret detail" as Any),
                             ("planName", String(repeating: "x", count: 257) as Any),
                             ("planId", "invalid\nplan" as Any), ("canClaim", 1 as Any),
                             ("checkedAt", 1_793_811_000_000 as Any),
                             ("windowPolicy", "localCalendar" as Any)] {
            var malformed = valid
            malformed[key] = value
            XCTAssertNil(ZcodePromotionWireReply.sanitize(malformed))
        }
        var invalidWindow = valid
        invalidWindow["exactOfferWindow"] = ["startsAt": 1]
        XCTAssertNil(ZcodePromotionWireReply.sanitize(invalidWindow))
        for key in ["startsAt", "endsAt", "checkedAt"] {
            for invalid in [Int64(-1), Int64(253_402_300_800)] {
                var malformed = valid
                malformed[key] = invalid
                XCTAssertNil(ZcodePromotionWireReply.sanitize(malformed))
            }
            for boundary in [Int64(0), Int64(253_402_300_799)] {
                var bounded = valid
                bounded[key] = boundary
                XCTAssertEqual(ZcodePromotionWireReply.sanitize(bounded)?[key] as? Int64, boundary)
            }
        }
    }

    func testUnknownOrClaimablePostReplyIsNeverSuccessAndCannotBeRetried() throws {
        for status in ["unknown", "claimable"] {
            let bridge = ZcodeSwitchBridge()
            let owner = SyntheticPromotionOwner()
            owner.output["status"] = status
            owner.output["canClaim"] = status == "claimable"
            try onMain { try bridge.configurePromotionOwner(owner) }
            let result = reply(bridge, "claimPromotions", ["accountId": id, "automatic": false]) as? [String: Any]
            XCTAssertEqual(result?["status"] as? String, "unknown")
            XCTAssertNil(result?["planId"])
            _ = reply(bridge, "claimPromotions", ["accountId": id, "automatic": false])
            XCTAssertEqual(owner.calls.count, 1)
        }
    }

    func testAvailabilityAndClaimExceptionsAreRedactedAtTheCorrectBoundary() throws {
        let bridge = ZcodeSwitchBridge()
        let owner = SyntheticPromotionOwner()
        owner.available = false
        try onMain { try bridge.configurePromotionOwner(owner) }
        XCTAssertEqual((reply(bridge, "promotionStatus", [:]) as? [String: Any])?["available"] as? Bool, false)
        XCTAssertEqual((reply(bridge, "claimPromotions", ["accountId": id, "automatic": false]) as? FlutterError)?.code,
                       "NativeContextUnavailable")
        XCTAssertEqual(owner.calls.count, 0)
        owner.available = true
        owner.failure = NSError(domain: "not-returned-to-Flutter", code: 987)
        let result = reply(bridge, "claimPromotions", ["accountId": id, "automatic": false]) as? [String: Any]
        XCTAssertEqual(result?["status"] as? String, "unknown")
        XCTAssertNil(result?["planId"])
        XCTAssertEqual(result?["reason"] as? String, "confirmResult")
        _ = reply(bridge, "claimPromotions", ["accountId": id, "automatic": false])
        XCTAssertEqual(owner.calls.count, 1)
    }

    func testSharedBusyTokenBlocksSwitchAndNativeOwnerChangesUntilClaimReturns() {
        let entered = expectation(description: "delegate entered")
        let done = expectation(description: "claim done")
        let owner = BlockingPromotionOwner(entered: entered)
        let bridge = ZcodeSwitchBridge()
        DispatchQueue.main.async {
            do {
                try bridge.configurePromotionOwner(owner)
                bridge.handle(call: FlutterMethodCall(methodName: "claimPromotions",
                    arguments: ["accountId": self.id, "automatic": false])) { value in
                    XCTAssertEqual((value as? [String: Any])?["status"] as? String, "noClaim")
                    done.fulfill()
                }
            } catch { XCTFail("Unexpected native setup failure"); done.fulfill() }
        }
        wait(for: [entered], timeout: 2)
        onMain {
            do { try bridge.configurePromotionOwner(nil); XCTFail("Expected busy owner refusal") }
            catch { XCTAssertEqual((error as? ZcodeBridgeFailure)?.rawValue, "LockBusy") }
            do { try bridge.release(); XCTFail("Expected busy release refusal") } catch {}
            bridge.handle(call: FlutterMethodCall(methodName: "switchAccount",
                arguments: ["accountId": id, "expectedRevision": id])) { value in
                    XCTAssertEqual((value as? FlutterError)?.code, "LockBusy")
                }
        }
        owner.resume.signal()
        wait(for: [done], timeout: 2)
    }
}

private final class SyntheticPromotionOwner: ZcodePromotionOwner {
    var calls: [(String, Bool, Bool)] = []
    var output = SyntheticPromotionOwner.safeReply()
    var available = true
    var failure: Error?
    static func safeReply() -> [String: Any] {
        ["status": "claimable", "canClaim": true, "planId": "synthetic-approved-plan",
         "planName": "Synthetic offer", "checkedAt": Int64(1_793_811_000),
         "windowPolicy": "serverPreview", "exactOfferWindow": NSNull(), "token": "must-not-escape"]
    }
    func availability() throws -> Bool { XCTAssertFalse(Thread.isMainThread); return available }
    func run(accountId: String, claim: Bool, automatic: Bool) throws -> [String: Any] {
        XCTAssertFalse(Thread.isMainThread)
        calls.append((accountId, claim, automatic))
        if let failure = failure { throw failure }
        return output
    }
}

private final class BlockingPromotionOwner: ZcodePromotionOwner {
    let entered: XCTestExpectation
    let resume = DispatchSemaphore(value: 0)
    init(entered: XCTestExpectation) { self.entered = entered }
    func availability() throws -> Bool { true }
    func run(accountId: String, claim: Bool, automatic: Bool) throws -> [String: Any] {
        entered.fulfill()
        guard resume.wait(timeout: .now() + 2) == .success else { throw ZcodeBridgeFailure.storage }
        return ["status": "noClaim", "canClaim": false, "reason": "noServerOffer",
                "windowPolicy": "serverPreview", "exactOfferWindow": NSNull()]
    }
}
