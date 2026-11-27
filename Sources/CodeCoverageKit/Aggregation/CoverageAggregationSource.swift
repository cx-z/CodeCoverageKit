#if CODE_COVERAGE_KIT_ENABLED
import Foundation

struct CoverageAggregationSource: Codable, Equatable, Sendable {
    let runID: String
    let launchID: String
    let processID: Int32
    let capturedAt: String
    let size: Int
    let sha256: String
    let metadataSHA256: String
    let captureSequence: Int?

    /// Fixes the exact raw representative identity; never includes indirectly represented older snapshots.
    init(record: CoverageSnapshotRecord) throws {
        runID = record.runID; launchID = record.launchID; processID = record.processID
        capturedAt = record.capturedAt; size = record.size; sha256 = record.sha256
        captureSequence = record.captureSequence
        let t_metadata = try JSONSerialization.jsonObject(with: record.makeRunMetadataData())
        metadataSHA256 = CoverageCanonicalJSON.sha256(try CoverageCanonicalJSON.encode(t_metadata))
    }

    /// Produces the protocol source object, omitting an absent local ordering sequence.
    func jsonObject() -> [String: Any] {
        var t_value: [String: Any] = ["run_id": runID, "launch_id": launchID, "process_id": processID,
            "captured_at": capturedAt, "size": size, "sha256": sha256, "metadata_sha256": metadataSHA256]
        if let captureSequence { t_value["capture_sequence"] = captureSequence }
        return t_value
    }
}
#endif
