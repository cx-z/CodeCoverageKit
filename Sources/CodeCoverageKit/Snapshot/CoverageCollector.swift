#if CODE_COVERAGE_KIT_ENABLED
#if SWIFT_PACKAGE
import CodeCoverageRuntimeBridge
#endif
import Foundation

final class CoverageCollector {
    struct Summary: Sendable {
        let currentCycleID: String?
        let currentBuildID: String?
        let metadataError: String?
        let lastError: String?
        var coalescedCount: Int = 0
        let pendingCount: Int
        let failedCount: Int
        let uploadedCount: Int
        let isUploading: Bool
        let lastSnapshotSize: Int?
        let lastSnapshotDurationMilliseconds: Int?
    }

    struct UploadReport: Sendable {
        let snapshotRunID: String
        let snapshotSize: Int
        let snapshotSHA256: String
        let snapshotDurationMilliseconds: Int
        let uploadedRunIDs: [String]
        let failedRunIDs: [String]
        let stoppedForAuthentication: Bool
        let summary: Summary
    }

    struct SnapshotReport: Sendable {
        let runID: String
        let size: Int
        let sha256: String
        let durationMilliseconds: Int
        let summary: Summary
    }

    enum CollectorError: LocalizedError {
        case unavailable(String)
        case busy
        case snapshotFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let detail):
                return detail
            case .busy:
                return "覆盖率采集或上传正在进行，请等待本轮结束。"
            case .snapshotFailed(let detail):
                return "生成最新覆盖率快照失败：\(detail)"
            }
        }
    }

    static let shared = CoverageCollector()

    private let vQueue = DispatchQueue(label: "CodeCoverageKit.Collector")
    private let vUploadClient: CoverageUploadClient
    private let vLaunchID = UUID().uuidString.lowercased()
    private var vStore: CoverageSnapshotStore?
    private var vMetadata: CoverageBuildMetadata?
    private var vMetadataError: String?
    private var vDidLoadMetadata = false
    private var vDeviceID: String?
    private var vRecords: [String: CoverageSnapshotRecord] = [:]
    private var vCaptureSequence = 0
    private var vValidatedRunIDs = Set<String>()
    private var vActiveRunID: String?
    private var vIsUploading = false
    private var vLastSnapshotSize: Int?
    private var vLastSnapshotDurationMilliseconds: Int?
    private var vLastError: String?

    /// 创建隔离 Collector；注入项用于协议验证，所有运行期访问仍归私有串行队列。
    init(uploadClient: CoverageUploadClient = CoverageUploadClient(),
         store: CoverageSnapshotStore? = nil, metadata: CoverageBuildMetadata? = nil) {
        vUploadClient = uploadClient
        vStore = store
        vMetadata = metadata
        vDidLoadMetadata = metadata != nil
    }

    /// 在启动阶段恢复清单并保存一次当前计数快照，且全程不创建网络请求。
    func start() {
        vQueue.async { [weak self] in
            guard let self else { return }
            do {
                try p_prepareIfNeeded(reloadRecords: true)
                _ = try p_capture(appState: "active", triggerReason: "app_launch")
            } catch {
                vLastError = error.localizedDescription
            }
        }
    }

    /// 响应宿主显式快照请求，在 Collector 队列中落盘但不读取网络配置或上传。
    func captureManually(completion: @escaping (Result<SnapshotReport, Error>) -> Void) {
        vQueue.async { [weak self] in
            guard let self else { return }
            do {
                try p_prepareIfNeeded(reloadRecords: false)
                let t_snapshot = try p_capture(appState: "active", triggerReason: "manual_snapshot")
                let t_report = SnapshotReport(
                    runID: t_snapshot.record.runID,
                    size: t_snapshot.record.size,
                    sha256: t_snapshot.record.sha256,
                    durationMilliseconds: t_snapshot.duration,
                    summary: p_makeSummary()
                )
                p_deliverOnMain(.success(t_report), completion: completion)
            } catch {
                vLastError = error.localizedDescription
                p_deliverOnMain(.failure(error), completion: completion)
            }
        }
    }

    /// 回到前台时重新读取所有 Build 清单以恢复外部中断状态，但绝不触发上传。
    func restoreFromDisk(completion: ((Summary) -> Void)? = nil) {
        vQueue.async { [weak self] in
            guard let self else { return }
            do {
                try p_prepareIfNeeded(reloadRecords: true)
            } catch {
                vLastError = error.localizedDescription
            }
            if let completion {
                p_deliverOnMain(p_makeSummary(), completion: completion)
            }
        }
    }

    /// 进入后台时只生成并持久化快照，不读取服务配置且不执行任何网络操作。
    func captureInBackground(completion: ((Result<Summary, Error>) -> Void)? = nil) {
        vQueue.async { [weak self] in
            guard let self else { return }
            do {
                try p_prepareIfNeeded(reloadRecords: false)
                _ = try p_capture(appState: "background", triggerReason: "app_background")
                if let completion {
                    p_deliverOnMain(.success(p_makeSummary()), completion: completion)
                }
            } catch {
                vLastError = error.localizedDescription
                if let completion {
                    p_deliverOnMain(.failure(error), completion: completion)
                }
            }
        }
    }

    /// 异步返回串行队列上的不可变状态快照，禁止 UI 跨队列读取内部集合。
    func fetchSummary(completion: @escaping (Summary) -> Void) {
        vQueue.async { [weak self] in
            guard let self else { return }
            do {
                try p_prepareIfNeeded(reloadRecords: false)
            } catch {
                vLastError = error.localizedDescription
            }
            p_deliverOnMain(p_makeSummary(), completion: completion)
        }
    }

    /// 用户上传先检查批次所有权，再采集并冻结各启动的待传代表集合。
    func uploadAllPending(
        configuration: CoverageServerConfiguration,
        completion: @escaping (Result<UploadReport, Error>) -> Void
    ) {
        vQueue.async { [weak self] in
            guard let self else { return }
            do {
                guard !vIsUploading else { throw CollectorError.busy }
                try p_prepareIfNeeded(reloadRecords: true)
                let t_snapshot = try p_capture(appState: "active", triggerReason: "user_upload")
                vIsUploading = true
                let t_records = p_makeUploadPlan().records.filter {
                    $0.uploadStatus == .pending || $0.uploadStatus == .failedRetryable
                }.sorted { $0.capturedAt < $1.capturedAt }
                p_uploadNext(
                    records: t_records,
                    index: 0,
                    attempt: 1,
                    configuration: configuration,
                    snapshot: t_snapshot,
                    uploadedRunIDs: [],
                    failedRunIDs: [],
                    completion: completion
                )
            } catch {
                vLastError = error.localizedDescription
                p_deliverOnMain(.failure(error), completion: completion)
            }
        }
    }

    /// 队列内初始化身份并恢复经校验的记录，保留当前在途上传的所有权。
    private func p_prepareIfNeeded(reloadRecords: Bool) throws {
        if vStore == nil {
            vStore = try CoverageSnapshotStore()
        }
        guard let t_store = vStore else {
            throw CollectorError.unavailable("覆盖率快照存储初始化失败。")
        }
        if vDeviceID == nil {
            vDeviceID = try t_store.loadOrCreateDeviceID()
        }
        if !vDidLoadMetadata {
            vDidLoadMetadata = true
            do {
                vMetadata = try CoverageBuildMetadata.load()
            } catch {
                vMetadataError = error.localizedDescription
            }
        }
        if reloadRecords || vRecords.isEmpty {
            vValidatedRunIDs = []
            let t_records = try t_store.loadRecords(preservingUploading: Set([vActiveRunID].compactMap { $0 }))
            vRecords = Dictionary(uniqueKeysWithValues: t_records.map { ($0.runID, $0) })
            vValidatedRunIDs = Set(t_records.map(\.runID))
        }
    }

    /// 串行分配本启动递增序号，先写原始 profile 再提交不可变身份清单。
    private func p_capture(appState: String, triggerReason: String) throws -> (record: CoverageSnapshotRecord, duration: Int) {
        guard let t_store = vStore,
              let t_metadata = vMetadata,
              let t_deviceID = vDeviceID else {
            throw CollectorError.unavailable(vMetadataError ?? "当前包缺少有效 Coverage Build 身份。")
        }
        let t_startedAt = CFAbsoluteTimeGetCurrent()
        do {
            guard vCaptureSequence < Int.max else { throw CollectorError.snapshotFailed("采集序号已耗尽") }
            vCaptureSequence += 1
            let t_profileData = try CodeCoverageRuntimeBridge.snapshotData()
            let t_record = try t_store.createSnapshot(
                profileData: t_profileData,
                metadata: t_metadata,
                deviceID: t_deviceID,
                launchID: vLaunchID,
                appState: appState,
                triggerReason: triggerReason,
                captureSequence: vCaptureSequence
            )
            let t_duration = max(0, Int((CFAbsoluteTimeGetCurrent() - t_startedAt) * 1_000))
            vRecords[t_record.runID] = t_record
            vValidatedRunIDs.insert(t_record.runID)
            vLastSnapshotSize = t_record.size
            vLastSnapshotDurationMilliseconds = t_duration
            vLastError = nil
            return (t_record, t_duration)
        } catch {
            throw CollectorError.snapshotFailed(error.localizedDescription)
        }
    }

    /// 串行上传冻结的代表；本地编码失败保留记录并停止整批，网络错误有限重试。
    private func p_uploadNext(
        records: [CoverageSnapshotRecord],
        index: Int,
        attempt: Int,
        configuration: CoverageServerConfiguration,
        snapshot: (record: CoverageSnapshotRecord, duration: Int),
        uploadedRunIDs: [String],
        failedRunIDs: [String],
        completion: @escaping (Result<UploadReport, Error>) -> Void
    ) {
        guard index < records.count else {
            p_finishUpload(
                snapshot: snapshot,
                uploadedRunIDs: uploadedRunIDs,
                failedRunIDs: failedRunIDs,
                stoppedForAuthentication: false,
                completion: completion
            )
            return
        }
        var t_record = vRecords[records[index].runID] ?? records[index]
        do {
            guard let t_store = vStore else {
                throw CollectorError.unavailable("覆盖率快照存储不可用。")
            }
            try t_store.validateProfile(record: t_record)
            vActiveRunID = t_record.runID
            t_record.uploadStatus = .uploading
            t_record.retryCount += 1
            t_record.lastError = nil
            try p_save(record: t_record)
            let t_profileURL = try t_store.profileURL(record: t_record)
            try vUploadClient.upload(
                record: t_record,
                profileURL: t_profileURL,
                configuration: configuration
            ) { [weak self] result in
                guard let self else { return }
                vQueue.async {
                    self.p_handleUploadResult(
                        result,
                        record: t_record,
                        records: records,
                        index: index,
                        attempt: attempt,
                        configuration: configuration,
                        snapshot: snapshot,
                        uploadedRunIDs: uploadedRunIDs,
                        failedRunIDs: failedRunIDs,
                        completion: completion
                    )
                }
            }
        } catch let t_error as CoverageUploadClient.UploadError {
            p_handleUploadResult(.failure(t_error), record: t_record, records: records, index: index,
                                 attempt: attempt, configuration: configuration, snapshot: snapshot,
                                 uploadedRunIDs: uploadedRunIDs, failedRunIDs: failedRunIDs, completion: completion)
        } catch {
            vActiveRunID = nil
            vValidatedRunIDs.remove(t_record.runID)
            t_record.uploadStatus = .failedPermanent
            t_record.lastError = error.localizedDescription
            try? p_save(record: t_record)
            p_uploadNext(
                records: records,
                index: index + 1,
                attempt: 1,
                configuration: configuration,
                snapshot: snapshot,
                uploadedRunIDs: uploadedRunIDs,
                failedRunIDs: failedRunIDs + [t_record.runID],
                completion: completion
            )
        }
    }

    /// 仅当前在途 Run 的回调可提交状态；编码或鉴权失败停止批次且保留原始文件。
    private func p_handleUploadResult(
        _ result: Result<CoverageUploadClient.AcceptedRun, CoverageUploadClient.UploadError>,
        record: CoverageSnapshotRecord,
        records: [CoverageSnapshotRecord],
        index: Int,
        attempt: Int,
        configuration: CoverageServerConfiguration,
        snapshot: (record: CoverageSnapshotRecord, duration: Int),
        uploadedRunIDs: [String],
        failedRunIDs: [String],
        completion: @escaping (Result<UploadReport, Error>) -> Void
    ) {
        guard vIsUploading, vActiveRunID == record.runID else { return }
        var t_record = record
        switch result {
        case .success(let accepted):
            t_record.uploadStatus = .uploaded
            t_record.lastError = nil
            t_record.serverReceivedAt = accepted.receivedAt
            t_record.analyzable = accepted.analyzable
            do {
                try p_save(record: t_record)
                p_uploadNext(
                    records: records,
                    index: index + 1,
                    attempt: 1,
                    configuration: configuration,
                    snapshot: snapshot,
                    uploadedRunIDs: uploadedRunIDs + [t_record.runID],
                    failedRunIDs: failedRunIDs,
                    completion: completion
                )
            } catch {
                p_finishUploadWithError(error, completion: completion)
            }
        case .failure(let error):
            t_record.lastError = error.localizedDescription
            t_record.uploadStatus = error.isPermanent ? .failedPermanent : .failedRetryable
            do {
                try p_save(record: t_record)
            } catch {
                p_finishUploadWithError(error, completion: completion)
                return
            }
            if error.isRetryableInCurrentOperation && attempt < 3 {
                vQueue.asyncAfter(deadline: .now() + .milliseconds(500 * attempt)) {
                    self.p_uploadNext(
                        records: records,
                        index: index,
                        attempt: attempt + 1,
                        configuration: configuration,
                        snapshot: snapshot,
                        uploadedRunIDs: uploadedRunIDs,
                        failedRunIDs: failedRunIDs,
                        completion: completion
                    )
                }
            } else if error.shouldStopBatch {
                p_finishUpload(
                    snapshot: snapshot,
                    uploadedRunIDs: uploadedRunIDs,
                    failedRunIDs: failedRunIDs + [t_record.runID],
                    stoppedForAuthentication: { if case .authenticationFailed = error { return true }; return false }(),
                    completion: completion
                )
            } else {
                p_uploadNext(
                    records: records,
                    index: index + 1,
                    attempt: 1,
                    configuration: configuration,
                    snapshot: snapshot,
                    uploadedRunIDs: uploadedRunIDs,
                    failedRunIDs: failedRunIDs + [t_record.runID],
                    completion: completion
                )
            }
        }
    }

    /// 更新内存字典与磁盘清单，保证二者在同一 Collector 串行事务边界内提交。
    private func p_save(record: CoverageSnapshotRecord) throws {
        guard let t_store = vStore else {
            throw CollectorError.unavailable("覆盖率快照存储不可用。")
        }
        try t_store.update(record: record)
        vRecords[record.runID] = record
    }

    /// 完成一批用户触发上传，恢复空闲状态并向主线程返回不可变报告。
    private func p_finishUpload(
        snapshot: (record: CoverageSnapshotRecord, duration: Int),
        uploadedRunIDs: [String],
        failedRunIDs: [String],
        stoppedForAuthentication: Bool,
        completion: @escaping (Result<UploadReport, Error>) -> Void
    ) {
        vIsUploading = false
        vActiveRunID = nil
        let t_report = UploadReport(
            snapshotRunID: snapshot.record.runID,
            snapshotSize: snapshot.record.size,
            snapshotSHA256: snapshot.record.sha256,
            snapshotDurationMilliseconds: snapshot.duration,
            uploadedRunIDs: uploadedRunIDs,
            failedRunIDs: failedRunIDs,
            stoppedForAuthentication: stoppedForAuthentication,
            summary: p_makeSummary()
        )
        p_deliverOnMain(.success(t_report), completion: completion)
    }

    /// 在无法继续维护本地状态时结束上传并向 UI 返回错误。
    private func p_finishUploadWithError(
        _ error: Error,
        completion: @escaping (Result<UploadReport, Error>) -> Void
    ) {
        vIsUploading = false
        vActiveRunID = nil
        p_deliverOnMain(.failure(error), completion: completion)
    }

    /// 派生经校验的代表集合，保护本进程正在上传的 Run 不被更新快照隐藏。
    private func p_makeUploadPlan() -> CoverageUploadPlan {
        CoverageUploadPlan(records: Array(vRecords.values), validRunIDs: vValidatedRunIDs,
                           protectedRunIDs: Set([vActiveRunID].compactMap { $0 }))
    }

    /// 按有效代表展示待传/失败数量，只有实际确认的记录计入 uploaded。
    private func p_makeSummary() -> Summary {
        let t_plan = p_makeUploadPlan()
        let t_records = t_plan.records
        let t_pendingCount = t_records.filter {
            $0.uploadStatus == .pending || $0.uploadStatus == .uploading
        }.count
        let t_failedCount = t_records.filter {
            $0.uploadStatus == .failedRetryable || $0.uploadStatus == .failedPermanent
        }.count
        let t_uploadedCount = t_records.filter { $0.uploadStatus == .uploaded }.count
        return Summary(
            currentCycleID: vMetadata?.cycleID,
            currentBuildID: vMetadata?.buildID,
            metadataError: vMetadataError,
            lastError: vLastError ?? t_records.last(where: { $0.lastError != nil })?.lastError,
            coalescedCount: t_plan.suppressedRunIDs.count,
            pendingCount: t_pendingCount,
            failedCount: t_failedCount,
            uploadedCount: t_uploadedCount,
            isUploading: vIsUploading,
            lastSnapshotSize: vLastSnapshotSize,
            lastSnapshotDurationMilliseconds: vLastSnapshotDurationMilliseconds
        )
    }

    /// 将泛型不可变结果切回主线程，统一 UI 回调边界。
    private func p_deliverOnMain<Value>(_ value: Value, completion: @escaping (Value) -> Void) {
        DispatchQueue.main.async {
            completion(value)
        }
    }
}
#endif
