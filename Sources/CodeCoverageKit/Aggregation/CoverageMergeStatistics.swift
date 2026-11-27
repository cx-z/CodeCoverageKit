#if CODE_COVERAGE_KIT_ENABLED
import Foundation
import Darwin

struct CoverageMergeStatistics: Sendable {
    let sources: Int
    let rawRequestBytes: Int
    let mergedRequestBytes: Int
    let largestRawRequestBytes: Int
    let preparationMilliseconds: Int
    let processPeakResidentBytes: Int

    /// Includes scheduler wait, durable object/attempt publication and their RSS peak before the first network send.
    func finalized(startedNanoseconds: UInt64) -> CoverageMergeStatistics? {
        var t_usage = rusage()
        guard getrusage(RUSAGE_SELF, &t_usage) == 0 else { return nil }
        let t_elapsed = Int((DispatchTime.now().uptimeNanoseconds - startedNanoseconds + 999_999) / 1_000_000)
        return CoverageMergeStatistics(sources: sources, rawRequestBytes: rawRequestBytes, mergedRequestBytes: mergedRequestBytes,
            largestRawRequestBytes: largestRawRequestBytes, preparationMilliseconds: t_elapsed,
            processPeakResidentBytes: max(processPeakResidentBytes, Int(t_usage.ru_maxrss)))
    }

    /// Describes the complete gzip group comparison and single-request retry exposure without substituting raw Run metrics.
    var description: String {
        "合并对象：\(sources) 个来源；逐份 gzip 合计 \(rawRequestBytes) 字节，合并 gzip \(mergedRequestBytes) 字节；最大原请求 \(largestRawRequestBytes) 字节；三次发送上限 \(mergedRequestBytes * 3) 字节；准备 \(preparationMilliseconds) ms；进程峰值 RSS \(processPeakResidentBytes) 字节"
    }
}
#endif
