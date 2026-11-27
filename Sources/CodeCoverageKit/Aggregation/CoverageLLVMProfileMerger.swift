#if CODE_COVERAGE_KIT_ENABLED
import Foundation
import CCKProfileMerge

/// Internal offline LLVM bridge; the public facade owns automatic installation and the local switch.
enum CoverageLLVMProfileMerger {
    /// Installs the built-in engine and provisional SDK budgets before enabling the next manual upload on its serial owner.
    static func install(on collector: CoverageCollector) {
        collector.installMergeEngine(limits: .builtIn, engine: { try merge(profiles: $0, limits: $1) })
        collector.setCrossLaunchMergeEnabled(true)
    }

    /// Copies an independent complete result across the C boundary while retaining every NSData input for the whole call.
    static func merge(profiles: [Data], limits: CoverageMergeLimits) throws -> Data {
        guard (2...64).contains(limits.maxSources), (2...limits.maxSources).contains(profiles.count),
              limits.maxInputBytes > 0, limits.maxOutputBytes > 0, limits.maxRecords > 0,
              (1...60_000).contains(limits.timeoutMilliseconds) else {
            throw NSError(domain: "CodeCoverageKit.OfflineMerge", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "invalid merge budget"])
        }
        let t_storage = profiles.map { $0 as NSData }
        let t_inputs = t_storage.map { CCKProfileInput(bytes: $0.bytes, size: $0.length) }
        var t_result = CCKMergeResult()
        var t_error = [CChar](repeating: 0, count: 512)
        let t_code = withExtendedLifetime(t_storage) {
            cck_profile_merge(t_inputs, t_inputs.count, limits.maxInputBytes, limits.maxOutputBytes,
                limits.maxRecords, UInt64(limits.timeoutMilliseconds), &t_result, &t_error, t_error.count)
        }
        guard t_code == 0, let t_bytes = t_result.bytes else {
            throw NSError(domain: "CodeCoverageKit.OfflineMerge", code: Int(t_code),
                userInfo: [NSLocalizedDescriptionKey: String(cString: t_error)])
        }
        defer { cck_profile_merge_free(t_bytes) }
        return Data(bytes: t_bytes, count: t_result.size)
    }
}
#endif
