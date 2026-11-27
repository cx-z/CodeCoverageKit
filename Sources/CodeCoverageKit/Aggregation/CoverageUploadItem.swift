#if CODE_COVERAGE_KIT_ENABLED
import Foundation

/// One fixed network object; raw state and aggregate receipts have distinct commit paths.
enum CoverageUploadItem {
    case raw(CoverageSnapshotRecord, URL)
    case aggregate(CoverageAggregateRecord, URL, CoverageUploadClient.PreparedUpload, CoverageMergeStatistics)

    /// Supplies the exact metadata/payload identity without reinterpreting a source Run as directly uploaded.
    func descriptor() throws -> CoverageUploadDescriptor {
        switch self {
        case .raw(let t_record, _): return try CoverageUploadDescriptor(record: t_record)
        case .aggregate(let t_record, _, _, _): return CoverageUploadDescriptor(aggregate: t_record)
        }
    }
}
#endif
