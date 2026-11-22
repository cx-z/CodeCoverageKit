import Foundation
import XCTest
@testable import CodeCoverageKit

final class CoverageCollectorTests: XCTestCase {
    /// 本地压缩失败必须停止整批并保留所有原始 profile，且不能伪装成鉴权失败。
    func testEncodingFailureStopsBatchAndKeepsOriginals() async throws {
        let t_root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: t_root) }
        let t_store = try CoverageSnapshotStore(rootURL: t_root)
        let t_client = CoverageUploadClient(session: CoverageURLProtocolStub.makeSession(), encoder: { _ in
            throw CoverageGzip.EncodingError.inputTooLarge
        })
        let t_collector = CoverageCollector(uploadClient: t_client, store: t_store, metadata: try CoverageTestFixtures.metadata())
        _ = try await p_capture(t_collector)
        let t_report = try await p_upload(t_collector)
        XCTAssertTrue(t_report.uploadedRunIDs.isEmpty)
        XCTAssertEqual(t_report.failedRunIDs.count, 1)
        XCTAssertFalse(t_report.stoppedForAuthentication)
        XCTAssertEqual(t_report.summary.failedCount, 1)
        let t_records = try t_store.loadRecords()
        XCTAssertEqual(t_records.count, 2)
        XCTAssertEqual(t_records.filter { $0.uploadStatus == .failedRetryable }.count, 1)
        XCTAssertEqual(t_records.compactMap(\.captureSequence).sorted(), [1, 2])
    }

    /// 在途请求期间采集和前台恢复不改变请求身份；第二次上传被拒绝且不额外采集。
    func testForegroundReloadProtectsInFlightRunAndFrozenBatch() async throws {
        let t_root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: t_root) }
        let t_store = try CoverageSnapshotStore(rootURL: t_root)
        let t_started = expectation(description: "upload started")
        let t_gate = DispatchSemaphore(value: 0)
        let t_host = "192.168.1.77"
        defer { t_gate.signal(); CoverageURLProtocolStub.unregister(host: t_host) }
        // Encoding errors stop after the HTTP response without triggering a second request.
        let t_client = CoverageUploadClient(session: CoverageURLProtocolStub.makeSession())
        let t_collector = CoverageCollector(uploadClient: t_client, store: t_store, metadata: try CoverageTestFixtures.metadata())
        let t_finished = expectation(description: "upload finished")
        // Use an encoding rejection so this test observes exactly one request.
        CoverageURLProtocolStub.register(host: t_host) { _ in
            t_started.fulfill()
            _ = t_gate.wait(timeout: .now() + 10)
            return CoverageURLProtocolStub.StubResponse(statusCode: 400, body: Data(#"{"error":"invalid_compressed_body"}"#.utf8))
        }
        t_collector.uploadAllPending(configuration: try CoverageTestFixtures.configuration(host: t_host)) { t_result in
            guard case .success(let t_report) = t_result else { t_finished.fulfill(); return XCTFail("expected recoverable report") }
            XCTAssertFalse(t_report.stoppedForAuthentication)
            XCTAssertEqual(t_report.failedRunIDs.count, 1)
            t_finished.fulfill()
        }
        await fulfillment(of: [t_started], timeout: 5)
        _ = try await p_capture(t_collector)
        let t_summary = await withCheckedContinuation { t_continuation in
            t_collector.restoreFromDisk { t_continuation.resume(returning: $0) }
        }
        XCTAssertTrue(t_summary.isUploading)
        XCTAssertEqual(t_summary.pendingCount, 2)
        do { _ = try await p_upload(t_collector); XCTFail("second batch must be busy") }
        catch CoverageCollector.CollectorError.busy { }
        t_gate.signal()
        await fulfillment(of: [t_finished], timeout: 5)
        let t_records = try t_store.loadRecords()
        XCTAssertEqual(t_records.count, 2)
        XCTAssertEqual(t_records.filter { $0.uploadStatus == .failedRetryable }.count, 1)
    }

    /// 在主线程回调中等待一次真实 runtime 快照写盘，不执行网络。
    private func p_capture(_ collector: CoverageCollector) async throws -> CoverageCollector.SnapshotReport {
        try await withCheckedThrowingContinuation { continuation in
            collector.captureManually { continuation.resume(with: $0) }
        }
    }

    /// 等待一个用户触发批次的最终结果，使用固定测试服务地址。
    private func p_upload(_ collector: CoverageCollector) async throws -> CoverageCollector.UploadReport {
        let t_configuration = try CoverageTestFixtures.configuration(host: "192.168.1.77")
        return try await withCheckedThrowingContinuation { continuation in
            collector.uploadAllPending(configuration: t_configuration) { continuation.resume(with: $0) }
        }
    }
}
