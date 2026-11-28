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
        var deliveredSourceCount: Int = 0
        var isPreparing: Bool = false
        var mergeEnabled: Bool = false
        var mergeAvailable: Bool = false
        var mergeDetail: String? = nil
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
        let snapshotUpload: CoverageUploadClient.AcceptedRun?
        var mergedSourceCount: Int = 0
        var mergeStatistics: [CoverageMergeStatistics] = []
        var fallbackReasons: [String] = []
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
    private let vPreparationQueue = DispatchQueue(label: "CodeCoverageKit.Preparation", qos: .utility)
    private var vBatch: CoverageUploadBatch?
    private var vMergeEnabled = false
    private var vMergeLimits: CoverageMergeLimits?
    private var vMergeEngine: CoverageMergePreparation.Engine?
    private var vDeliveredSourceIDs = Set<String>()
    private var vRejectedAggregates: [CoverageAggregateRecord] = []
    private var vLastMergeDetail: String?
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
    private var vSnapshotUpload: CoverageUploadClient.AcceptedRun?
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

    /// Freezes the current representatives and optional measured merge configuration; later captures wait for another action.
    func uploadAllPending(configuration: CoverageServerConfiguration,
                          progress: ((Summary) -> Void)? = nil,
                          completion: @escaping (Result<UploadReport, Error>) -> Void) {
        vQueue.async { [weak self] in
            guard let self else { return }
            do {
                guard !vIsUploading else { throw CollectorError.busy }
                try p_prepareIfNeeded(reloadRecords: true)
                let t_snapshot = try p_capture(appState: "active", triggerReason: "user_upload")
                let t_records = p_makeUploadPlan().records.filter {
                    ($0.uploadStatus == .pending || $0.uploadStatus == .failedRetryable)
                }
                let t_limits = vMergeEnabled ? vMergeLimits : nil
                let t_engine = vMergeEnabled ? vMergeEngine : nil
                let t_batch = CoverageUploadBatch(records: t_records, snapshot: t_snapshot, configuration: configuration,
                    limits: t_limits, engine: t_engine, progress: progress, completion: completion)
                if vMergeEnabled && (t_limits == nil || t_engine == nil) {
                    t_batch.fallbackReasons.append("未安装已验收合并组件和实测预算，使用逐份 gzip。")
                }
                vBatch = t_batch; vIsUploading = true; vSnapshotUpload = nil
                vLastMergeDetail = nil; vLastError = nil
                p_processGroup(t_batch)
            } catch {
                vLastError = error.localizedDescription
                p_deliverOnMain(.failure(error), completion: completion)
            }
        }
    }

    /// Registers only the optional engine; invalid budgets remain disabled, and an active batch retains its frozen configuration.
    func installMergeEngine(limits: CoverageMergeLimits, engine: @escaping CoverageMergePreparation.Engine) {
        vQueue.async {
            guard limits.isValid else { self.vLastError = "合并资源预算无效，继续逐份 gzip。"; return }
            self.vMergeLimits = limits; self.vMergeEngine = engine
        }
    }

    /// Changes the local flag for the next explicit action; active fixed uploads and existing receipts retain their meaning.
    func setCrossLaunchMergeEnabled(_ enabled: Bool) {
        vQueue.async {
            self.vMergeEnabled = enabled && self.vMergeEngine != nil && self.vMergeLimits != nil
            if enabled && !self.vMergeEnabled { self.vLastMergeDetail = "未安装已验收合并组件和实测预算，继续逐份 gzip。" }
        }
    }

    /// Prepares immutable candidates off-queue; skips historically rejected groups without blocking later frozen groups or publishing stale results.
    private func p_processGroup(_ batch: CoverageUploadBatch) {
        guard vBatch === batch else { return }
        guard batch.groupIndex < batch.groups.count else {
            p_finishUpload(snapshot: batch.snapshot, uploadedRunIDs: batch.uploadedRunIDs,
                failedRunIDs: batch.failedRunIDs, stoppedForAuthentication: false, completion: batch.completion)
            return
        }
        let t_records = batch.groups[batch.groupIndex]
        do {
            guard let t_store = vStore else { throw CollectorError.unavailable("快照存储不可用。") }
            let t_urls = try t_records.map { try t_store.profileURL(record: $0) }
            guard let t_limits = batch.limits, let t_engine = batch.engine,
                  t_records.count >= 2, Set(t_records.map(\.launchID)).count >= 2 else {
                p_sendItems(t_records.enumerated().map { .raw($0.element, t_urls[$0.offset]) }, index: 0, batch: batch)
                return
            }
            batch.isPreparing = true
            let t_started = DispatchTime.now().uptimeNanoseconds
            batch.preparationStartedNanoseconds = t_started
            p_publishProgress(batch)
            let t_root = t_store.rootURL, t_launch = vLaunchID, t_client = vUploadClient, t_configuration = batch.configuration
            vPreparationQueue.async {
                let t_outcome = CoverageMergePreparation.prepare(records: t_records, urls: t_urls, rootURL: t_root,
                    launchID: t_launch, limits: t_limits, engine: t_engine, client: t_client, configuration: t_configuration, startedNanoseconds: t_started)
                self.vQueue.async {
                    guard self.vBatch === batch else { return }
                    batch.isPreparing = false
                    switch t_outcome {
                    case .invalidSource(let t_error): self.p_finishUploadWithError(t_error, completion: batch.completion)
                    case .fallback(let t_reason):
                        batch.fallbackReasons.append(t_reason)
                        self.p_sendItems(t_records.enumerated().map { .raw($0.element, t_urls[$0.offset]) }, index: 0, batch: batch)
                    case .merged(let t_candidate):
                        do {
                            guard let t_store = self.vStore else { throw CollectorError.unavailable("快照存储不可用。") }
                            if let t_rejected = self.vRejectedAggregates.first(where: { $0.hasSameMergeContent(as: t_candidate.aggregate) }) {
                                self.vLastError = t_rejected.permanentError
                                batch.failedRunIDs.append(t_rejected.runID)
                                batch.groupIndex += 1
                                self.p_processGroup(batch)
                                return
                            }
                            let t_url = try t_store.saveAggregate(t_candidate.aggregate, payload: t_candidate.payload)
                            self.p_sendItems([.aggregate(t_candidate.aggregate, t_url, t_candidate.prepared, t_candidate.statistics)], index: 0, batch: batch)
                        } catch {
                            batch.fallbackReasons.append("合并对象无法完成本地提交，尝试逐份 gzip。")
                            self.p_sendItems(t_records.enumerated().map { .raw($0.element, t_urls[$0.offset]) }, index: 0, batch: batch)
                        }
                    }
                }
            }
        } catch { p_finishUploadWithError(error, completion: batch.completion) }
    }

    /// Prepares one raw request off-queue or uses an already committed aggregate, keeping only the active encoded body alive.
    private func p_sendItems(_ items: [CoverageUploadItem], index: Int, batch: CoverageUploadBatch) {
        guard vBatch === batch else { return }
        guard index < items.count else { batch.groupIndex += 1; p_processGroup(batch); return }
        let t_item = items[index]
        do {
            let t_descriptor = try t_item.descriptor()
            vActiveRunID = t_descriptor.runID
            switch t_item {
            case .aggregate(_, _, let t_prepared, _):
                p_sendFixed(t_prepared, descriptor: t_descriptor, item: t_item, items: items, index: index, attempt: 1, batch: batch)
            case .raw(let t_record, let t_url):
                try vStore?.validateProfile(record: t_record)
                let t_client = vUploadClient, t_configuration = batch.configuration
                vPreparationQueue.async {
                    let t_result = Result { try t_client.prepareUpload(record: t_record, profileURL: t_url, configuration: t_configuration) }
                    self.vQueue.async {
                        guard self.vBatch === batch, self.vActiveRunID == t_descriptor.runID else { return }
                        switch t_result {
                        case .success(let t_prepared):
                            self.p_sendFixed(t_prepared, descriptor: t_descriptor, item: t_item, items: items, index: index, attempt: 1, batch: batch)
                        case .failure(let t_error as CoverageUploadClient.UploadError):
                            self.p_handleFixedResult(.failure(t_error), prepared: nil, descriptor: t_descriptor, item: t_item,
                                items: items, index: index, attempt: 1, batch: batch)
                        case .failure(let t_error): self.p_finishUploadWithError(t_error, completion: batch.completion)
                        }
                    }
                }
            }
        } catch { p_finishUploadWithError(error, completion: batch.completion) }
    }

    /// Retries only the identical prepared object; source changes and lifecycle captures cannot affect this request.
    private func p_sendFixed(_ prepared: CoverageUploadClient.PreparedUpload, descriptor: CoverageUploadDescriptor,
                             item: CoverageUploadItem, items: [CoverageUploadItem], index: Int, attempt: Int, batch: CoverageUploadBatch) {
        guard vBatch === batch, vActiveRunID == descriptor.runID else { return }
        do {
            switch item {
            case .raw(let t_original, _):
                var t_record = vRecords[t_original.runID] ?? t_original
                t_record.uploadStatus = .uploading; t_record.retryCount += 1; t_record.lastError = nil
                try p_save(record: t_record)
            case .aggregate(let t_original, _, _, let t_statistics):
                guard let t_store = vStore else { throw CollectorError.unavailable("快照存储不可用。") }
                var t_record = try t_store.loadAggregate(t_original)
                t_record.attemptCount += 1; t_record.lastError = nil
                try t_store.saveAggregateState(t_record)
                if attempt == 1 {
                    guard let t_started = batch.preparationStartedNanoseconds, let t_limits = batch.limits,
                          let t_final = t_statistics.finalized(startedNanoseconds: t_started),
                          t_final.preparationMilliseconds <= t_limits.timeoutMilliseconds,
                          t_final.processPeakResidentBytes <= t_limits.maxProcessResidentBytes else {
                        p_fallbackToRaw(batch, reason: "计入对象耐久提交后的准备时间或资源成本超出预算，使用逐份 gzip。")
                        return
                    }
                    batch.statistics.append(t_final)
                }
            }
            p_publishProgress(batch)
            vUploadClient.send(prepared: prepared, descriptor: descriptor) { [weak self] t_result in
                guard let self else { return }
                self.vQueue.async {
                    self.p_handleFixedResult(t_result, prepared: prepared, descriptor: descriptor, item: item,
                        items: items, index: index, attempt: attempt, batch: batch)
                }
            }
        } catch {
            if case .aggregate = item, attempt == 1 {
                p_fallbackToRaw(batch, reason: "合并对象发送前状态无法提交，尝试逐份 gzip。")
            } else { p_finishUploadWithError(error, completion: batch.completion) }
        }
    }

    /// Falls back only before an aggregate's first send, preserving the frozen original group and all unconfirmed artifacts.
    private func p_fallbackToRaw(_ batch: CoverageUploadBatch, reason: String) {
        guard vBatch === batch else { return }
        do {
            guard let t_store = vStore else { throw CollectorError.unavailable("快照存储不可用。") }
            batch.fallbackReasons.append(reason)
            let t_raw = try batch.groups[batch.groupIndex].map { CoverageUploadItem.raw($0, try t_store.profileURL(record: $0)) }
            p_sendItems(t_raw, index: 0, batch: batch)
        } catch { p_finishUploadWithError(error, completion: batch.completion) }
    }

    /// Commits an original's success or an independent receipt before reporting delivery; failures never relabel raw sources.
    private func p_handleFixedResult(_ result: Result<CoverageUploadClient.AcceptedRun, CoverageUploadClient.UploadError>,
                                     prepared: CoverageUploadClient.PreparedUpload?, descriptor: CoverageUploadDescriptor,
                                     item: CoverageUploadItem, items: [CoverageUploadItem], index: Int, attempt: Int, batch: CoverageUploadBatch) {
        guard vBatch === batch, vActiveRunID == descriptor.runID else { return }
        do {
            switch result {
            case .success(let t_accepted):
                switch item {
                case .raw(let t_original, _):
                    var t_record = vRecords[t_original.runID] ?? t_original
                    t_record.uploadStatus = .uploaded; t_record.lastError = nil
                    t_record.serverReceivedAt = t_accepted.receivedAt; t_record.analyzable = t_accepted.analyzable
                    try p_save(record: t_record)
                    if t_record.runID == batch.snapshot.record.runID { vSnapshotUpload = t_accepted }
                case .aggregate(let t_aggregate, _, _, _):
                    guard let t_store = vStore else { throw CollectorError.unavailable("快照存储不可用。") }
                    let t_current = try t_store.loadAggregate(t_aggregate)
                    try t_store.saveReceipt(CoverageAggregateReceipt(aggregate: t_current, accepted: t_accepted))
                    vDeliveredSourceIDs.formUnion(t_aggregate.sources.map(\.runID))
                    batch.deliveredSources += t_aggregate.sources.count
                }
                batch.uploadedRunIDs.append(descriptor.runID)
                p_sendItems(items, index: index + 1, batch: batch)
            case .failure(let t_error):
                vLastError = t_error.localizedDescription
                switch item {
                case .raw(let t_original, _):
                    var t_record = vRecords[t_original.runID] ?? t_original
                    t_record.uploadStatus = t_error.isPermanent ? .failedPermanent : .failedRetryable
                    t_record.lastError = t_error.localizedDescription
                    try p_save(record: t_record)
                case .aggregate(let t_original, _, _, _):
                    guard let t_store = vStore else { throw CollectorError.unavailable("快照存储不可用。") }
                    var t_aggregate = try t_store.loadAggregate(t_original)
                    t_aggregate.lastError = t_error.localizedDescription
                    if t_error.isPermanent { t_aggregate.permanentError = t_error.localizedDescription }
                    try t_store.saveAggregateState(t_aggregate)
                    if t_error.isPermanent { vRejectedAggregates.append(t_aggregate) }
                }
                if t_error.isRetryableInCurrentOperation, attempt < 3, let prepared {
                    vQueue.asyncAfter(deadline: .now() + .milliseconds(500 * attempt)) {
                        self.p_sendFixed(prepared, descriptor: descriptor, item: item, items: items, index: index, attempt: attempt + 1, batch: batch)
                    }
                } else {
                    batch.failedRunIDs.append(descriptor.runID)
                    if t_error.shouldStopBatch || (descriptor.profileFormat == "indexed" && t_error.isPermanent) {
                        p_finishUpload(snapshot: batch.snapshot, uploadedRunIDs: batch.uploadedRunIDs, failedRunIDs: batch.failedRunIDs,
                            stoppedForAuthentication: { if case .authenticationFailed = t_error { return true }; return false }(), completion: batch.completion)
                    } else { p_sendItems(items, index: index + 1, batch: batch) }
                }
            }
        } catch { p_finishUploadWithError(error, completion: batch.completion) }
    }

    /// Delivers progress summaries on main without giving the UI worker, filesystem or batch ownership.
    private func p_publishProgress(_ batch: CoverageUploadBatch) {
        if let t_progress = batch.progress { p_deliverOnMain(p_makeSummary(), completion: t_progress) }
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
            vDeliveredSourceIDs = t_store.deliveredSourceIDs(records: t_records)
            vRejectedAggregates = t_store.rejectedAggregates(records: t_records)
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

    /// 更新内存字典与磁盘清单，保证二者在同一 Collector 串行事务边界内提交。
    private func p_save(record: CoverageSnapshotRecord) throws {
        guard let t_store = vStore else {
            throw CollectorError.unavailable("覆盖率快照存储不可用。")
        }
        try t_store.update(record: record)
        vRecords[record.runID] = record
    }

    /// 完成冻结批次，区分实际上传对象与合并送达来源，并回传各自正确的请求体统计。
    private func p_finishUpload(
        snapshot: (record: CoverageSnapshotRecord, duration: Int),
        uploadedRunIDs: [String],
        failedRunIDs: [String],
        stoppedForAuthentication: Bool,
        completion: @escaping (Result<UploadReport, Error>) -> Void
    ) {
        vIsUploading = false
        vActiveRunID = nil
        vLastMergeDetail = ((vBatch?.statistics ?? []).map(\.description) + (vBatch?.fallbackReasons ?? [])).joined(separator: "\n")
        let t_report = UploadReport(
            snapshotRunID: snapshot.record.runID,
            snapshotSize: snapshot.record.size,
            snapshotSHA256: snapshot.record.sha256,
            snapshotDurationMilliseconds: snapshot.duration,
            snapshotUpload: vSnapshotUpload,
            mergedSourceCount: vBatch?.deliveredSources ?? 0,
            mergeStatistics: vBatch?.statistics ?? [],
            fallbackReasons: vBatch?.fallbackReasons ?? [],
            uploadedRunIDs: uploadedRunIDs,
            failedRunIDs: failedRunIDs,
            stoppedForAuthentication: stoppedForAuthentication,
            summary: p_makeSummary()
        )
        vBatch = nil
        vSnapshotUpload = nil
        p_deliverOnMain(.success(t_report), completion: completion)
    }

    /// 本地状态无法维护时结束批次并清空临时上传统计，向 UI 返回错误。
    private func p_finishUploadWithError(
        _ error: Error,
        completion: @escaping (Result<UploadReport, Error>) -> Void
    ) {
        vIsUploading = false
        vActiveRunID = nil
        vSnapshotUpload = nil
        vBatch = nil
        vLastError = error.localizedDescription
        p_deliverOnMain(.failure(error), completion: completion)
    }

    /// 派生经校验的代表集合，保护本进程正在上传的 Run 不被更新快照隐藏。
    private func p_makeUploadPlan() -> CoverageUploadPlan {
        CoverageUploadPlan(records: Array(vRecords.values), validRunIDs: vValidatedRunIDs,
                           protectedRunIDs: Set([vActiveRunID].compactMap { $0 }), deliveredRunIDs: vDeliveredSourceIDs)
    }

    /// 按有效代表展示待传/失败数量，只有实际确认的记录计入 uploaded。
    private func p_makeSummary() -> Summary {
        let t_plan = p_makeUploadPlan()
        let t_records = t_plan.records
        let t_pendingCount = t_records.filter {
            ($0.uploadStatus == .pending || $0.uploadStatus == .uploading)
        }.count
        let t_failedCount = t_records.filter {
            $0.uploadStatus == .failedRetryable || $0.uploadStatus == .failedPermanent
        }.count
        let t_uploadedCount = t_records.filter { $0.uploadStatus == .uploaded }.count
        let t_hasRejection = vRejectedAggregates.contains { t_object in
            t_object.sources.contains { !vDeliveredSourceIDs.contains($0.runID) && vRecords[$0.runID]?.uploadStatus != .uploaded }
        }
        return Summary(
            currentCycleID: vMetadata?.cycleID,
            currentBuildID: vMetadata?.buildID,
            metadataError: vMetadataError,
            lastError: vLastError ?? t_records.last(where: { $0.lastError != nil })?.lastError,
            coalescedCount: t_plan.suppressedRunIDs.count,
            deliveredSourceCount: vDeliveredSourceIDs.count,
            isPreparing: vBatch?.isPreparing ?? false,
            mergeEnabled: vMergeEnabled,
            mergeAvailable: vMergeEngine != nil && vMergeLimits != nil,
            mergeDetail: (vIsUploading ? vBatch?.fallbackReasons.last : vLastMergeDetail) ?? (!t_hasRejection ? nil : "存在永久拒绝的合并组合；新增来源或内容后可重组，原始来源仍保留。"),
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
