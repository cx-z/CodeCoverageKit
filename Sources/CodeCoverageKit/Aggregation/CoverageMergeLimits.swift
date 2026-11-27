#if CODE_COVERAGE_KIT_ENABLED
import Foundation

/// Internal merge budgets; built-in acceptance limits remain provisional until device resource measurements are complete.
@_spi(OfflineMerge) public struct CoverageMergeLimits: Sendable {
    public let maxSources: Int
    public let maxInputBytes: Int
    public let maxOutputBytes: Int
    public let maxRecords: Int
    public let timeoutMilliseconds: Int
    public let maxRequestBytes: Int
    public let maxRequestGrowthRatio: Double
    public let minimumSavingsBytes: Int
    public let minimumSavingsRatio: Double
    public let maxProcessResidentBytes: Int
    public let minimumFreeDiskBytes: Int

    /// Provides bounded SDK-owned defaults for internal device acceptance; hosts do not assemble an engine or budgets.
    static var builtIn: CoverageMergeLimits {
        CoverageMergeLimits(maxSources: 32, maxInputBytes: 32 * 1024 * 1024,
            maxOutputBytes: 32 * 1024 * 1024, maxRecords: 2_000_000,
            timeoutMilliseconds: 5_000, maxRequestBytes: 8 * 1024 * 1024,
            maxRequestGrowthRatio: 8, minimumSavingsBytes: 128,
            minimumSavingsRatio: 0.05, maxProcessResidentBytes: 2 * 1024 * 1024 * 1024,
            minimumFreeDiskBytes: 256 * 1024 * 1024)
    }

    /// Creates explicit limits for SDK assembly and isolated validation; these values do not attest device acceptance.
    public init(maxSources: Int, maxInputBytes: Int, maxOutputBytes: Int, maxRecords: Int,
                timeoutMilliseconds: Int, maxRequestBytes: Int, maxRequestGrowthRatio: Double,
                minimumSavingsBytes: Int, minimumSavingsRatio: Double,
                maxProcessResidentBytes: Int, minimumFreeDiskBytes: Int) {
        self.maxSources = maxSources; self.maxInputBytes = maxInputBytes; self.maxOutputBytes = maxOutputBytes
        self.maxRecords = maxRecords; self.timeoutMilliseconds = timeoutMilliseconds; self.maxRequestBytes = maxRequestBytes
        self.maxRequestGrowthRatio = maxRequestGrowthRatio; self.minimumSavingsBytes = minimumSavingsBytes
        self.minimumSavingsRatio = minimumSavingsRatio; self.maxProcessResidentBytes = maxProcessResidentBytes
        self.minimumFreeDiskBytes = minimumFreeDiskBytes
    }

    /// Gives LLVM only the time remaining after earlier immutable reads; all size, resource and benefit budgets stay fixed.
    func withTimeout(milliseconds: Int) -> CoverageMergeLimits {
        CoverageMergeLimits(maxSources: maxSources, maxInputBytes: maxInputBytes, maxOutputBytes: maxOutputBytes,
            maxRecords: maxRecords, timeoutMilliseconds: milliseconds, maxRequestBytes: maxRequestBytes,
            maxRequestGrowthRatio: maxRequestGrowthRatio, minimumSavingsBytes: minimumSavingsBytes,
            minimumSavingsRatio: minimumSavingsRatio, maxProcessResidentBytes: maxProcessResidentBytes,
            minimumFreeDiskBytes: minimumFreeDiskBytes)
    }

    /// Rejects missing, nonfinite or protocol-incompatible budgets before any merge is scheduled.
    var isValid: Bool {
        (2...64).contains(maxSources) && (1...64 * 100 * 1024 * 1024).contains(maxInputBytes) && (1...100 * 1024 * 1024).contains(maxOutputBytes) && maxRecords > 0 &&
        (1...60_000).contains(timeoutMilliseconds) && (1...100 * 1024 * 1024).contains(maxRequestBytes) &&
        maxRequestGrowthRatio.isFinite && maxRequestGrowthRatio > 0 && minimumSavingsBytes > 0 &&
        minimumSavingsRatio.isFinite && (0...1).contains(minimumSavingsRatio) &&
        maxProcessResidentBytes > 0 && minimumFreeDiskBytes > 0 && minimumFreeDiskBytes <= Int.max - maxOutputBytes
    }
}
#endif
