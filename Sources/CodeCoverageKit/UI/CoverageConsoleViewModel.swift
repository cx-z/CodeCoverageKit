#if CODE_COVERAGE_KIT_ENABLED && canImport(UIKit)
import Foundation

@MainActor
final class CoverageConsoleViewModel {
    enum ServerURLSource: String {
        case bundleDefault = "包内默认地址"
        case userOverride = "用户覆盖地址"
    }

    struct ViewState {
        enum Kind {
            case idle
            case working
            case success
            case failure
        }

        let kind: Kind
        let title: String
        let detail: String
        let isBusy: Bool
    }

    private enum Operation {
        case health
        case uploadProbe
    }

    private enum ConfigurationError: LocalizedError {
        case metadataUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .metadataUnavailable(let detail):
                return detail
            }
        }
    }

    private let vStore: CoverageServerConfigurationStore
    private let vClient: CoverageProbeClient
    private let vCollector: CoverageCollector
    private let vMetadata: CoverageBuildMetadata?
    private let vMetadataErrorText: String?
    private let vDefaultServerURLText: String
    private var vCurrentTask: Task<Void, Never>?
    private var vRequestID = UUID()
    private var vCoverageUploadInProgress = false
    private var vHasUserOverride: Bool

    private(set) var serverURLText: String
    private(set) var serverURLSource: ServerURLSource
    private(set) var coverageSummaryText = "正在读取本地 Coverage 状态…"
    private(set) var canUploadCoverage = false
    private(set) var state = ViewState(
        kind: .idle,
        title: "等待验证",
        detail: "可直接使用包内默认地址；GET /health 不鉴权，测试文件和覆盖数据上传使用当前测试包提供的受限凭证。",
        isBusy: false
    )

    var onStateChange: ((ViewState) -> Void)?
    var onCoverageSummaryChange: ((String, Bool) -> Void)?
    var onServerConfigurationChange: ((String, ServerURLSource) -> Void)?

    /// 载入包内 Coverage 配置和可选用户地址覆盖，并建立由主 Actor 管理的请求状态所有者。
    init(
        store: CoverageServerConfigurationStore? = nil,
        client: CoverageProbeClient = CoverageProbeClient(),
        collector: CoverageCollector = .shared,
        metadataLoader: () throws -> CoverageBuildMetadata = { try CoverageBuildMetadata.load() }
    ) {
        let t_store = store ?? CoverageServerConfigurationStore()
        vStore = t_store
        vClient = client
        vCollector = collector
        let t_metadata: CoverageBuildMetadata?
        let t_metadataErrorText: String?
        do {
            t_metadata = try metadataLoader()
            t_metadataErrorText = nil
        } catch {
            t_metadata = nil
            t_metadataErrorText = error.localizedDescription
        }
        vMetadata = t_metadata
        vMetadataErrorText = t_metadataErrorText
        vDefaultServerURLText = t_metadata?.coverageServerURL.absoluteString ?? ""
        let t_override = t_store.loadServerURLOverride()
        vHasUserOverride = t_override != nil
        serverURLText = t_override ?? vDefaultServerURLText
        serverURLSource = t_override == nil ? .bundleDefault : .userOverride
    }

    /// 页面释放时取消尚未完成的请求，阻止过期回调继续提交状态。
    deinit {
        vCurrentTask?.cancel()
    }

    /// 接收 UI 当前地址输入；该状态只在主 Actor 上更新，不触碰包内凭证或立即持久化。
    func updateInput(serverURLText: String) {
        self.serverURLText = serverURLText
    }

    /// 校验并显式保存用户服务地址覆盖值，不复制或持久化包内受限凭证。
    func saveConfiguration() {
        do {
            let t_configuration = try p_validatedConfiguration()
            vStore.saveServerURLOverride(t_configuration.serverURL)
            vHasUserOverride = true
            serverURLText = t_configuration.serverURL.absoluteString
            serverURLSource = .userOverride
            p_notifyServerConfigurationChange()
            p_setState(
                ViewState(
                    kind: .success,
                    title: "地址已保存",
                    detail: "Server URL：\(t_configuration.serverURL.absoluteString)\n受限上传凭证继续使用当前测试包内配置。",
                    isBusy: false
                )
            )
        } catch {
            p_setConfigurationError(error)
        }
    }

    /// 删除用户地址覆盖并立即恢复当前安装包默认地址，不修改 pending、快照或覆盖计数。
    func restoreBundleDefaultServerURL() {
        guard let t_metadata = vMetadata else {
            p_setConfigurationError(ConfigurationError.metadataUnavailable(vMetadataErrorText ?? "当前包缺少 Coverage Build 元数据。"))
            return
        }
        vStore.removeServerURLOverride()
        vHasUserOverride = false
        serverURLText = t_metadata.coverageServerURL.absoluteString
        serverURLSource = .bundleDefault
        p_notifyServerConfigurationChange()
        p_setState(
            ViewState(
                kind: .success,
                title: "已恢复包内默认地址",
                detail: "Server URL：\(serverURLText)\n本地 pending 和覆盖计数未改变。",
                isBusy: false
            )
        )
    }

    /// 使用当前地址主动执行无鉴权 `/health` 请求，并仅在必要时保存用户覆盖地址。
    func checkHealth() {
        do {
            let t_configuration = try p_validatedConfiguration()
            p_persistImplicitServerURLOverrideIfNeeded(t_configuration.serverURL)
            p_start(operation: .health, configuration: t_configuration)
        } catch {
            p_setConfigurationError(error)
        }
    }

    /// 使用包内凭证上传无业务数据测试文件，并仅在必要时保存用户覆盖地址。
    func uploadTestProbe() {
        do {
            let t_configuration = try p_validatedConfiguration()
            p_persistImplicitServerURLOverrideIfNeeded(t_configuration.serverURL)
            p_start(operation: .uploadProbe, configuration: t_configuration)
        } catch {
            p_setConfigurationError(error)
        }
    }

    /// 请求 Collector 返回不可变状态快照，并仅在主 Actor 上更新 Cycle/Build 与计数展示。
    func refreshCoverageSummary() {
        vCollector.fetchSummary { [weak self] summary in
            guard let self else { return }
            p_applyCoverageSummary(summary)
        }
    }

    /// 使用包内凭证触发唯一手动流程：先快照，再串行上传全部历史 pending。
    func uploadCoverageData() {
        do {
            let t_configuration = try p_validatedConfiguration()
            guard !vCoverageUploadInProgress else { return }
            p_persistImplicitServerURLOverrideIfNeeded(t_configuration.serverURL)
            vCoverageUploadInProgress = true
            p_setState(
                ViewState(
                    kind: .working,
                    title: "正在刷新并上传覆盖数据",
                    detail: "先在本地生成最新 .profraw，再串行上传全部 pending；离开页面不会转为自动后台上传。",
                    isBusy: true
                )
            )
            vCollector.uploadAllPending(configuration: t_configuration) { [weak self] result in
                guard let self else { return }
                vCoverageUploadInProgress = false
                switch result {
                case .success(let report):
                    p_applyCoverageSummary(report.summary)
                    let t_kind: ViewState.Kind = report.stoppedForAuthentication || !report.failedRunIDs.isEmpty ? .failure : .success
                    let t_title = report.stoppedForAuthentication ? "鉴权失败，已停止本轮" : (report.failedRunIDs.isEmpty ? "覆盖数据上传完成" : "部分覆盖数据上传失败")
                    p_setState(
                        ViewState(
                            kind: t_kind,
                            title: t_title,
                            detail: "最新 Run：\(report.snapshotRunID)\n大小：\(report.snapshotSize) 字节\nSHA-256：\(report.snapshotSHA256)\n快照耗时：\(report.snapshotDurationMilliseconds) ms\n本轮上传：\(report.uploadedRunIDs.count)\n本轮失败：\(report.failedRunIDs.count)",
                            isBusy: false
                        )
                    )
                case .failure(let error):
                    refreshCoverageSummary()
                    p_setState(
                        ViewState(
                            kind: .failure,
                            title: "覆盖数据上传失败",
                            detail: error.localizedDescription,
                            isBusy: false
                        )
                    )
                }
            }
        } catch {
            p_setConfigurationError(error)
        }
    }

    /// 取消当前请求并恢复可操作状态，供页面退出或后续扩展显式取消使用。
    func cancelCurrentRequest() {
        vCurrentTask?.cancel()
        vCurrentTask = nil
        vRequestID = UUID()
        guard !vCoverageUploadInProgress else { return }
        p_setState(
            ViewState(
                kind: .idle,
                title: "请求已取消",
                detail: "可以修改配置后重新验证。",
                isBusy: false
            )
        )
    }

    /// 组合当前地址与 Bundle 内受限凭证，生成一次请求使用的不可变配置快照。
    private func p_validatedConfiguration() throws -> CoverageServerConfiguration {
        guard let t_metadata = vMetadata else {
            throw ConfigurationError.metadataUnavailable(vMetadataErrorText ?? "当前包缺少 Coverage Build 元数据。")
        }
        return try CoverageServerConfiguration.make(
            serverURLText: serverURLText,
            runUploadToken: t_metadata.runUploadToken
        )
    }

    /// 保持包内默认地址为动态默认值，仅在当前地址确属用户覆盖时写入 UserDefaults。
    private func p_persistImplicitServerURLOverrideIfNeeded(_ serverURL: URL) {
        let t_isBundleDefault = serverURL.absoluteString == vDefaultServerURLText
        guard vHasUserOverride || !t_isBundleDefault else { return }
        vStore.saveServerURLOverride(serverURL)
        vHasUserOverride = true
        serverURLText = serverURL.absoluteString
        serverURLSource = .userOverride
        p_notifyServerConfigurationChange()
    }

    /// 向页面提交完整的地址与来源快照，确保 UI 不直接读取持久化状态。
    private func p_notifyServerConfigurationChange() {
        onServerConfigurationChange?(serverURLText, serverURLSource)
    }

    /// 取消旧任务并以新请求 ID 启动操作，防止旧响应覆盖较新的用户操作。
    private func p_start(operation: Operation, configuration: CoverageServerConfiguration) {
        vCurrentTask?.cancel()
        let t_requestID = UUID()
        vRequestID = t_requestID
        let t_workingTitle = operation == .health ? "正在检查连接" : "正在上传测试文件"
        p_setState(
            ViewState(
                kind: .working,
                title: t_workingTitle,
                detail: "首次访问局域网时请观察系统是否弹出本地网络授权；若弹出，请按测试要求作出选择。",
                isBusy: true
            )
        )
        vCurrentTask = Task { [weak self] in
            guard let self else { return }
            do {
                switch operation {
                case .health:
                    let t_result = try await vClient.checkHealth(configuration: configuration)
                    guard !Task.isCancelled, vRequestID == t_requestID else { return }
                    p_finishHealth(result: t_result)
                case .uploadProbe:
                    let t_result = try await vClient.uploadTestProbe(configuration: configuration)
                    guard !Task.isCancelled, vRequestID == t_requestID else { return }
                    p_finishUpload(result: t_result)
                }
            } catch {
                guard !Task.isCancelled, vRequestID == t_requestID else { return }
                p_finish(error: error)
            }
        }
    }

    /// 将 health 成功结果转换为服务实例和耗时信息，并结束当前请求。
    private func p_finishHealth(result: CoverageProbeClient.HealthResult) {
        vCurrentTask = nil
        p_setState(
            ViewState(
                kind: .success,
                title: "连接成功",
                detail: "服务版本：\(result.serverVersion)\n实例 ID：\(result.instanceID)\n服务时间：\(result.serverTime)\n耗时：\(result.elapsedMilliseconds) ms\n注意：/health 不验证 Token。",
                isBusy: false
            )
        )
    }

    /// 将上传成功结果转换为 probe ID、大小和 SHA-256 校验证据，并结束当前请求。
    private func p_finishUpload(result: CoverageProbeClient.UploadResult) {
        vCurrentTask = nil
        p_setState(
            ViewState(
                kind: .success,
                title: "测试文件上传成功",
                detail: "Probe ID：\(result.probeID)\n大小：\(result.size) 字节\nSHA-256：\(result.sha256)\n服务端接收时间：\(result.receivedAt)\n耗时：\(result.elapsedMilliseconds) ms",
                isBusy: false
            )
        )
    }

    /// 将配置错误转换为独立的用户可定位状态，不发起任何网络请求。
    private func p_setConfigurationError(_ error: Error) {
        p_setState(
            ViewState(
                kind: .failure,
                title: "配置错误",
                detail: error.localizedDescription,
                isBusy: false
            )
        )
    }

    /// 将客户端分类错误或未知错误转换为页面失败状态，并结束当前请求。
    private func p_finish(error: Error) {
        vCurrentTask = nil
        if let t_clientError = error as? CoverageProbeClient.ClientError {
            p_setState(
                ViewState(
                    kind: .failure,
                    title: t_clientError.categoryTitle,
                    detail: t_clientError.localizedDescription,
                    isBusy: false
                )
            )
        } else {
            p_setState(
                ViewState(
                    kind: .failure,
                    title: "未知错误",
                    detail: error.localizedDescription,
                    isBusy: false
                )
            )
        }
    }

    /// 将 Collector 摘要转换为页面文本，并根据有效 Build 身份和上传状态决定按钮可用性。
    private func p_applyCoverageSummary(_ summary: CoverageCollector.Summary) {
        let t_cycle = summary.currentCycleID ?? "无"
        let t_build = summary.currentBuildID ?? "无"
        var t_lines = [
            "Cycle：\(t_cycle)",
            "Build：\(t_build)",
            "pending：\(summary.pendingCount)  failed：\(summary.failedCount)  uploaded：\(summary.uploadedCount)"
        ]
        if let t_size = summary.lastSnapshotSize,
           let t_duration = summary.lastSnapshotDurationMilliseconds {
            t_lines.append("最近快照：\(t_size) 字节，\(t_duration) ms")
        }
        if let t_error = summary.metadataError {
            t_lines.append("Build 元数据：\(t_error)")
        }
        if let t_error = summary.lastError {
            t_lines.append("最近错误：\(t_error)")
        }
        coverageSummaryText = t_lines.joined(separator: "\n")
        canUploadCoverage = summary.currentCycleID != nil && summary.currentBuildID != nil && !summary.isUploading && !vCoverageUploadInProgress
        onCoverageSummaryChange?(coverageSummaryText, canUploadCoverage)
    }

    /// 在主 Actor 上提交完整 ViewState 快照并同步通知页面刷新。
    private func p_setState(_ newState: ViewState) {
        state = newState
        onStateChange?(newState)
    }
}
#endif
