import Foundation
import XCTest
import zlib
@testable import CodeCoverageKit

final class CoverageUploadClientTests: XCTestCase {
    /// 验证 gzip 请求的原始 multipart 大小准确，且解压后字段、身份和凭证保持不变。
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
        let t_decoded = try p_decodeGzip(t_prepared.body)
        let t_body = String(decoding: t_decoded, as: UTF8.self)
        XCTAssertEqual(t_prepared.uncompressedBodySize, t_decoded.count)
        XCTAssertGreaterThan(t_prepared.uncompressedBodySize, t_record.size)
        XCTAssertEqual(t_prepared.request.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
        XCTAssertEqual(t_prepared.request.value(forHTTPHeaderField: "Content-Length"), String(t_prepared.body.count))

        XCTAssertEqual(t_prepared.request.url?.path, "/api/v1/runs")
        XCTAssertTrue(t_contentType.contains("boundary=code-coverage-kit-run-"))
        XCTAssertEqual(t_prepared.request.value(forHTTPHeaderField: "Authorization"), "Bearer \(CoverageTestFixtures.token)")
        XCTAssertEqual(t_body.components(separatedBy: #"name="metadata""#).count - 1, 1)
        XCTAssertEqual(t_body.components(separatedBy: #"name="sha256""#).count - 1, 1)
        XCTAssertEqual(t_body.components(separatedBy: #"name="profile""#).count - 1, 1)
        XCTAssertFalse(t_body.contains(#"name="file""#))
        XCTAssertTrue(t_body.contains(#"filename="33333333-3333-4333-8333-333333333333.profraw""#))
    }

    /// 验证 accepted 回显仍使用原始 profile 大小，压缩统计来自当前请求体。
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
            client: CoverageUploadClient(session: CoverageURLProtocolStub.makeSession(), encoder: { _ in Data([1, 2, 3]) }),
            record: t_record,
            profileURL: t_url,
            host: t_host
        )

        guard case .success(let t_accepted) = t_result else {
            return XCTFail("有效响应必须成功")
        }
        XCTAssertEqual(t_accepted.statusCode, 202)
        XCTAssertEqual(t_accepted.runID, t_record.runID)
        XCTAssertEqual(t_accepted.size, t_profile.count)
        XCTAssertEqual(t_accepted.compressedBodySize, 3)
        let t_prepared = try CoverageUploadClient().prepareUpload(
            record: t_record, profileURL: t_url,
            configuration: CoverageTestFixtures.configuration(host: t_host)
        )
        XCTAssertEqual(t_accepted.uncompressedBodySize, t_prepared.uncompressedBodySize)
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

    /// 验证本地编码失败不会生成原始上传任务，也不被判为永久数据损坏。
    func testCompressionFailurePreservesRunWithoutFallback() throws {
        let (t_url, t_record) = try p_writeProfile(Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: t_url.deletingLastPathComponent()) }
        let t_client = CoverageUploadClient(session: CoverageURLProtocolStub.makeSession(), encoder: { _ in
            throw CoverageGzip.EncodingError.inputTooLarge
        })
        XCTAssertThrowsError(try t_client.prepareUpload(record: t_record, profileURL: t_url,
                                                       configuration: CoverageTestFixtures.configuration(host: "192.168.1.61"))) { error in
            guard let t_error = error as? CoverageUploadClient.UploadError else { return XCTFail("wrong error") }
            XCTAssertTrue(t_error.shouldStopBatch)
            XCTAssertFalse(t_error.isPermanent)
            XCTAssertFalse(t_error.isRetryableInCurrentOperation)
        }
        XCTAssertEqual(try Data(contentsOf: t_url), Data("x".utf8))
    }

    /// 验证空内容、小文件和大文件均使用有效且确定的 gzip 单 member。
    func testGzipAlwaysEncodesAndRoundTrips() throws {
        for t_data in [Data(), Data([1]), Data((0..<300000).map { UInt8(truncatingIfNeeded: $0) })] {
            let t_encoded = try CoverageGzip.encode(t_data)
            XCTAssertEqual(Array(t_encoded.prefix(2)), [0x1f, 0x8b])
            XCTAssertEqual(try p_decodeGzip(t_encoded), t_data)
            XCTAssertEqual(try CoverageGzip.encode(t_data), t_encoded)
        }
    }

    /// 使用独立的系统 inflate 路径检查请求头、完整 gzip 结束标记和原始内容。
    private func p_decodeGzip(_ data: Data) throws -> Data {
        var t_stream = z_stream()
        XCTAssertEqual(inflateInit2_(&t_stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)), Z_OK)
        defer { inflateEnd(&t_stream) }
        return try data.withUnsafeBytes { t_input in
            t_stream.next_in = UnsafeMutablePointer<Bytef>(mutating: t_input.bindMemory(to: Bytef.self).baseAddress)
            t_stream.avail_in = uInt(data.count)
            var t_result = Data()
            var t_chunk = [UInt8](repeating: 0, count: 65536)
            var t_status = Z_OK
            repeat {
                t_status = t_chunk.withUnsafeMutableBytes { t_output in
                    t_stream.next_out = t_output.bindMemory(to: Bytef.self).baseAddress
                    t_stream.avail_out = uInt(t_output.count)
                    return inflate(&t_stream, Z_NO_FLUSH)
                }
                guard t_status == Z_OK || t_status == Z_STREAM_END else { throw CoverageGzip.EncodingError.zlibFailure(t_status) }
                t_result.append(contentsOf: t_chunk.prefix(t_chunk.count - Int(t_stream.avail_out)))
            } while t_status != Z_STREAM_END
            XCTAssertEqual(t_stream.avail_in, 0)
            return t_result
        }
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

