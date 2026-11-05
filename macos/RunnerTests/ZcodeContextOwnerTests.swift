// Source-only synthetic test candidate. Not compiled/run in the cloud owner stage.
import Cocoa
import XCTest
@testable import LoongPass

final class ZcodeContextOwnerTests: XCTestCase {
    private func fixtures() throws -> (ZcodeOwnerBinding, ZcodeOwnerSnapshot, ZcodeOwnerProcess) {
        let app = ZcodeOwnerApp(bundleId: "dev.zcode.app", bundlePath: "/synthetic/ZCode.app",
            executablePath: "/synthetic/ZCode.app/Contents/MacOS/ZCode", device: 1, inode: 2)
        let process = ZcodeOwnerProcess(pid: 42, uid: 501, startedSeconds: 100,
            startedMicroseconds: 1, executablePath: app.executablePath)
        return (ZcodeOwnerBinding(app: app, contextId: "synthetic-context", uid: 501, main: process),
                ZcodeOwnerSnapshot(app: app, contextId: "synthetic-context", complete: true,
                    otherWriters: false, processes: []), process)
    }

    func testDefaultFactoryExplainsMissingProducerInsteadOfReadingOwnEnvironment() {
        XCTAssertThrowsError(try ZcodeContextOwner.production()) {
            XCTAssertEqual($0 as? ZcodeBridgeFailure, .nativeContextUnavailable)
        }
        XCTAssertTrue(ZcodeContextOwner.missingProductionContracts.contains("effective ZCode runtime setting and launch environment"))
    }

    // Source-only until the authorized Mac suite compiles and runs this file.
    func testRuntimeDriftCannotBecomeWritersActiveNetworkPermission() throws {
        var (binding, snapshot, main) = try fixtures()
        binding.runtimeContext = ZcodeOwnerRuntimeContext(origin: "https://zcode.z.ai",
            credentialPlatform: "darwin", requestPlatform: "darwin-arm64")
        snapshot.processes = [main]
        for observed in [nil,
            ZcodeOwnerRuntimeContext(origin: "https://zcode.chatglm.site", credentialPlatform: "darwin", requestPlatform: "darwin-arm64"),
            ZcodeOwnerRuntimeContext(origin: "https://zcode.z.ai", credentialPlatform: "darwin", requestPlatform: "darwin-x64")] {
            snapshot.runtimeContext = observed
            let current = snapshot
            let owner = ZcodeContextOwner(binding: binding, snapshot: { current },
                terminate: { _ in XCTFail("No lifecycle effect"); return false },
                launch: { _ in XCTFail("No launch"); return main })
            XCTAssertThrowsError(try owner.checkStopped()) {
                XCTAssertEqual($0 as? ZcodeBridgeFailure,
                    observed == nil ? .nativeContextUnavailable : .sourceChanged)
            }
        }
    }

    func testHelperSurvivingMainExitCannotPassStoppedProof() throws {
        let (binding, empty, main) = try fixtures()
        var snapshot = empty
        var helper = main
        helper.pid = 43
        helper.executablePath = "/synthetic/ZCode.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"
        snapshot.processes = [helper]
        let owner = ZcodeContextOwner(binding: binding, snapshot: { snapshot },
            terminate: { _ in XCTFail("Must not terminate a helper"); return false },
            launch: { _ in XCTFail("Must not launch implicitly"); return main })
        XCTAssertThrowsError(try owner.checkStopped()) {
            XCTAssertEqual($0 as? ZcodeBridgeFailure, .writersActive)
        }
    }

    func testNativeDecisionsStopExactMainAndWaitForAllHelpers() throws {
        let (binding, empty, main) = try fixtures()
        let done = expectation(description: "explicit stop")
        DispatchQueue.main.async {
            var snapshot = empty
            snapshot.processes = [main]
            var terminated = 0
            let owner = ZcodeContextOwner(binding: binding, snapshot: { snapshot }, terminate: { target in
                XCTAssertEqual(target, main)
                terminated += 1
                snapshot.processes = []
                return true
            }, launch: { _ in XCTFail("Stop must not reopen"); return main })
            owner.requestStop { result in
                if case .failure = result { XCTFail("Expected lifecycle success") }
                XCTAssertEqual(terminated, 1)
                do { try owner.checkStopped() } catch { XCTFail("Expected stopped proof") }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 2)
    }

    func testTimeoutIsFailureAndReopenWithoutContractNeverLaunches() throws {
        let (binding, empty, main) = try fixtures()
        let done = expectation(description: "bounded refusal")
        DispatchQueue.main.async {
            var snapshot = empty
            snapshot.processes = [main]
            var clock: TimeInterval = 0
            let owner = ZcodeContextOwner(binding: binding, snapshot: { snapshot }, terminate: { _ in true },
                launch: { _ in XCTFail("Missing contract must not launch"); return main },
                timeout: 1, now: { clock }, schedule: { work in clock += 2; work() })
            owner.requestStop { result in
                if case .success = result { XCTFail("Expected lifecycle failure") }
                XCTAssertEqual(owner.lastLifecycleIssue, .stopTimedOut)
                snapshot.processes = []
                owner.reopen { reopened in
                    if case .success = reopened { XCTFail("Expected reopen refusal") }
                    XCTAssertEqual(owner.lastLifecycleIssue, .missingLaunchContract)
                    done.fulfill()
                }
            }
        }
        wait(for: [done], timeout: 2)
    }

    func testMacLaunchRechecksAppAndContextImmediatelyBeforeProcessRun() throws {
        let (binding, empty, _) = try fixtures()
        let contract = ZcodeOwnerLaunchContract(contextId: binding.contextId, mode: .controlledLaunch,
            executableURL: URL(fileURLWithPath: binding.app.executablePath), arguments: [],
            environment: [:], currentDirectoryURL: URL(fileURLWithPath: binding.app.bundlePath))
        for changedApp in [true, false] {
            var latest = empty
            if changedApp { latest.app.inode += 1 } else { latest.contextId = "changed-context" }
            let operations = ZcodeMacLifecycleOperations(binding: binding, snapshot: { latest },
                observeIdentity: { _ in XCTFail("Must not reach post-launch identity observation"); return nil })
            XCTAssertThrowsError(try operations.launch(contract)) {
                // If Process.run was reached, the nonexistent synthetic executable
                // would produce a system error instead of this precise rejection.
                XCTAssertEqual($0 as? ZcodeBridgeFailure, .sourceChanged)
            }
        }
    }

    func testExplicitControlledLaunchIsNotClaimedToRestoreUnknownArguments() throws {
        let (binding, empty, main) = try fixtures()
        let done = expectation(description: "controlled launch")
        DispatchQueue.main.async {
            var snapshot = empty
            var newMain = main
            newMain.pid = 99
            newMain.startedSeconds = 200
            let contract = ZcodeOwnerLaunchContract(contextId: binding.contextId, mode: .controlledLaunch,
                executableURL: URL(fileURLWithPath: binding.app.executablePath), arguments: [],
                environment: ["HOME": "/synthetic/home", "ZCODE_DATA_BASE_DIR": "/synthetic/data"],
                currentDirectoryURL: URL(fileURLWithPath: binding.app.bundlePath))
            let owner = ZcodeContextOwner(binding: binding, snapshot: { snapshot }, terminate: { _ in false },
                launch: { supplied in
                    XCTAssertEqual(supplied.mode, .controlledLaunch)
                    XCTAssertTrue(supplied.arguments.isEmpty)
                    snapshot.processes = [newMain]
                    return newMain
                }, launchContract: contract)
            owner.reopen { result in
                if case .failure = result { XCTFail("Expected lifecycle success") }
                do { try owner.checkStopped(); XCTFail("Expected stopped refusal") } catch {}
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 2)
    }
}
