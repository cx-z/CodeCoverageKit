#if CODE_COVERAGE_KIT_ENABLED
import CodeCoverageRuntimeBridge
import Foundation

final class CoverageCollector {
    struct Summary: Sendable {
        let currentCycleID: String?
        let currentBuildID: String?
        let metadataError: String?
        let lastError: String?
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
    private var vIsUploading = false
    private var vLastSnapshotSize: Int?
    private var vLastSnapshotDurationMilliseconds: Int?
    private var vLastError: String?

    /// 创建唯一 Collector；所有可变状态、LLVM runtime 和文件访问均归专用串行队列所有。
    private init(uploadClient: CoverageUploadClient = CoverageUploadClient()) {
        vUploadClient = uploadClient
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

    /// 响应唯一的手动上传动作：先刷新快照，再串行上传所有 Build 的 pending/可重试记录。
    func uploadAllPending(
        configuration: CoverageServerConfiguration,
        completion: @escaping (Result<UploadReport, Error>) -> Void
    ) {
        vQueue.async { [weak self] in
            guard let self else { return }
            do {
                try p_prepareIfNeeded(reloadRecords: true)
                guard !vIsUploading else { throw CollectorError.busy }
                let t_snapshot = try p_capture(appState: "active", triggerReason: "user_upload")
                vIsUploading = true
                let t_records = vRecords.values.filter {
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

    /// 初始化 Store、Build 身份、匿名设备身份和本地记录；调用方必须位于 Collector 队列。
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
            vRecords = Dictionary(uniqueKeysWithValues: try t_store.loadRecords().map { ($0.runID, $0) })
        }
    }

    /// 在串行边界内调用 LLVM buffer API，并先写 profile 再原子提交该 Run 清单。
    private func p_capture(appState: String, triggerReason: String) throws -> (record: CoverageSnapshotRecord, duration: Int) {
        guard let t_store = vStore,
              let t_metadata = vMetadata,
              let t_deviceID = vDeviceID else {
            throw CollectorError.unavailable(vMetadataError ?? "当前包缺少有效 Coverage Build 身份。")
        }
        let t_startedAt = CFAbsoluteTimeGetCurrent()
        do {
            let t_profileData = try CodeCoverageRuntimeBridge.snapshotData()
            let t_record = try t_store.createSnapshot(
                profileData: t_profileData,
                metadata: t_metadata,
                deviceID: t_deviceID,
                launchID: vLaunchID,
                appState: appState,
                triggerReason: triggerReason
            )
            let t_duration = max(0, Int((CFAbsoluteTimeGetCurrent() - t_startedAt) * 1_000))
            vRecords[t_record.runID] = t_record
            vLastSnapshotSize = t_record.size
            vLastSnapshotDurationMilliseconds = t_duration
            vLastError = nil
            return (t_record, t_duration)
        } catch {
            throw CollectorError.snapshotFailed(error.localizedDescription)
        }
    }

    /// 串行推进上传队列；单个 Run 只在本次用户操作中最多尝试三次网络/5xx 重试。
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
        } catch {
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

    /// 应用严格响应结果，决定成功、当前操作内重试、永久失败或鉴权停止整批。
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
                    stoppedForAuthentication: true,
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
        p_deliverOnMain(.failure(error), completion: completion)
    }

    /// 从队列内状态生成计数和当前 Build 的不可变展示模型。
    private func p_makeSummary() -> Summary {
        let t_records = vRecords.values.sorted { $0.capturedAt < $1.capturedAt }
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
