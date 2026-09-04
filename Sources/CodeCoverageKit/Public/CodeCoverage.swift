#if CODE_COVERAGE_KIT_ENABLED && canImport(UIKit)
import UIKit

/// Coverage Debug 构建的公共门面；所有入口都在主 Actor 调用，内部状态所有权不会暴露给宿主。
@MainActor
public enum CodeCoverage {
    /// 一次已原子落盘但尚未自动上传的本地 profile 快照摘要。
    public struct SnapshotResult: Sendable {
        /// 本地生成且随该快照持久化的 Run UUID，不包含凭证或文件路径。
        public let runID: String
        /// `.profraw` 快照的实际字节数。
        public let size: Int
        /// `.profraw` 内容的小写十六进制 SHA-256，不包含敏感信息。
        public let sha256: String
        /// 从读取 LLVM runtime 到原子提交清单的近似耗时，单位为毫秒。
        public let durationMilliseconds: Int
        /// 本次快照完成后，所有 Build 仍待上传或可重试的 Run 数量。
        public let pendingCount: Int

        /// 创建供宿主展示的不可变快照结果，不暴露 SDK 内部存储记录。
        fileprivate init(report: CoverageCollector.SnapshotReport) {
            runID = report.runID
            size = report.size
            sha256 = report.sha256
            durationMilliseconds = report.durationMilliseconds
            pendingCount = report.summary.pendingCount
        }
    }

    /// 一次用户主动上传操作的不可变结果；不包含 Token、服务器响应原文或本地文件路径。
    public struct UploadResult: Sendable {
        /// 本轮上传前自动生成的最新 Run UUID。
        public let latestRunID: String
        /// 本轮上传前最新 `.profraw` 快照的实际字节数。
        public let latestSnapshotSize: Int
        /// 最新 `.profraw` 快照的小写十六进制 SHA-256。
        public let latestSnapshotSHA256: String
        /// 最新快照从读取 runtime 到原子提交清单的近似耗时，单位为毫秒。
        public let latestSnapshotDurationMilliseconds: Int
        /// 本次用户操作中经服务端严格回显校验后标记为已上传的 Run 数量。
        public let uploadedCount: Int
        /// 本次用户操作中进入可重试或永久失败状态的 Run 数量。
        public let failedCount: Int
        /// 本轮结束后所有 Build 仍待上传或可重试的 Run 数量。
        public let pendingCount: Int
        /// 是否因服务端返回 401/403 而立即停止本轮剩余上传。
        public let stoppedForAuthentication: Bool

        /// 创建供宿主消费的不可变上传结果，不泄露 Token、Store 或上传客户端。
        fileprivate init(report: CoverageCollector.UploadReport) {
            latestRunID = report.snapshotRunID
            latestSnapshotSize = report.snapshotSize
            latestSnapshotSHA256 = report.snapshotSHA256
            latestSnapshotDurationMilliseconds = report.snapshotDurationMilliseconds
            uploadedCount = report.uploadedRunIDs.count
            failedCount = report.failedRunIDs.count
            pendingCount = report.summary.pendingCount
            stoppedForAuthentication = report.stoppedForAuthentication
        }
    }

    private static var vDidStart = false
    private static var vBackgroundObserver: NSObjectProtocol?
    private static var vForegroundObserver: NSObjectProtocol?

    /// 返回当前 App Bundle 是否包含 SDK 可识别且校验通过的 Coverage Build metadata；不返回或记录其中的 Token。
    public static var isAvailable: Bool {
        (try? CoverageBuildMetadata.load()) != nil
    }

    /// 在主 Actor 启动本地采集、恢复历史 pending，并注册只做本地快照/恢复的生命周期监听；不会联网且重复调用无副作用。
    public static func start() {
        guard !vDidStart else { return }
        vDidStart = true
        CoverageCollector.shared.start()
        vBackgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            CoverageCollector.shared.captureInBackground()
        }
        vForegroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            CoverageCollector.shared.restoreFromDisk()
        }
    }

    /// 在主 Actor 创建 SDK 自带的原生 UIKit 控制台；宿主只负责将其推入现有导航栈。
    public static func makeConsoleViewController() -> UIViewController {
        CoverageConsoleViewController()
    }

    /// 显式生成一份本地 `.profraw` 快照但不联网，并在主线程回调；失败不会删除或改写既有 pending。
    public static func snapshot(completion: @escaping (Result<SnapshotResult, Error>) -> Void) {
        CoverageCollector.shared.captureManually { result in
            completion(result.map(SnapshotResult.init(report:)))
        }
    }

    /// 使用包内受限 Token 和当前地址覆盖执行唯一手动上传流程：先快照，再串行上传全部 pending，并在主线程回调；失败记录保持可恢复状态。
    public static func uploadPending(completion: @escaping (Result<UploadResult, Error>) -> Void) {
        do {
            let t_metadata = try CoverageBuildMetadata.load()
            let t_store = CoverageServerConfigurationStore()
            let t_serverURLText = t_store.loadServerURLOverride() ?? t_metadata.coverageServerURL.absoluteString
            let t_configuration = try CoverageServerConfiguration.make(
                serverURLText: t_serverURLText,
                runUploadToken: t_metadata.runUploadToken
            )
            CoverageCollector.shared.uploadAllPending(configuration: t_configuration) { result in
                completion(result.map(UploadResult.init(report:)))
            }
        } catch {
            completion(.failure(error))
        }
    }
}
#endif
