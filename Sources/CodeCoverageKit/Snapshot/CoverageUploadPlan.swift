#if CODE_COVERAGE_KIT_ENABLED
import Foundation

/// Derives upload representatives without deleting or relabelling immutable Runs.
struct CoverageUploadPlan {
    let records: [CoverageSnapshotRecord]
    let suppressedRunIDs: Set<String>

    /// Keeps ambiguous/legacy groups and permanent errors visible; only validated ordered Runs may dominate; durable aggregate receipts complete exact sources. Concurrent sampling requires explicit independent validation before coalescing.
    init(records: [CoverageSnapshotRecord], validRunIDs: Set<String>, protectedRunIDs: Set<String> = [], deliveredRunIDs: Set<String> = [], coalescingEnabled: Bool = false) {
        let t_groups = Dictionary(grouping: records) {
            [$0.cycleID, $0.buildID, $0.deviceID, $0.launchID, String($0.processID)]
        }
        var t_suppressed = Set<String>()
        for t_group in t_groups.values where coalescingEnabled {
            let t_sequences = t_group.compactMap(\.captureSequence)
            guard t_sequences.count == t_group.count,
                  t_sequences.allSatisfy({ $0 > 0 }),
                  Set(t_sequences).count == t_sequences.count,
                  t_group.allSatisfy({ validRunIDs.contains($0.runID) }) else { continue }
            let t_candidates = t_group.filter { $0.uploadStatus != .failedPermanent }
            guard let t_latest = t_candidates.max(by: { $0.captureSequence! < $1.captureSequence! }) else { continue }
            for t_record in t_candidates where t_record.captureSequence! < t_latest.captureSequence! {
                if (t_record.uploadStatus == .pending || t_record.uploadStatus == .failedRetryable),
                   !protectedRunIDs.contains(t_record.runID) {
                    t_suppressed.insert(t_record.runID)
                }
            }
        }
        suppressedRunIDs = t_suppressed
        self.records = records.filter { $0.uploadStatus == .failedPermanent || (!t_suppressed.contains($0.runID) && !deliveredRunIDs.contains($0.runID)) }.sorted {
            ($0.capturedAt, $0.runID) < ($1.capturedAt, $1.runID)
        }
    }
}
#endif
