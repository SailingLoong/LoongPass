import Foundation
import Darwin

private enum SettingsCheckFailure: Error { case failed(String) }
private let rendererKey = "electron-account-renderer-state-v1"
private let atomsKey = "electron-persisted-atom-state"

private func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
    guard try condition() else { throw SettingsCheckFailure.failed(label) }
}

private func encode(_ value: Any) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
    data.append(10)
    return data
}

private func document(_ data: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw SettingsCheckFailure.failed("invalid fixture document")
    }
    return value
}

private func equalJSON(_ actual: Any?, _ expected: Any?, _ label: String) throws {
    guard let actual, let expected else {
        try check(actual == nil && expected == nil, label)
        return
    }
    let actualBytes = try JSONSerialization.data(withJSONObject: [actual], options: [.sortedKeys])
    let expectedBytes = try JSONSerialization.data(withJSONObject: [expected], options: [.sortedKeys])
    try check(actualBytes == expectedBytes, label)
}

private func unavailable(_ action: () throws -> Data) throws {
    do { _ = try action() }
    catch let failure as CodexFailure {
        try check(failure == .settingsUnavailable, "unsanitized settings failure")
        return
    }
    throw SettingsCheckFailure.failed("unsupported settings were accepted")
}

private func account(_ user: String, _ workspace: String) throws -> CodexCredential {
    let claims: [String: Any] = ["sub": "subject-\(user)", "email": "\(user)@example.invalid",
        "https://api.openai.com/auth": ["chatgpt_user_id": user, "user_id": user,
        "chatgpt_account_id": workspace, "chatgpt_plan_type": "plus"]]
    let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let token = "eyJhbGciOiJSUzI1NiJ9.\(payload).synthetic-signature"
    return try CodexCredential(data: encode(["auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(),
        "tokens": ["id_token": token, "access_token": token,
                   "refresh_token": "synthetic-\(user)", "account_id": workspace]]))
}

// Independent fixture names from the inspected renderer controller. These
// expectations do not ask the projection to compute its own expected allowlist.
private let localGlobals = [
    "open-in-target-preferences", "worktree-repository-preferences", "active-workspace-roots",
    "electron-saved-workspace-roots", "electron-workspace-root-labels", "local-projects",
    "app-server-project-id-by-legacy-project-id-by-host", "app-server-projects-migration-by-host",
    "selected-project", "project-writable-roots", "project-appearances", "project-files",
    "pinned-thread-ids", "app-server-migrated-pinned-thread-ids-by-host", "pinned-project-ids",
    "sidebar-project-thread-orders", "sidebar-thread-metadata", "thread-project-assignments",
    "thread-project-membership-host-ids", "thread-writable-roots", "thread-workspace-root-hints",
    "thread-projectless-output-directories", "projectless-thread-ids", "project-order",
]
private let localAtoms = [
    "composer-prompt-drafts-v1", "composer-prompt-drafts-v2", "composer-recent-model-configurations-v1",
    "composer-auto-context-enabled", "prompt-history", "flat-project-sidebar-preferences-v1",
    "sidebar-custom-sections-v3", "sidebar-collapsed-sections-v1", "agent-mode-by-host-id",
    "sidebar-project-expanded-v1-codex:project-a", "thread-tab-routes-v1:thread-a",
    "permission-selection-by-host-id:local",
]
private let privateGlobals = ["chatgpt-account-cache", "spaces-cloud-cache", "remote-control-permissions",
                              "remote-connection-lease", "pending-thread-deletions", "account-beta-preferences", "queued-follow-ups"]
private let privateAtoms = ["thread-reference-capability-v1:thread-a", "account-bindings-v1",
                            "oauth-plugin-state", "chatgpt-spaces-cache", "thread-unrecognized-state-v1"]

private struct Fixture {
    let a: CodexCredential
    let b: CodexCredential
    let c: CodexCredential
    var root: [String: Any]

    init() throws {
        a = try account("user-a", "workspace-a")
        b = try account("user-b", "workspace-b")
        c = try account("user-c", "workspace-c")
        var sourceAtoms = Dictionary(uniqueKeysWithValues: localAtoms.map { ($0, "A-\($0)" as Any) })
        var sourceGlobals = Dictionary(uniqueKeysWithValues: localGlobals.map { ($0, "A-\($0)" as Any) })
        var targetAtoms = Dictionary(uniqueKeysWithValues: localAtoms.map { ($0, "B-\($0)" as Any) })
        var targetGlobals = Dictionary(uniqueKeysWithValues: localGlobals.map { ($0, "B-\($0)" as Any) })
        sourceAtoms["composer-prompt-drafts-v2"] = ["thread-a": "unfinished A draft"]
        sourceAtoms["composer-recent-model-configurations-v1"] = ["model": "gpt-synthetic", "effort": "high"]
        sourceAtoms["sidebar-custom-sections-v3"] = [["id": "section-a", "title": "Local projects"]]
        sourceGlobals["local-projects"] = ["project-a"]
        sourceGlobals["selected-project"] = "project-a"
        sourceGlobals["project-files"] = NSNull()
        sourceAtoms.removeValue(forKey: "composer-auto-context-enabled")
        sourceGlobals.removeValue(forKey: "project-order")
        targetAtoms["sidebar-project-expanded-v1-codex:target-only"] = true
        targetAtoms["thread-tab-routes-v1:target-only"] = ["old-tab"]
        targetAtoms["permission-selection-by-host-id:target-only"] = "old-permission"
        for key in privateAtoms { sourceAtoms[key] = ["owner": "A"]; targetAtoms[key] = ["owner": "B"] }
        for key in privateGlobals { sourceGlobals[key] = ["owner": "A"]; targetGlobals[key] = ["owner": "B"] }
        sourceGlobals["queued-follow-ups"] = [["id": "sourceQueueA", "prompt": "pending A prompt"]]
        targetGlobals["queued-follow-ups"] = [["id": "targetQueueB", "prompt": "pending B prompt"]]
        sourceAtoms["unknown-source-only"] = "must not transfer"
        sourceGlobals["unknown-source-only-global"] = "must not transfer"
        targetAtoms["unknown-target-only"] = ["keep": NSNull(), "unicode": "龙/😀"]
        targetGlobals["unknown-target-only-global"] = ["keep": [1, 2, 3]]
        root = sourceGlobals
        root[atomsKey] = sourceAtoms
        root["future-root-value"] = ["nested": [true, NSNull(), "龙/😀"]]
        root[rendererKey] = ["owner": a.rendererOwnerKey, "inactive": [
            b.rendererOwnerKey: ["atoms": targetAtoms, "globals": targetGlobals,
                                 "future-snapshot-value": ["keep": true]],
            c.rendererOwnerKey: ["atoms": ["prompt-history": ["C history"]], "globals": ["local-projects": ["project-c"]]],
        ], "future-metadata-value": ["keep": [1, "two", NSNull()]]]
    }
}

private func snapshot(_ root: [String: Any], _ owner: String) throws -> [String: Any] {
    guard let metadata = root[rendererKey] as? [String: Any],
          let inactive = metadata["inactive"] as? [String: Any],
          let value = inactive[owner] as? [String: Any] else {
        throw SettingsCheckFailure.failed("renderer target snapshot is missing")
    }
    return value
}

/// The native controller archives its current atoms/globals and loads the
/// selected inactive snapshot. This fixture models that consumer independently.
private func nativeStartup(_ root: [String: Any], target: String) throws -> [String: Any] {
    var loaded = root
    var metadata = root[rendererKey] as! [String: Any]
    var inactive = metadata["inactive"] as! [String: Any]
    let targetSnapshot = try snapshot(root, target)
    if let current = metadata["owner"] as? String {
        var globals: [String: Any] = [:]
        for key in localGlobals + privateGlobals { globals[key] = root[key] }
        inactive[current] = ["atoms": root[atomsKey] as! [String: Any], "globals": globals]
    }
    let globals = targetSnapshot["globals"] as! [String: Any]
    for key in localGlobals + privateGlobals { loaded[key] = globals[key] }
    loaded[atomsKey] = targetSnapshot["atoms"]
    inactive.removeValue(forKey: target)
    metadata["owner"] = target
    metadata["inactive"] = inactive
    loaded[rendererKey] = metadata
    return loaded
}

@main
struct CodexLocalSettingsChecks {
    static func projectionChecks() throws {
        let fixture = try Fixture()
        let output = try CodexLocalSettings.transfer(data: encode(fixture.root), source: fixture.a, target: fixture.b)
        try check(try CodexLocalSettings.transfer(data: output, source: fixture.a, target: fixture.b) == output,
                  "unchanged target preferences normalized original bytes")
        let projected = try document(output)
        let beforeTarget = try snapshot(fixture.root, fixture.b.rendererOwnerKey)
        let target = try snapshot(projected, fixture.b.rendererOwnerKey)
        let sourceAtoms = fixture.root[atomsKey] as! [String: Any]
        let targetAtoms = target["atoms"] as! [String: Any]
        let targetGlobals = target["globals"] as! [String: Any]
        for key in localGlobals { try equalJSON(targetGlobals[key], fixture.root[key], "local global preference was not transferred") }
        for key in localAtoms { try equalJSON(targetAtoms[key], sourceAtoms[key], "local atom preference was not transferred") }
        try check(targetAtoms["sidebar-project-expanded-v1-codex:target-only"] == nil &&
                  targetAtoms["thread-tab-routes-v1:target-only"] == nil &&
                  targetAtoms["permission-selection-by-host-id:target-only"] == nil, "absent source local keys were retained")
        let previousAtoms = beforeTarget["atoms"] as! [String: Any], previousGlobals = beforeTarget["globals"] as! [String: Any]
        for key in privateAtoms + ["unknown-target-only"] { try equalJSON(targetAtoms[key], previousAtoms[key], "target account atom changed") }
        for key in privateGlobals + ["unknown-target-only-global"] { try equalJSON(targetGlobals[key], previousGlobals[key], "target cloud/auth global changed") }
        try equalJSON(targetGlobals["queued-follow-ups"], [["id": "targetQueueB", "prompt": "pending B prompt"]], "target pending work was replaced")
        try equalJSON(projected["queued-follow-ups"], [["id": "sourceQueueA", "prompt": "pending A prompt"]], "source pending work was changed")
        var withoutQueue = fixture.root
        withoutQueue.removeValue(forKey: "queued-follow-ups")
        let noQueueProjection = try document(CodexLocalSettings.transfer(data: encode(withoutQueue), source: fixture.a, target: fixture.b))
        let noQueueTarget = try snapshot(noQueueProjection, fixture.b.rendererOwnerKey)["globals"] as! [String: Any]
        try equalJSON(noQueueTarget["queued-follow-ups"], [["id": "targetQueueB", "prompt": "pending B prompt"]], "missing source queue erased target pending work")
        try check(targetAtoms["unknown-source-only"] == nil && targetGlobals["unknown-source-only-global"] == nil, "unapproved source fields transferred")
        try equalJSON(projected[atomsKey], fixture.root[atomsKey], "active source atoms changed")
        for key in fixture.root.keys where key != rendererKey { try equalJSON(projected[key], fixture.root[key], "active root or unknown value changed") }
        try equalJSON(try snapshot(projected, fixture.c.rendererOwnerKey), try snapshot(fixture.root, fixture.c.rendererOwnerKey), "unrelated account changed")
        try equalJSON(target["future-snapshot-value"], beforeTarget["future-snapshot-value"], "unknown target snapshot field changed")
        let beforeMetadata = fixture.root[rendererKey] as! [String: Any], metadata = projected[rendererKey] as! [String: Any]
        try equalJSON(metadata["owner"], beforeMetadata["owner"], "active renderer owner changed early")
        try equalJSON(metadata["future-metadata-value"], beforeMetadata["future-metadata-value"], "unknown metadata changed")

        let runningB = try nativeStartup(projected, target: fixture.b.rendererOwnerKey)
        try equalJSON(runningB["local-projects"], ["project-a"], "native B load lost A projects")
        try equalJSON((runningB[atomsKey] as! [String: Any])["composer-prompt-drafts-v2"], ["thread-a": "unfinished A draft"], "native B load lost draft")
        try equalJSON((runningB[atomsKey] as! [String: Any])["composer-recent-model-configurations-v1"], ["model": "gpt-synthetic", "effort": "high"], "native B load lost model choice")
        try equalJSON((runningB[atomsKey] as! [String: Any])["sidebar-custom-sections-v3"], [["id": "section-a", "title": "Local projects"]], "native B load lost sidebar")
        try equalJSON(runningB["chatgpt-account-cache"], ["owner": "B"], "native B load acquired A cloud cache")
        try equalJSON(runningB["queued-follow-ups"], [["id": "targetQueueB", "prompt": "pending B prompt"]], "native B load replayed A pending work")
        let returnData = try CodexLocalSettings.transfer(data: encode(runningB), source: fixture.b, target: fixture.a)
        let runningA = try nativeStartup(document(returnData), target: fixture.a.rendererOwnerKey)
        try equalJSON(runningA["local-projects"], ["project-a"], "A/B/A lost local projects")
        try equalJSON((runningA[atomsKey] as! [String: Any])["composer-prompt-drafts-v2"], ["thread-a": "unfinished A draft"], "A/B/A lost draft")
        try equalJSON(runningA["chatgpt-account-cache"], ["owner": "A"], "A/B/A changed A cloud identity cache")
        try equalJSON(runningA["queued-follow-ups"], [["id": "sourceQueueA", "prompt": "pending A prompt"]], "A/B/A changed A pending work")
    }

    static func archivedOwnerChecks() throws {
        var fixture = try Fixture()
        var metadata = fixture.root[rendererKey] as! [String: Any]
        var inactive = metadata["inactive"] as! [String: Any]
        inactive[fixture.a.rendererOwnerKey] = ["atoms": ["prompt-history": ["archived A"]],
                                                "globals": ["local-projects": ["archived-project-a"], "chatgpt-account-cache": ["owner": "A"]]]
        metadata["owner"] = NSNull(); metadata["inactive"] = inactive; fixture.root[rendererKey] = metadata
        let first = try document(CodexLocalSettings.transfer(data: encode(fixture.root), source: fixture.a, target: fixture.b))
        let b = try snapshot(first, fixture.b.rendererOwnerKey)
        try equalJSON((b["atoms"] as! [String: Any])["prompt-history"], ["archived A"], "unbound owner read stale root atoms")
        try equalJSON((b["globals"] as! [String: Any])["local-projects"], ["archived-project-a"], "unbound owner read stale root projects")
        try equalJSON((b["globals"] as! [String: Any])["chatgpt-account-cache"], ["owner": "B"], "archived transfer changed target cloud cache")
        let returned = try document(CodexLocalSettings.transfer(data: encode(first), source: fixture.b, target: fixture.a))
        let a = try snapshot(returned, fixture.a.rendererOwnerKey)
        try equalJSON((a["atoms"] as! [String: Any])["prompt-history"], ["archived A"], "archived A/B/A lost history")
        try equalJSON((a["globals"] as! [String: Any])["local-projects"], ["archived-project-a"], "archived A/B/A lost projects")
        try equalJSON((a["globals"] as! [String: Any])["chatgpt-account-cache"], ["owner": "A"], "archived A/B/A changed A cloud cache")
    }

    static func unchangedAndRefusalChecks() throws {
        let fixture = try Fixture()
        let original = try encode(fixture.root)
        try check(try CodexLocalSettings.transfer(data: original, source: fixture.a, target: fixture.a) == original, "same identity changed settings bytes")
        let legacy = Data("{ \"electron-persisted-atom-state\": { \"unknown\": [1,2] }, \"local-projects\": [\"legacy\"] }\n\n".utf8)
        try check(try CodexLocalSettings.transfer(data: legacy, source: fixture.a, target: fixture.b) == legacy, "legacy settings bytes changed")
        try check(try CodexLocalSettings.transfer(data: legacy, source: nil, target: fixture.b) == legacy, "unbound legacy settings changed")
        let unbound = try encode([rendererKey: ["owner": NSNull(), "inactive": [:] as [String: Any]], "unknown": ["keep": true]])
        try check(try CodexLocalSettings.transfer(data: unbound, source: nil, target: fixture.b) == unbound, "empty unbound metadata changed")
        try unavailable { try CodexLocalSettings.transfer(data: original, source: fixture.c, target: fixture.b) }
        try unavailable { try CodexLocalSettings.transfer(data: original, source: nil, target: fixture.b) }
        try unavailable { try CodexLocalSettings.transfer(data: unbound, source: fixture.a, target: fixture.b) }
        var archived = fixture.root, metadata = archived[rendererKey] as! [String: Any]
        metadata["owner"] = NSNull(); archived[rendererKey] = metadata
        try unavailable { try CodexLocalSettings.transfer(data: encode(archived), source: nil, target: fixture.b) }
        try unavailable { try CodexLocalSettings.transfer(data: Data("[]".utf8), source: fixture.a, target: fixture.b) }
        try unavailable { try CodexLocalSettings.transfer(data: Data("not-json".utf8), source: fixture.a, target: fixture.b) }
        let malformed: [Any] = [NSNull(), [], ["owner": 1, "inactive": [:]], ["owner": fixture.a.rendererOwnerKey],
            ["inactive": [:]], ["owner": fixture.a.rendererOwnerKey, "inactive": []],
            ["owner": fixture.a.rendererOwnerKey, "inactive": [fixture.b.rendererOwnerKey: ["atoms": [], "globals": [:]]]],
            ["owner": fixture.a.rendererOwnerKey, "inactive": [fixture.b.rendererOwnerKey: ["atoms": [:], "globals": 5]]],
            ["owner": fixture.a.rendererOwnerKey, "inactive": [fixture.b.rendererOwnerKey: ["globals": [:]]]],
        ]
        for value in malformed {
            try unavailable { try CodexLocalSettings.transfer(data: encode([rendererKey: value]), source: fixture.a, target: fixture.b) }
        }
        try unavailable { try CodexLocalSettings.transfer(data: encode(["electron-account-renderer-state-v2": [:]]), source: fixture.a, target: fixture.b) }
        var malformedAtoms = fixture.root
        malformedAtoms[atomsKey] = [1, 2]
        try unavailable { try CodexLocalSettings.transfer(data: encode(malformedAtoms), source: fixture.a, target: fixture.b) }
        var oversizedResult = fixture.root
        var largeAtoms = oversizedResult[atomsKey] as! [String: Any]
        largeAtoms["prompt-history"] = String(repeating: "x", count: 1_700_000)
        oversizedResult[atomsKey] = largeAtoms
        let boundedInput = try encode(oversizedResult)
        try check(boundedInput.count < 3 * 1024 * 1024, "oversized-output fixture must have bounded input")
        try unavailable { try CodexLocalSettings.transfer(data: boundedInput, source: fixture.a, target: fixture.b) }
    }

    static func main() {
        do {
            try projectionChecks()
            try archivedOwnerChecks()
            try unchangedAndRefusalChecks()
            print("PASS Codex local settings: native A/B/A snapshots, local preferences, target account isolation, exact legacy bytes and safe refusal")
        } catch {
            if case SettingsCheckFailure.failed(let label) = error { print("FAIL \(label)") }
            else { print("FAIL Codex local settings projection") }
            exit(1)
        }
    }
}
