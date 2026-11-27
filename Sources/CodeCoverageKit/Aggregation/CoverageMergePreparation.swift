#if CODE_COVERAGE_KIT_ENABLED
import Darwin
import Foundation

/// CPU-only worker: immutable sources/configuration in, complete candidate or explicit fallback out. Never owns Store state.
struct CoverageMergePreparation {
    struct Candidate {
        let aggregate: CoverageAggregateRecord
        let payload: Data
        let prepared: CoverageUploadClient.PreparedUpload
        let statistics: CoverageMergeStatistics
    }
    enum Outcome {
        case merged(Candidate)
        case fallback(String)
        case invalidSource(Error)
    }
    typealias Engine = @Sendable ([Data], CoverageMergeLimits) throws -> Data

    /// Computes bounded stable groups inside the original Cycle/Build/device, without recursively consuming aggregates.
    static func groups(_ records: [CoverageSnapshotRecord], limits: CoverageMergeLimits?) -> [[CoverageSnapshotRecord]] {
        let t_sorted = records.sorted { ($0.cycleID, $0.buildID, $0.deviceID, $0.capturedAt, $0.runID) < ($1.cycleID, $1.buildID, $1.deviceID, $1.capturedAt, $1.runID) }
        var t_groups: [[CoverageSnapshotRecord]] = []
        for t_record in t_sorted {
            if let t_last = t_groups.last, let t_first = t_last.first,
               t_first.cycleID == t_record.cycleID, t_first.buildID == t_record.buildID, t_first.deviceID == t_record.deviceID,
               t_last.count < (limits?.maxSources ?? 64),
               t_last.reduce(0, { $0 + $1.size }) <= (limits?.maxInputBytes ?? Int.max) - t_record.size {
                t_groups[t_groups.count - 1].append(t_record)
            } else { t_groups.append([t_record]) }
        }
        return t_groups
    }

    /// Reads every frozen source, uses LLVM independently, and compares exact full multipart gzip bytes including provenance.
    static func prepare(records: [CoverageSnapshotRecord], urls: [URL], rootURL: URL, launchID: String,
                        limits: CoverageMergeLimits, engine: Engine, client: CoverageUploadClient,
                        configuration: CoverageServerConfiguration, startedNanoseconds: UInt64) -> Outcome {
        let t_start = startedNanoseconds
        // Monotonic elapsed time covers file reads, LLVM and request comparisons even if wall-clock time changes.
        let t_elapsedMilliseconds = { Int((DispatchTime.now().uptimeNanoseconds - t_start) / 1_000_000) }
        guard limits.isValid, records.count >= 2, records.count <= limits.maxSources,
              records.count == urls.count, Set(records.map(\.launchID)).count >= 2 else { return .fallback("数量、格式或资源预算不满足合并条件，使用逐份 gzip。") }
        var t_inputBytes = 0
        for t_record in records {
            guard t_record.size > 0, t_record.size <= limits.maxInputBytes - t_inputBytes else {
                return .fallback("原始输入超出合并预算，使用逐份 gzip。")
            }
            t_inputBytes += t_record.size
        }
        var t_profiles: [Data] = []
        do {
            for (t_record, t_url) in zip(records, urls) {
                if t_elapsedMilliseconds() > limits.timeoutMilliseconds {
                    return .fallback("合并准备超时，使用逐份 gzip。")
                }
                let t_data = try Data(contentsOf: t_url)
                guard t_data.count == t_record.size, CoverageCanonicalJSON.sha256(t_data) == t_record.sha256 else {
                    throw CoverageSnapshotStore.StoreError.profileMismatch(t_record.runID)
                }
                t_profiles.append(t_data)
            }
        } catch { return .invalidSource(error) }
        do {
            let t_free = try FileManager.default.attributesOfFileSystem(forPath: rootURL.path)[.systemFreeSize] as? NSNumber
            guard let t_free, t_free.int64Value >= Int64(limits.minimumFreeDiskBytes) + Int64(limits.maxOutputBytes) else {
                return .fallback("可用空间不足，使用逐份 gzip。")
            }
            let t_remaining = limits.timeoutMilliseconds - t_elapsedMilliseconds()
            guard t_remaining > 0 else { return .fallback("合并准备超时，使用逐份 gzip。") }
            let t_payload = try engine(t_profiles, limits.withTimeout(milliseconds: t_remaining))
            guard t_payload.count <= limits.maxOutputBytes,
                  t_payload.prefix(16) == Data([0xff, 0x6c, 0x70, 0x72, 0x6f, 0x66, 0x69, 0x81, 12, 0, 0, 0, 0, 0, 0, 0]) else {
                return .fallback("合并输出不在已验证格式范围，使用逐份 gzip。")
            }
            if t_elapsedMilliseconds() > limits.timeoutMilliseconds {
                return .fallback("合并准备超时，使用逐份 gzip。")
            }
            let t_aggregate = try CoverageAggregateRecord(records: records, payload: t_payload, launchID: launchID)
            guard t_aggregate.metadata.count <= 64 * 1024 else { return .fallback("来源清单超限，使用逐份 gzip。") }
            var t_rawBytes = 0, t_maxRawBytes = 0
            for (t_record, t_profile) in zip(records, t_profiles) {
                if t_elapsedMilliseconds() > limits.timeoutMilliseconds {
                    return .fallback("请求字节比较超时，使用逐份 gzip。")
                }
                let t_size = try client.prepareUpload(descriptor: CoverageUploadDescriptor(record: t_record), profile: t_profile, configuration: configuration).body.count
                t_rawBytes += t_size; t_maxRawBytes = max(t_maxRawBytes, t_size)
            }
            let t_prepared = try client.prepareUpload(descriptor: CoverageUploadDescriptor(aggregate: t_aggregate), profile: t_payload, configuration: configuration)
            let t_elapsed = t_elapsedMilliseconds()
            var t_usage = rusage()
            guard getrusage(RUSAGE_SELF, &t_usage) == 0 else { return .fallback("无法验证资源占用，使用逐份 gzip。") }
            let t_savings = t_rawBytes - t_prepared.body.count
            guard t_prepared.body.count <= limits.maxRequestBytes,
                  Double(t_prepared.body.count) <= Double(t_maxRawBytes) * limits.maxRequestGrowthRatio,
                  t_savings >= limits.minimumSavingsBytes,
                  Double(t_savings) / Double(max(1, t_rawBytes)) >= limits.minimumSavingsRatio,
                  t_elapsed <= limits.timeoutMilliseconds, t_usage.ru_maxrss <= limits.maxProcessResidentBytes else {
                return .fallback("候选未达验收预算：\(records.count) 个来源，逐份 gzip 合计 \(t_rawBytes) 字节，候选 \(t_prepared.body.count) 字节，最大原请求 \(t_maxRawBytes) 字节，准备 \(t_elapsed) ms，进程峰值 RSS \(t_usage.ru_maxrss) 字节；使用逐份 gzip。")
            }
            return .merged(Candidate(aggregate: t_aggregate, payload: t_payload, prepared: t_prepared,
                statistics: CoverageMergeStatistics(sources: records.count, rawRequestBytes: t_rawBytes,
                    mergedRequestBytes: t_prepared.body.count, largestRawRequestBytes: t_maxRawBytes,
                    preparationMilliseconds: t_elapsed, processPeakResidentBytes: Int(t_usage.ru_maxrss))))
        } catch {
            let t_error = error as NSError
            if t_error.domain == "CodeCoverageKit.OfflineMerge" {
                let t_reason: String
                switch t_error.code {
                case 1: t_reason = "输入格式或附加特性尚未验证支持"
                case 2: t_reason = "LLVM 读取、合并或输出校验失败"
                case 3: t_reason = "合并输入、记录或输出预算不足"
                case 4: t_reason = "合并准备超时"
                case 5: t_reason = "合并内存分配失败"
                default: t_reason = "离线合并失败"
                }
                return .fallback(t_reason + "，使用逐份 gzip。")
            }
            return .fallback("合并对象或 gzip 请求准备失败，使用逐份 gzip。")
        }
    }
}
#endif
