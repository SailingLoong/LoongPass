import Foundation
import Darwin

@main @MainActor struct WorkBuddyClientInfoChecks {
    static func main() {
        do { try run() }
        catch { print("FAIL WorkBuddy public client metadata: \(error)"); exit(1) }
    }
    static func run() throws {
        let product: [String: Any] = ["applicationName": "WorkBuddy", "authentication": ["id": "workbuddy-desktop", "type": "account-scoped-external-link", "attributes": ["platform": "workbuddy"]]]
        let package = ["name": "@genie/agent-cli", "version": "3.1.7"]
        func read(_ p: [String: Any], _ cli: [String: Any], app: String = "6.0.1") throws -> [String: String] {
            try WorkBuddyDesktopTransaction.clientInfo(appVersion: app,
                product: JSONSerialization.data(withJSONObject: p), package: JSONSerialization.data(withJSONObject: cli))
        }
        let parsed = try read(product, package)
        precondition(parsed == ["appVersion": "6.0.1", "cliVersion": "3.1.7", "applicationName": "WorkBuddy"])
        for invalid in [["name": "@genie/agent-cli"], ["name": "other-cli", "version": "3.1.7"], ["name": "@genie/agent-cli", "version": "3.1.7\ninvalid"], ["name": "@genie/agent-cli", "version": "3.1.7\n"]] {
            do { _ = try read(product, invalid); preconditionFailure("Invalid CLI metadata accepted") }
            catch WorkBuddyDesktopTransaction.Failure.unsafeFile {}
        }
        var missing = product; missing.removeValue(forKey: "applicationName")
        do { _ = try read(missing, package); preconditionFailure("Missing product name accepted") }
        catch WorkBuddyDesktopTransaction.Failure.unsafeFile {}
        var foreign = product; foreign["applicationName"] = "workbuddy-ai"
        do { _ = try read(foreign, package); preconditionFailure("Foreign product accepted") }
        catch WorkBuddyDesktopTransaction.Failure.unsafeFile {}
        do { _ = try read(product, package, app: "unknown"); preconditionFailure("Invalid app version accepted") }
        catch WorkBuddyDesktopTransaction.Failure.unsafeFile {}
        print("PASS complete app/CLI metadata, missing fields, foreign products and malformed versions")
    }
}
