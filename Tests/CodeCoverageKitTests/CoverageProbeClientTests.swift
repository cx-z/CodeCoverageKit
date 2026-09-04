import Foundation
import XCTest
@testable import CodeCoverageKit

final class CoverageProbeClientTests: XCTestCase {
    /// 验证 health 使用固定公共路径、GET 方法且不会附加受限上传凭证。
    func testHealthRequestUsesPublicEndpointWithoutAuthorization() async throws {
        let t_host = "192.168.1.41"
        CoverageURLProtocolStub.register(host: t_host) { _ in
            CoverageURLProtocolStub.StubResponse(body: Data(#"{"status":"ok","server_version":"coverage-server/1","server_time":"2026-09-03T00:00:00Z","instance_id":"test-instance"}"#.utf8))
        }
        defer { CoverageURLProtocolStub.unregister(host: t_host) }
        let t_client = CoverageProbeClient(session: CoverageURLProtocolStub.makeSession())

        let t_result = try await t_client.checkHealth(configuration: CoverageTestFixtures.configuration(host: t_host))
        let t_request = try XCTUnwrap(CoverageURLProtocolStub.lastRequest(host: t_host))

        XCTAssertEqual(t_result.instanceID, "test-instance")
        XCTAssertEqual(t_request.httpMethod, "GET")
        XCTAssertEqual(t_request.url?.path, "/health")
        XCTAssertNil(t_request.value(forHTTPHeaderField: "Authorization"))
    }

    /// 验证探针使用中性 payload、文件名和 boundary，且 multipart 只含 sha256 与 file。
    func testProbeRequestUsesNeutralIdentifiersAndExactFields() async throws {
        let t_host = "192.168.1.42"
        let t_client = CoverageProbeClient(session: CoverageURLProtocolStub.makeSession())
        let t_prepared = try await t_client.prepareTestProbe(configuration: CoverageTestFixtures.configuration(host: t_host))
        let t_request = t_prepared.request
        let t_contentType = try XCTUnwrap(t_request.value(forHTTPHeaderField: "Content-Type"))
        let t_body = String(decoding: t_prepared.body, as: UTF8.self)

        XCTAssertEqual(t_request.url?.path, "/api/v1/probes")
        XCTAssertTrue(t_contentType.contains("boundary=code-coverage-kit-probe-"))
        XCTAssertEqual(t_request.value(forHTTPHeaderField: "Authorization"), "Bearer \(CoverageTestFixtures.token)")
        XCTAssertTrue(t_body.contains(#""kind":"code-coverage-kit-network-probe""#))
        XCTAssertTrue(t_body.contains(#"filename="code-coverage-kit-network-probe.json""#))
        XCTAssertEqual(t_body.components(separatedBy: #"name="sha256""#).count - 1, 1)
        XCTAssertEqual(t_body.components(separatedBy: #"name="file""#).count - 1, 1)
        XCTAssertFalse(t_body.contains(#"name="metadata""#))
        XCTAssertFalse(t_body.contains(#"name="profile""#))
    }

    /// 验证 401/403 被归类为鉴权错误，且错误文案不会回显受限 Token。
    func testProbeAuthenticationFailureDoesNotExposeToken() async throws {
        let t_host = "192.168.1.43"
        CoverageURLProtocolStub.register(host: t_host) { _ in
            CoverageURLProtocolStub.StubResponse(statusCode: 401, body: Data(#"{"error":"invalid_token"}"#.utf8))
        }
        defer { CoverageURLProtocolStub.unregister(host: t_host) }
        let t_client = CoverageProbeClient(session: CoverageURLProtocolStub.makeSession())

        do {
            _ = try await t_client.uploadTestProbe(configuration: CoverageTestFixtures.configuration(host: t_host))
            XCTFail("401 必须失败")
        } catch let t_error as CoverageProbeClient.ClientError {
            guard case .authenticationFailed = t_error else {
                return XCTFail("错误分类不匹配：\(t_error)")
            }
            XCTAssertFalse(t_error.localizedDescription.contains(CoverageTestFixtures.token))
        }
    }
}
