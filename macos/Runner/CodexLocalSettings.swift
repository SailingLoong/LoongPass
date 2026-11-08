import Foundation

enum CodexLocalSettings {
    static let fileName = ".codex-global-state.json"
    static let maximumBytes = 3 * 1024 * 1024

    /// Protocol keys from the installed official renderer's account-state
    /// controller. Transfer only explicitly local state; all other values remain
    /// owned by their original account, including unknown future fields.
    private enum Keys {
        static let renderer = "electron-account-renderer-state-v1"
        static let rendererPrefix = "electron-account-renderer-state-"
        static let persistedAtoms = "electron-persisted-atom-state"
        static let owner = "owner"
        static let inactive = "inactive"
        static let atoms = "atoms"
        static let globals = "globals"
        static let localGlobals: Set<String> = [
            "open-in-target-preferences", "worktree-repository-preferences", "active-workspace-roots",
            "electron-saved-workspace-roots", "electron-workspace-root-labels", "local-projects",
            "app-server-project-id-by-legacy-project-id-by-host", "app-server-projects-migration-by-host",
            "selected-project", "project-writable-roots", "project-appearances", "project-files",
            "pinned-thread-ids", "app-server-migrated-pinned-thread-ids-by-host", "pinned-project-ids",
            "sidebar-project-thread-orders", "sidebar-thread-metadata", "thread-project-assignments",
            "thread-project-membership-host-ids", "thread-writable-roots", "thread-workspace-root-hints",
            "thread-projectless-output-directories", "projectless-thread-ids", "project-order",
        ]
        static let localAtoms: Set<String> = [
            "composer-prompt-drafts-v1", "composer-prompt-drafts-v2", "composer-recent-model-configurations-v1",
            "composer-auto-context-enabled", "prompt-history", "flat-project-sidebar-preferences-v1",
            "sidebar-custom-sections-v3", "sidebar-collapsed-sections-v1", "agent-mode-by-host-id",
        ]
        static let localAtomPrefixes = [
            "sidebar-project-expanded-v1-codex:", "thread-tab-routes-v1:", "permission-selection-by-host-id:",
        ]

        static func isLocalAtom(_ key: String) -> Bool {
            localAtoms.contains(key) || localAtomPrefixes.contains(where: { key.hasPrefix($0) })
        }
    }

    private static func document(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= maximumBytes,
              let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              !document.keys.contains(where: { $0.hasPrefix(Keys.rendererPrefix) && $0 != Keys.renderer }) else {
            throw CodexFailure.settingsUnavailable
        }
        return document
    }

    static func activeOwner(data: Data) throws -> String? {
        do {
            let value = try document(data)
            guard let renderer = value[Keys.renderer] else { return nil }
            guard let metadata = renderer as? [String: Any], let owner = metadata[Keys.owner] else {
                throw CodexFailure.settingsUnavailable
            }
            if owner is NSNull { return nil }
            guard let key = owner as? String else { throw CodexFailure.settingsUnavailable }
            return key
        } catch { throw CodexFailure.settingsUnavailable }
    }

    static func transfer(data: Data, source: CodexCredential?, target: CodexCredential) throws -> Data {
        do {
            var document = try document(data)
            // Earlier clients have no account renderer boundary to seed.
            guard let value = document[Keys.renderer] else { return data }
            guard var metadata = value as? [String: Any], let owner = metadata[Keys.owner],
                  owner is NSNull || owner is String,
                  let rawInactive = metadata[Keys.inactive] as? [String: Any] else { throw CodexFailure.settingsUnavailable }
            var inactive: [String: [String: Any]] = [:]
            for (key, value) in rawInactive {
                guard let snapshot = value as? [String: Any],
                      snapshot[Keys.atoms] is [String: Any], snapshot[Keys.globals] is [String: Any] else {
                    throw CodexFailure.settingsUnavailable
                }
                inactive[key] = snapshot
            }
            guard let source else {
                guard owner is NSNull, inactive.isEmpty else { throw CodexFailure.settingsUnavailable }
                return data
            }
            let sourceAtoms: [String: Any], sourceGlobals: [String: Any]
            if let activeOwner = owner as? String {
                guard activeOwner == source.rendererOwnerKey else { throw CodexFailure.settingsUnavailable }
                if let atoms = document[Keys.persistedAtoms] {
                    guard let atoms = atoms as? [String: Any] else { throw CodexFailure.settingsUnavailable }
                    sourceAtoms = atoms
                } else { sourceAtoms = [:] }
                sourceGlobals = document
            } else {
                guard let archived = inactive[source.rendererOwnerKey],
                      let atoms = archived[Keys.atoms] as? [String: Any],
                      let globals = archived[Keys.globals] as? [String: Any] else { throw CodexFailure.settingsUnavailable }
                sourceAtoms = atoms
                sourceGlobals = globals
            }
            guard source.rendererOwnerKey != target.rendererOwnerKey else { return data }
            let previous = inactive[target.rendererOwnerKey]
            var snapshot = previous ?? [Keys.atoms: [String: Any](), Keys.globals: [String: Any]()]
            var atoms = (snapshot[Keys.atoms] as! [String: Any]).filter { !Keys.isLocalAtom($0.key) }
            var globals = (snapshot[Keys.globals] as! [String: Any]).filter { !Keys.localGlobals.contains($0.key) }
            for (key, value) in sourceAtoms where Keys.isLocalAtom(key) { atoms[key] = value }
            for key in Keys.localGlobals { globals[key] = sourceGlobals[key] }
            snapshot[Keys.atoms] = atoms
            snapshot[Keys.globals] = globals
            if let previous, NSDictionary(dictionary: snapshot).isEqual(to: previous) { return data }
            if previous == nil, atoms.isEmpty, globals.isEmpty { return data }
            inactive[target.rendererOwnerKey] = snapshot
            metadata[Keys.inactive] = inactive
            document[Keys.renderer] = metadata
            let result = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            guard result.count <= maximumBytes else { throw CodexFailure.settingsUnavailable }
            return result
        } catch { throw CodexFailure.settingsUnavailable }
    }
}
