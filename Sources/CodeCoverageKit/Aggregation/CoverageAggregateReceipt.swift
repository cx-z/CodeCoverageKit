#if CODE_COVERAGE_KIT_ENABLED
import Foundation

struct CoverageAggregateReceipt: Codable, Sendable {
    let aggregate: CoverageAggregateRecord
    let accepted: CoverageUploadClient.AcceptedRun

    /// Rechecks strict acknowledgement binding during recovery; existence alone never completes source obligations.
    func validate() throws {
        try aggregate.validate()
        guard accepted.runID == aggregate.runID, accepted.cycleID == aggregate.cycleID,
              accepted.buildID == aggregate.buildID, accepted.sha256 == aggregate.sha256,
              accepted.size == aggregate.size, accepted.profileFormat == "indexed",
              accepted.metadataSHA256 == aggregate.metadataSHA256,
              [200, 201, 202].contains(accepted.statusCode) else { throw CocoaError(.fileReadCorruptFile) }
    }
}
#endif
