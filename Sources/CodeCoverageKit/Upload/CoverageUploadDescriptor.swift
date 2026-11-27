#if CODE_COVERAGE_KIT_ENABLED
import Foundation

/// Immutable transport identity; an aggregate never impersonates one of its source records.
struct CoverageUploadDescriptor: Sendable {
    let runID: String
    let cycleID: String
    let buildID: String
    let sha256: String
    let size: Int
    let metadata: Data
    let profileFormat: String
    let metadataSHA256: String?

    /// Keeps original Run metadata and response semantics unchanged for direct raw uploads.
    init(record: CoverageSnapshotRecord) throws {
        runID = record.runID; cycleID = record.cycleID; buildID = record.buildID
        sha256 = record.sha256; size = record.size; metadata = try record.makeRunMetadataData()
        profileFormat = "raw"; metadataSHA256 = nil
    }

    /// Binds strict indexed acknowledgements to both the new payload and its exact canonical source declaration.
    init(aggregate: CoverageAggregateRecord) {
        runID = aggregate.runID; cycleID = aggregate.cycleID; buildID = aggregate.buildID
        sha256 = aggregate.sha256; size = aggregate.size; metadata = aggregate.metadata
        profileFormat = "indexed"; metadataSHA256 = aggregate.metadataSHA256
    }
}
#endif
