#if CODE_COVERAGE_KIT_ENABLED
import Foundation

/// SPI used only by the optional locally built Coverage merger. Ordinary SDK products do not link LLVM.
@_spi(OfflineMerge) public enum CoverageOfflineMergeRuntime {
    /// Registers an offline engine and explicitly measured limits on the Collector queue; does not enable merging or upload.
    public static func install(limits: CoverageMergeLimits, engine: @escaping @Sendable ([Data], CoverageMergeLimits) throws -> Data) {
        CoverageCollector.shared.installMergeEngine(limits: limits, engine: engine)
    }
}
#endif
