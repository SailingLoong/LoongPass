// Native-only evidence framework. No environment/settings/credential/process
// reader, account catalogue, session opener, network or lifecycle effect exists.
import Foundation

enum ZcodeObservedFact: Codable, Equatable, CustomStringConvertible {
    case unknown, unset, value(String)
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
        static let state = Key(stringValue: "state")!, value = Key(stringValue: "value")!
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let state = try c.decode(String.self, forKey: .state)
        let keys = Set(c.allKeys.map(\.stringValue))
        switch state {
        case "unknown" where keys == ["state"]: self = .unknown
        case "unset" where keys == ["state"]: self = .unset
        case "value" where keys == ["state", "value"]:
            let value = try c.decode(String.self, forKey: .value)
            guard value.utf8.count <= 4096, !value.contains("\0") else { throw ZcodeBridgeFailure.invalidArguments }
            self = .value(value)
        default: throw ZcodeBridgeFailure.invalidArguments
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .unknown: try c.encode("unknown", forKey: .state)
        case .unset: try c.encode("unset", forKey: .state)
        case .value(let value):
            guard value.utf8.count <= 4096, !value.contains("\0") else { throw ZcodeBridgeFailure.invalidArguments }
            try c.encode("value", forKey: .state); try c.encode(value, forKey: .value)
        }
    }
    var description: String {
        switch self { case .unknown: return "Unknown"; case .unset: return "Unset"; case .value: return "Value(redacted)" }
    }
}

enum ZcodeFactsSource: String { case unavailable, synthetic, explicitNativeEvidence }
struct ZcodeRuntimeFacts: Codable {
    var zcodeEnv: ZcodeObservedFact = .unknown
    var baseUrl: ZcodeObservedFact = .unknown
    var endpointOrigin: ZcodeObservedFact = .unknown
    var productionBaseUrl: ZcodeObservedFact = .unknown
    var testBaseUrl: ZcodeObservedFact = .unknown
    var overrideOrigin: ZcodeObservedFact = .unknown
    var processArch: ZcodeObservedFact = .unknown
}
struct ZcodeFactsEvidence {
    var source: ZcodeFactsSource = .unavailable
    var revision: UInt64 = 0
    var bootstrapObserved = false, readyObserved = false
    var runtimeDataDir: ZcodeObservedFact = .unknown
    var environmentDataDir: ZcodeObservedFact = .unknown
    var effectiveHome: ZcodeObservedFact = .unknown
    var platform: ZcodeObservedFact = .unknown
    var username: ZcodeObservedFact = .unknown
    var runtimeFacts = ZcodeRuntimeFacts()
    // No secret field: establishing that proof is outside this framework.
}
enum ZcodeFactsDiagnostic: String {
    case appIdentityUnproven, dataDirectoryPhasesUnproven, credentialContextUnproven
    case writerCoverageUnproven, launchContractUnproven, productionDisabled
    case runtimeFactsPartiallyUnknown, syntheticEvidenceOnly, rustContextUnproven
}
private struct ZcodeRustFacts: Encodable {
    let app: ZcodeOwnerApp
    let runtimeDataDir, environmentDataDir, effectiveHome: ZcodeObservedFact
    let credentialSecret: ZcodeObservedFact = .unknown
    let platform, username: ZcodeObservedFact
    let runtimeFacts: ZcodeRuntimeFacts
}
struct ZcodeFactsInspection: CustomStringConvertible {
    let app: ZcodeAppObservation?
    let source: ZcodeFactsSource
    let revision: UInt64
    let diagnostics: Set<ZcodeFactsDiagnostic>
    let unknownFields: [String]
    let rustMetadataAvailable: Bool
    private let facts: ZcodeRustFacts?
    fileprivate init(app: ZcodeAppObservation?, evidence: ZcodeFactsEvidence,
                     diagnostics: Set<ZcodeFactsDiagnostic>, unknownFields: [String],
                     facts: ZcodeRustFacts?, rustMetadataAvailable: Bool) {
        self.app = app; source = evidence.source; revision = evidence.revision
        self.diagnostics = diagnostics; self.unknownFields = unknownFields
        self.facts = facts; self.rustMetadataAvailable = rustMetadataAvailable
    }
    func rustFactsData() throws -> Data {
        guard let facts = facts else { throw ZcodeBridgeFailure.nativeContextUnavailable }
        return try JSONEncoder().encode(facts)
    }
    // Uses the existing owner/ABI decision path; never configures a Rust session.
    // Empty context and incomplete coverage cannot authorize any lifecycle effect.
    func makeBlockedOwner(uid: UInt32) throws -> ZcodeContextOwner {
        guard let app = app else { throw ZcodeBridgeFailure.nativeContextUnavailable }
        let binding = ZcodeOwnerBinding(app: app.app, contextId: "", uid: uid, main: nil)
        let snapshot = ZcodeOwnerSnapshot(app: app.app, contextId: "", complete: false,
            otherWriters: false, processes: [])
        return ZcodeContextOwner(binding: binding, snapshot: { snapshot },
            terminate: { _ in throw ZcodeBridgeFailure.nativeContextUnavailable },
            launch: { _ in throw ZcodeBridgeFailure.nativeContextUnavailable })
    }
    var description: String { "ZcodeFactsInspection(\(diagnostics.map(\.rawValue).sorted().joined(separator: ",")))" }
}
struct ZcodeFactsProvider {
    func inspect(appURL: URL, evidence supplied: ZcodeFactsEvidence = ZcodeFactsEvidence()) -> ZcodeFactsInspection {
        var evidence = supplied.source == .unavailable ? ZcodeFactsEvidence() : supplied
        let phases = evidence.bootstrapObserved && evidence.readyObserved
        if !phases { evidence.runtimeDataDir = .unknown }
        let app = try? ZcodeAppIdentityCollector().collect(at: appURL)
        var diagnostics: Set<ZcodeFactsDiagnostic> = [.credentialContextUnproven,
            .writerCoverageUnproven, .launchContractUnproven, .productionDisabled, .rustContextUnproven]
        if app == nil { diagnostics.insert(.appIdentityUnproven) }
        if !phases { diagnostics.insert(.dataDirectoryPhasesUnproven) }
        if evidence.source == .synthetic { diagnostics.insert(.syntheticEvidenceOnly) }
        var facts: ZcodeRustFacts?
        if let app = app {
            facts = ZcodeRustFacts(app: app.app, runtimeDataDir: evidence.runtimeDataDir,
                environmentDataDir: evidence.environmentDataDir, effectiveHome: evidence.effectiveHome,
                platform: evidence.platform, username: evidence.username, runtimeFacts: evidence.runtimeFacts)
        }
        let observed: [(String, ZcodeObservedFact)] = [
            ("runtimeDataDir", evidence.runtimeDataDir), ("environmentDataDir", evidence.environmentDataDir),
            ("effectiveHome", evidence.effectiveHome), ("platform", evidence.platform), ("username", evidence.username),
            ("credentialSecret", .unknown), ("runtimeFacts.zcodeEnv", evidence.runtimeFacts.zcodeEnv),
            ("runtimeFacts.baseUrl", evidence.runtimeFacts.baseUrl), ("runtimeFacts.endpointOrigin", evidence.runtimeFacts.endpointOrigin),
            ("runtimeFacts.productionBaseUrl", evidence.runtimeFacts.productionBaseUrl), ("runtimeFacts.testBaseUrl", evidence.runtimeFacts.testBaseUrl),
            ("runtimeFacts.overrideOrigin", evidence.runtimeFacts.overrideOrigin), ("runtimeFacts.processArch", evidence.runtimeFacts.processArch)]
        let unknown = observed.filter { $0.1 == .unknown }.map { $0.0 }
        // Unobserved fields are diagnostic, not a second endpoint resolver:
        // lower-priority Unknown facts may be irrelevant to Rust's selected path.
        if unknown.contains(where: { $0.hasPrefix("runtimeFacts.") }) { diagnostics.insert(.runtimeFactsPartiallyUnknown) }
        var metadataAvailable = false
        if let facts = facts, let data = try? JSONEncoder().encode(facts), data.count <= 65_536 {
            let pointer = data.withUnsafeBytes { lp_zcode_owner_metadata($0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
            if let pointer = pointer {
                defer { lp_zcode_free(pointer) }
                // Deliberately consume only success/error shape; never echo ABI payload.
                if let reply = try? JSONSerialization.jsonObject(with: Data(bytes: pointer, count: strlen(pointer))) as? [String: Any] {
                    metadataAvailable = reply["error"] == nil && reply["contextId"] is String
                }
            }
        }
        return ZcodeFactsInspection(app: app, evidence: evidence, diagnostics: diagnostics,
            unknownFields: unknown, facts: facts, rustMetadataAvailable: metadataAvailable)
    }
}
