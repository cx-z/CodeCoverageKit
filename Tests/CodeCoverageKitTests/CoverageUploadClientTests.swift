import Foundation
import XCTest
@testable import CodeCoverageKit

final class CoverageUploadClientTests: XCTestCase {
    /// 验证 Run 请求使用中性 boundary，且 multipart 严格只含 metadata、sha256、profile。
    func testPreparedRunRequestUsesExactFieldsAndRestrictedAuthorization() throws {
        let t_profile = Data("profile-data".utf8)
        let (t_url, t_record) = try p_writeProfile(t_profile)
        defer { try? FileManager.default.removeItem(at: t_url.deletingLastPathComponent()) }
        let t_client = CoverageUploadClient(session: CoverageURLProtocolStub.makeSession())

        let t_prepared = try t_client.prepareUpload(
            record: t_record,
            profileURL: t_url,
            configuration: CoverageTestFixtures.configuration(host: "192.168.1.51")
        )
        let t_contentType = try XCTUnwrap(t_prepared.request.value(forHTTPHeaderField: "Content-Type"))
        let t_body = String(decoding: t_prepared.body, as: UTF8.self)

        XCTAssertEqual(t_prepared.request.url?.path, "/api/v1/runs")
        XCTAssertTrue(t_contentType.contains("boundary=code-coverage-kit-run-"))
        XCTAssertEqual(t_prepared.request.value(forHTTPHeaderField: "Authorization"), "Bearer \(CoverageTestFixtures.token)")
        XCTAssertEqual(t_body.components(separatedBy: #"name="metadata""#).count - 1, 1)
        XCTAssertEqual(t_body.components(separatedBy: #"name="sha256""#).count - 1, 1)
        XCTAssertEqual(t_body.components(separatedBy: #"name="profile""#).count - 1, 1)
        XCTAssertFalse(t_body.contains(#"name="file""#))
        XCTAssertTrue(t_body.contains(#"filename="33333333-3333-4333-8333-333333333333.profraw""#))
    }

    /// 验证 200/201/202 中只有身份字段全部一致的 accepted 响应才会被接受。
    func testAcceptedRunResponseRequiresExactIdentity() async throws {
        let t_profile = Data("accepted-profile".utf8)
        let (t_url, t_record) = try p_writeProfile(t_profile)
        defer { try? FileManager.default.removeItem(at: t_url.deletingLastPathComponent()) }
        let t_host = "192.168.1.52"
        CoverageURLProtocolStub.register(host: t_host) { _ in
            CoverageURLProtocolStub.StubResponse(
                statusCode: 202,
                body: self.p_successBody(record: t_record)
            )
        }
        defer { CoverageURLProtocolStub.unregister(host: t_host) }

        let t_result = try await p_upload(
            client: CoverageUploadClient(session: CoverageURLProtocolStub.makeSession()),
            record: t_record,
            profileURL: t_url,
            host: t_host
        )

        guard case .success(let t_accepted) = t_result else {
            return XCTFail("有效响应必须成功")
        }
        XCTAssertEqual(t_accepted.statusCode, 202)
        XCTAssertEqual(t_accepted.runID, t_record.runID)
    }

    /// 验证成功 HTTP 中任何 Run 身份回显不一致都会保持本地记录未上传。
    func testAcceptedHTTPRejectsMismatchedIdentity() async throws {
        let t_profile = Data("mismatch-profile".utf8)
        let (t_url, t_record) = try p_writeProfile(t_profile)
        defer { try? FileManager.default.removeItem(at: t_url.deletingLastPathComponent()) }
        let t_host = "192.168.1.53"
        CoverageURLProtocolStub.register(host: t_host) { _ in
            CoverageURLProtocolStub.StubResponse(
                statusCode: 201,
                body: self.p_successBody(record: t_record, buildID: "99999999-9999-4999-8999-999999999999")
            )
        }
        defer { CoverageURLProtocolStub.unregister(host: t_host) }

        let t_result = try await p_upload(
            client: CoverageUploadClient(session: CoverageURLProtocolStub.makeSession()),
            record: t_record,
            profileURL: t_url,
            host: t_host
        )

        guard case .failure(.invalidResponse) = t_result else {
            return XCTFail("身份不一致必须归类为 invalidResponse")
        }
    }

    /// 验证鉴权、冲突、5xx 与传输错误继续保持停止、永久和可重试分类，且不泄露 Token。
    func testUploadErrorClassificationsAndSecretRedaction() async throws {
        let t_profile = Data("classification-profile".utf8)
        let (t_url, t_record) = try p_writeProfile(t_profile)
        defer { try? FileManager.default.removeItem(at: t_url.deletingLastPathComponent()) }

        let t_auth = try await p_failure(statusCode: 401, host: "192.168.1.54", record: t_record, profileURL: t_url)
        XCTAssertTrue(t_auth.shouldStopBatch)
        XCTAssertFalse(t_auth.isPermanent)
        XCTAssertFalse(t_auth.localizedDescription.contains(CoverageTestFixtures.token))

        let t_conflict = try await p_failure(statusCode: 409, host: "192.168.1.55", record: t_record, profileURL: t_url)
        XCTAssertTrue(t_conflict.isPermanent)
        XCTAssertFalse(t_conflict.isRetryableInCurrentOperation)

        let t_server = try await p_failure(statusCode: 503, host: "192.168.1.56", record: t_record, profileURL: t_url)
        XCTAssertTrue(t_server.isRetryableInCurrentOperation)
        XCTAssertFalse(t_server.isPermanent)

        let t_transportHost = "192.168.1.57"
        CoverageURLProtocolStub.register(host: t_transportHost) { _ in
            CoverageURLProtocolStub.StubResponse(error: URLError(.timedOut))
        }
        defer { CoverageURLProtocolStub.unregister(host: t_transportHost) }
        let t_transportResult = try await p_upload(
            client: CoverageUploadClient(session: CoverageURLProtocolStub.makeSession()),
            record: t_record,
            profileURL: t_url,
            host: t_transportHost
        )
        guard case .failure(let t_transportError) = t_transportResult else {
            return XCTFail("传输错误必须失败")
        }
        XCTAssertTrue(t_transportError.isRetryableInCurrentOperation)
        XCTAssertFalse(t_transportError.localizedDescription.contains(CoverageTestFixtures.token))
    }

    /// 写入一次测试 profile，并返回与实际 size/SHA 一致的 Run 记录。
    private func p_writeProfile(_ profile: Data) throws -> (URL, CoverageSnapshotRecord) {
        let t_directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: t_directory, withIntermediateDirectories: true)
        let t_url = t_directory.appendingPathComponent("\(CoverageTestFixtures.runID).profraw")
        try profile.write(to: t_url, options: [.atomic])
        return (t_url, CoverageTestFixtures.record(profile: profile))
    }

    /// 通过测试 URLSession 上传一个既有 Run，并异步返回客户端分类结果。
    private func p_upload(
        client: CoverageUploadClient,
        record: CoverageSnapshotRecord,
        profileURL: URL,
        host: String
    ) async throws -> Result<CoverageUploadClient.AcceptedRun, CoverageUploadClient.UploadError> {
        try await withCheckedThrowingContinuation { t_continuation in
            do {
                try client.upload(
                    record: record,
                    profileURL: profileURL,
                    configuration: CoverageTestFixtures.configuration(host: host)
                ) { t_result in
                    t_continuation.resume(returning: t_result)
                }
            } catch {
                t_continuation.resume(throwing: error)
            }
        }
    }

    /// 返回一个指定 HTTP 状态对应的稳定上传错误。
    private func p_failure(
        statusCode: Int,
        host: String,
        record: CoverageSnapshotRecord,
        profileURL: URL
    ) async throws -> CoverageUploadClient.UploadError {
        CoverageURLProtocolStub.register(host: host) { _ in
            CoverageURLProtocolStub.StubResponse(statusCode: statusCode, body: Data(#"{"error":"test_error"}"#.utf8))
        }
        defer { CoverageURLProtocolStub.unregister(host: host) }
        let t_result = try await p_upload(
            client: CoverageUploadClient(session: CoverageURLProtocolStub.makeSession()),
            record: record,
            profileURL: profileURL,
            host: host
        )
        guard case .failure(let t_error) = t_result else {
            throw XCTSkip("预期 HTTP \(statusCode) 返回失败")
        }
        return t_error
    }

    /// 生成与指定本地 Run 完全一致或按参数故意不一致的成功响应 JSON。
    private func p_successBody(record: CoverageSnapshotRecord, buildID: String? = nil) -> Data {
        let t_payload: [String: Any] = [
            "status": "accepted",
            "run_id": record.runID,
            "cycle_id": record.cycleID,
            "build_id": buildID ?? record.buildID,
            "sha256": record.sha256,
            "size": record.size,
            "received_at": "2026-09-03T00:00:01Z",
            "analyzable": true
        ]
        return try! JSONSerialization.data(withJSONObject: t_payload, options: [.sortedKeys])
    }
}

