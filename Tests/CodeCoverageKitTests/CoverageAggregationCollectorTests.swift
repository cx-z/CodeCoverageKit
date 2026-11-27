import Foundation
import XCTest
@_spi(OfflineMerge) @testable import CodeCoverageKit

final class CoverageAggregationCollectorTests: XCTestCase {
    private final class Capture {
        private let lock = NSLock()
        private var encoded = 0
        private var attempts: [(String, Int)] = []
        /// Serializes compression observations across worker and URLProtocol callbacks.
        func encode(_ data: Data) throws -> Data {
            lock.lock(); encoded += 1; lock.unlock()
            return try CoverageGzip.encode(data)
        }
        /// Records the fixed request identity and number of encodes performed before that attempt.
        func request(_ request: URLRequest) -> String {
            let id = request.value(forHTTPHeaderField: "Content-Type")!.components(separatedBy: "boundary=code-coverage-kit-run-").last!
            lock.lock(); attempts.append((id, encoded)); lock.unlock()
            return id
        }
        /// Returns immutable observations after the batch finishes.
        func values() -> [(String, Int)] { lock.lock(); defer { lock.unlock() }; return attempts }
    }

    /// A committed aggregate receipt completes sources while all original manifests remain pending; disabling keeps that fact.
    func testConfirmedSourcesAreNotDirectUploadsAndDisablePreservesReceipt() async throws {
        let t_root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: t_root) }
        let t_capture = Capture(), t_host = "192.168.1.101"
        let t_collector = try p_collector(root: t_root, capture: t_capture)
        defer { CoverageURLProtocolStub.unregister(host: t_host) }
        CoverageURLProtocolStub.register(host: t_host) { t_request in
            self.p_success(root: t_root, id: t_capture.request(t_request))
        }
        let t_first = try await p_upload(t_collector, host: t_host)
        XCTAssertEqual(t_first.uploadedRunIDs.count, 1)
        XCTAssertEqual(t_first.mergedSourceCount, 3)
        XCTAssertNil(t_first.snapshotUpload)
        let t_store = try CoverageSnapshotStore(rootURL: t_root)
        let t_raw = try t_store.loadRecords()
        XCTAssertEqual(t_raw.count, 3)
        XCTAssertTrue(t_raw.allSatisfy { $0.uploadStatus == .pending })
        XCTAssertEqual(t_store.deliveredSourceIDs(records: t_raw).count, 3)
        t_collector.setCrossLaunchMergeEnabled(false)
        let t_next = try await p_upload(t_collector, host: t_host)
        XCTAssertEqual(t_next.uploadedRunIDs, [t_next.snapshotRunID])
        XCTAssertEqual(t_next.mergedSourceCount, 0)
        XCTAssertTrue(t_next.summary.mergeDetail?.isEmpty ?? true)
        XCTAssertEqual(t_next.summary.deliveredSourceCount, 3)
        XCTAssertEqual(t_next.summary.pendingCount, 0)
    }

    /// Lost responses retry one encoded object, then a later user action may combine its unconfirmed originals with new data.
    func testFixedRetriesAndNextBatchRecombinesOriginals() async throws {
        let t_root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: t_root) }
        let t_capture = Capture(), t_host = "192.168.1.102"
        let t_collector = try p_collector(root: t_root, capture: t_capture)
        defer { CoverageURLProtocolStub.unregister(host: t_host) }
        CoverageURLProtocolStub.register(host: t_host) { t_request in
            _ = t_capture.request(t_request)
            return CoverageURLProtocolStub.StubResponse(error: URLError(.timedOut))
        }
        let t_first = try await p_upload(t_collector, host: t_host)
        XCTAssertEqual(t_first.failedRunIDs.count, 1)
        XCTAssertEqual(t_first.mergeStatistics.count, 1)
        let t_attempts = t_capture.values()
        XCTAssertEqual(t_attempts.count, 3)
        XCTAssertEqual(Set(t_attempts.map { $0.0 }).count, 1)
        XCTAssertEqual(Set(t_attempts.map { $0.1 }).count, 1) // No request was re-encoded during retries.
        XCTAssertEqual(t_first.summary.deliveredSourceCount, 0)
        CoverageURLProtocolStub.register(host: t_host) { t_request in self.p_success(root: t_root, id: t_capture.request(t_request)) }
        let t_next = try await p_upload(t_collector, host: t_host)
        XCTAssertEqual(t_next.uploadedRunIDs.count, 1)
        XCTAssertNotEqual(t_next.uploadedRunIDs.first, t_first.failedRunIDs.first)
        XCTAssertEqual(t_next.mergedSourceCount, 4)
        let t_raw = try CoverageSnapshotStore(rootURL: t_root).loadRecords()
        XCTAssertEqual(t_raw.count, 4)
        XCTAssertTrue(t_raw.allSatisfy { $0.uploadStatus == .pending })
    }

    /// Disabling after an uncertain aggregate response permits direct gzip of every unconfirmed original, without deleting it.
    func testDisableAfterResponseLossRestoresRawGzip() async throws {
        let t_root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: t_root) }
        let t_capture = Capture(), t_host = "192.168.1.103"
        let t_collector = try p_collector(root: t_root, capture: t_capture)
        defer { CoverageURLProtocolStub.unregister(host: t_host) }
        CoverageURLProtocolStub.register(host: t_host) { t_request in
            _ = t_capture.request(t_request)
            return CoverageURLProtocolStub.StubResponse(error: URLError(.networkConnectionLost))
        }
        _ = try await p_upload(t_collector, host: t_host)
        t_collector.setCrossLaunchMergeEnabled(false)
        CoverageURLProtocolStub.register(host: t_host) { t_request in
            XCTAssertEqual(t_request.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
            return self.p_success(root: t_root, id: t_capture.request(t_request))
        }
        let t_next = try await p_upload(t_collector, host: t_host)
        XCTAssertEqual(t_next.uploadedRunIDs.count, 4)
        XCTAssertEqual(t_next.mergedSourceCount, 0)
        XCTAssertTrue(try CoverageSnapshotStore(rootURL: t_root).loadRecords().allSatisfy { $0.uploadStatus == .uploaded })
    }

    /// Complete gzip savings decide adoption; reducing request count alone cannot publish or upload an aggregate.
    func testInsufficientBenefitFallsBackToEveryRawInput() async throws {
        let t_root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: t_root) }
        let t_capture = Capture(), t_host = "192.168.1.106"
        let t_collector = try p_collector(root: t_root, capture: t_capture, minimumSavingsBytes: Int.max)
        defer { CoverageURLProtocolStub.unregister(host: t_host) }
        CoverageURLProtocolStub.register(host: t_host) { t_request in self.p_success(root: t_root, id: t_capture.request(t_request)) }
        let t_report = try await p_upload(t_collector, host: t_host)
        XCTAssertEqual(t_report.uploadedRunIDs.count, 3)
        XCTAssertEqual(t_report.mergedSourceCount, 0)
        XCTAssertFalse(t_report.fallbackReasons.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: t_root.appendingPathComponent("aggregates").path))
    }

    /// Durable object/attempt publication belongs to the preparation budget; no indexed request starts after that cost overruns.
    func testDurablePublicationCostCanForceRawFallbackBeforeFirstSend() async throws {
        let t_root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: t_root) }
        let t_capture = Capture(), t_host = "192.168.1.107"
        var t_writes = 0 // After construction, this injection counter is accessed only by the Collector-owned Store queue.
        let t_durability = CoverageDurableFile { t_boundary in
            if t_boundary == .beforeWrite { t_writes += 1 }
            if t_writes == 3 && t_boundary == .beforeFileSync { Thread.sleep(forTimeInterval: 2.1) }
        }
        let t_collector = try p_collector(root: t_root, capture: t_capture, timeoutMilliseconds: 2000, durability: t_durability)
        defer { CoverageURLProtocolStub.unregister(host: t_host) }
        CoverageURLProtocolStub.register(host: t_host) { t_request in self.p_success(root: t_root, id: t_capture.request(t_request)) }
        let t_report = try await p_upload(t_collector, host: t_host)
        XCTAssertEqual(t_report.uploadedRunIDs.count, 3)
        XCTAssertEqual(t_report.mergedSourceCount, 0)
        XCTAssertTrue(t_report.mergeStatistics.isEmpty)
        XCTAssertTrue(t_report.fallbackReasons.contains { $0.contains("耐久提交") })
        XCTAssertTrue(try CoverageSnapshotStore(rootURL: t_root).loadRecords().allSatisfy { $0.uploadStatus == .uploaded })
    }

    /// Preparation leaves the Collector queue responsive, freezes inputs and rejects a second action before it can capture.
    func testPreparationFreezesInputsWhileCaptureAndRestoreContinue() async throws {
        let t_root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: t_root) }
        let t_capture = Capture(), t_host = "192.168.1.104", t_gate = DispatchSemaphore(value: 0)
        let t_started = expectation(description: "worker started")
        let t_collector = try p_collector(root: t_root, capture: t_capture, engine: { _, _ in
            t_started.fulfill(); _ = t_gate.wait(timeout: .now() + 10)
            return Self.p_payload()
        })
        defer { t_gate.signal(); CoverageURLProtocolStub.unregister(host: t_host) }
        CoverageURLProtocolStub.register(host: t_host) { t_request in self.p_success(root: t_root, id: t_capture.request(t_request)) }
        let t_task = Task { try await self.p_upload(t_collector, host: t_host) }
        await fulfillment(of: [t_started], timeout: 5)
        let t_later = try await withCheckedThrowingContinuation { t_continuation in
            t_collector.captureManually { t_continuation.resume(with: $0) }
        }
        do { _ = try await p_upload(t_collector, host: t_host); XCTFail("busy must reject a second action") }
        catch CoverageCollector.CollectorError.busy { }
        let t_summary = await withCheckedContinuation { t_continuation in t_collector.restoreFromDisk { t_continuation.resume(returning: $0) } }
        XCTAssertTrue(t_summary.isPreparing)
        XCTAssertTrue(t_summary.isUploading)
        t_gate.signal()
        let t_report = try await t_task.value
        XCTAssertEqual(t_report.mergedSourceCount, 3)
        XCTAssertEqual(t_report.summary.pendingCount, 1)
        let t_store = try CoverageSnapshotStore(rootURL: t_root)
        let t_raw = try t_store.loadRecords()
        XCTAssertFalse(t_store.deliveredSourceIDs(records: t_raw).contains(t_later.runID))
    }

    /// Injects a synthetic indexed payload only to exercise bookkeeping; LLVM semantics are verified by Tools/ProfileMerge/verify.py.
    private func p_collector(root: URL, capture: Capture, minimumSavingsBytes: Int = 1, timeoutMilliseconds: Int = 60_000, durability: CoverageDurableFile = CoverageDurableFile(),
                             engine: @escaping CoverageMergePreparation.Engine = { _, _ in p_payload() }) throws -> CoverageCollector {
        let t_store = try CoverageSnapshotStore(rootURL: root), t_metadata = try CoverageTestFixtures.metadata()
        let t_device = try t_store.loadOrCreateDeviceID()
        for t_index in 0..<2 {
            _ = try t_store.createSnapshot(profileData: Data((0..<16_384).map { UInt8(truncatingIfNeeded: $0 * 17 + t_index) }), metadata: t_metadata,
                deviceID: t_device, launchID: UUID().uuidString.lowercased(), appState: "active", triggerReason: "manual_snapshot", captureSequence: 1)
        }
        let t_collectorStore = try CoverageSnapshotStore(rootURL: root, durability: durability)
        let t_collector = CoverageCollector(uploadClient: CoverageUploadClient(session: CoverageURLProtocolStub.makeSession(), encoder: capture.encode), store: t_collectorStore, metadata: t_metadata)
        t_collector.installMergeEngine(limits: CoverageMergeLimits(maxSources: 64, maxInputBytes: 64 * 1024 * 1024,
            maxOutputBytes: 1024 * 1024, maxRecords: 1_000_000, timeoutMilliseconds: timeoutMilliseconds, maxRequestBytes: 2 * 1024 * 1024,
            maxRequestGrowthRatio: 10, minimumSavingsBytes: minimumSavingsBytes, minimumSavingsRatio: 0,
            maxProcessResidentBytes: Int.max, minimumFreeDiskBytes: 1), engine: engine)
        t_collector.setCrossLaunchMergeEnabled(true)
        return t_collector
    }

    /// Returns the state-test header; these bytes are never presented as real LLVM merge output.
    private static func p_payload() -> Data { Data([0xff, 0x6c, 0x70, 0x72, 0x6f, 0x66, 0x69, 0x81, 12, 0, 0, 0, 0, 0, 0, 0]) }

    /// Builds exact echoes from already committed aggregate artifacts or an active original manifest.
    private func p_success(root: URL, id: String) -> CoverageURLProtocolStub.StubResponse {
        do {
            let t_files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
            let t_object = t_files.first { $0.lastPathComponent == "object.json" && $0.deletingLastPathComponent().lastPathComponent == id }
            let t_value: [String: Any]
            if let t_object {
                let t_record = try JSONDecoder().decode(CoverageAggregateRecord.self, from: Data(contentsOf: t_object))
                let t_payload = try Data(contentsOf: t_object.deletingLastPathComponent().appendingPathComponent("payload.profdata"))
                XCTAssertEqual(CoverageCanonicalJSON.sha256(t_payload), t_record.sha256)
                t_value = ["status": "accepted", "run_id": id, "cycle_id": t_record.cycleID, "build_id": t_record.buildID,
                    "sha256": t_record.sha256, "size": t_record.size, "received_at": "2026-01-01T00:00:00Z", "analyzable": true,
                    "profile_format": "indexed", "metadata_sha256": t_record.metadataSHA256]
            } else {
                let t_url = try XCTUnwrap(t_files.first { $0.lastPathComponent == id + ".json" && $0.path.contains("/snapshots/") })
                let t_record = try JSONDecoder().decode(CoverageSnapshotRecord.self, from: Data(contentsOf: t_url))
                t_value = ["status": "accepted", "run_id": id, "cycle_id": t_record.cycleID, "build_id": t_record.buildID,
                    "sha256": t_record.sha256, "size": t_record.size, "received_at": "2026-01-01T00:00:00Z", "analyzable": true]
            }
            return CoverageURLProtocolStub.StubResponse(statusCode: 202, body: try JSONSerialization.data(withJSONObject: t_value))
        } catch { XCTFail("missing committed object: \(error)"); return CoverageURLProtocolStub.StubResponse(statusCode: 422) }
    }

    /// Awaits one manual operation while preserving the Collector's main-thread completion contract.
    private func p_upload(_ collector: CoverageCollector, host: String) async throws -> CoverageCollector.UploadReport {
        try await withCheckedThrowingContinuation { t_continuation in
            collector.uploadAllPending(configuration: try! CoverageTestFixtures.configuration(host: host)) { t_continuation.resume(with: $0) }
        }
    }
}
