#if CODE_COVERAGE_KIT_ENABLED
import Foundation

/// Mutable progress belongs exclusively to CoverageCollector's serial queue; workers receive copied immutable inputs.
final class CoverageUploadBatch {
    let groups: [[CoverageSnapshotRecord]]
    let snapshot: (record: CoverageSnapshotRecord, duration: Int)
    let configuration: CoverageServerConfiguration
    let limits: CoverageMergeLimits?
    let engine: CoverageMergePreparation.Engine?
    let progress: ((CoverageCollector.Summary) -> Void)?
    let completion: (Result<CoverageCollector.UploadReport, Error>) -> Void
    var groupIndex = 0
    var uploadedRunIDs: [String] = []
    var failedRunIDs: [String] = []
    var deliveredSources = 0
    var statistics: [CoverageMergeStatistics] = []
    var fallbackReasons: [String] = []
    var isPreparing = false
    var preparationStartedNanoseconds: UInt64?

    /// Freezes representatives, grouping, configuration, engine and budgets at the user's upload action.
    init(records: [CoverageSnapshotRecord], snapshot: (record: CoverageSnapshotRecord, duration: Int),
         configuration: CoverageServerConfiguration, limits: CoverageMergeLimits?, engine: CoverageMergePreparation.Engine?,
         progress: ((CoverageCollector.Summary) -> Void)?, completion: @escaping (Result<CoverageCollector.UploadReport, Error>) -> Void) {
        groups = CoverageMergePreparation.groups(records, limits: limits)
        self.snapshot = snapshot; self.configuration = configuration; self.limits = limits; self.engine = engine
        self.progress = progress; self.completion = completion
    }
}
#endif
