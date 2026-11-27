#if CODE_COVERAGE_KIT_ENABLED
import Foundation

struct CoverageAggregateRecord: Codable, Equatable, Sendable {
    let runID: String
    let cycleID: String
    let buildID: String
    let deviceID: String
    let metadata: Data
    let metadataSHA256: String
    let size: Int
    let sha256: String
    let sources: [CoverageAggregationSource]
    var attemptCount: Int = 0
    var lastError: String?
    var permanentError: String?

    /// Creates a new upload identity for precisely these original sources and this complete indexed payload.
    init(records: [CoverageSnapshotRecord], payload: Data, launchID: String) throws {
        guard let t_first = records.first, records.count >= 2,
              Set(records.map(\.runID)).count == records.count,
              Set(records.map(\.launchID)).count >= 2,
              records.allSatisfy({ $0.cycleID == t_first.cycleID && $0.buildID == t_first.buildID && $0.deviceID == t_first.deviceID }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        runID = UUID().uuidString.lowercased(); cycleID = t_first.cycleID; buildID = t_first.buildID; deviceID = t_first.deviceID
        sources = try records.sorted { $0.runID < $1.runID }.map(CoverageAggregationSource.init(record:))
        size = payload.count; sha256 = CoverageCanonicalJSON.sha256(payload)
        metadata = try CoverageCanonicalJSON.encode([
            "schema_version": 1, "run_id": runID, "cycle_id": cycleID, "build_id": buildID,
            "device_id": deviceID, "launch_id": launchID, "process_id": getpid(),
            "captured_at": ISO8601DateFormatter().string(from: Date()), "app_state": "unknown",
            "trigger_reason": "cross_launch_merge", "profile_format": "indexed",
            "aggregation": ["schema_version": 1, "merger_version": "llvm-20.1.8/cck-1", "sources": sources.map { $0.jsonObject() }]
        ])
        metadataSHA256 = CoverageCanonicalJSON.sha256(metadata)
    }

    /// Compares the fixed network identity while allowing only local attempt diagnostics to advance.
    func hasSameIdentity(as other: CoverageAggregateRecord) -> Bool {
        runID == other.runID && cycleID == other.cycleID && buildID == other.buildID && deviceID == other.deviceID &&
        metadata == other.metadata && metadataSHA256 == other.metadataSHA256 && size == other.size &&
        sha256 == other.sha256 && sources == other.sources
    }

    /// Verifies the stored canonical metadata against the typed object before it can authorize a receipt.
    func validate() throws {
        let t_value = try JSONSerialization.jsonObject(with: metadata)
        guard let t_metadata = t_value as? [String: Any],
              try CoverageCanonicalJSON.encode(t_value) == metadata,
              CoverageCanonicalJSON.sha256(metadata) == metadataSHA256,
              t_metadata["run_id"] as? String == runID, t_metadata["cycle_id"] as? String == cycleID,
              t_metadata["build_id"] as? String == buildID, t_metadata["device_id"] as? String == deviceID,
              t_metadata["profile_format"] as? String == "indexed",
              let t_aggregation = t_metadata["aggregation"] as? [String: Any],
              let t_sources = t_aggregation["sources"],
              try CoverageCanonicalJSON.encode(t_sources) == CoverageCanonicalJSON.encode(sources.map { $0.jsonObject() }),
              sources.count >= 2, sources.count <= 64,
              sources.map(\.runID) == Array(Set(sources.map(\.runID))).sorted(),
              Set(sources.map(\.launchID)).count >= 2 else { throw CocoaError(.fileReadCorruptFile) }
    }
}
#endif
