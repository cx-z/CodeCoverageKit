import XCTest
@testable import CodeCoverageKit

final class CoverageServerConfigurationTests: XCTestCase {
    /// 验证私有 IPv4、链路本地 IPv4 与 `.local` 地址保持允许，且根路径被规范化。
    func testAcceptsLANServerURLs() throws {
        XCTAssertEqual(
            try CoverageServerConfiguration.normalizedServerURL(from: "HTTP://192.168.1.8:8765/").absoluteString,
            "http://192.168.1.8:8765"
        )
        XCTAssertEqual(
            try CoverageServerConfiguration.normalizedServerURL(from: "http://coverage-host.local:8765").host,
            "coverage-host.local"
        )
        XCTAssertEqual(
            try CoverageServerConfiguration.normalizedServerURL(from: "http://169.254.20.4:8765").host,
            "169.254.20.4"
        )
        XCTAssertEqual(
            try CoverageServerConfiguration.normalizedServerURL(from: "https://172.31.8.9").host,
            "172.31.8.9"
        )
    }

    /// 验证公网地址、业务路径、账号信息和查询参数仍在客户端安全边界内被拒绝。
    func testRejectsPublicOrPathURLs() {
        XCTAssertThrowsError(try CoverageServerConfiguration.normalizedServerURL(from: "https://example.com"))
        XCTAssertThrowsError(try CoverageServerConfiguration.normalizedServerURL(from: "http://192.168.1.8:8765/api"))
        XCTAssertThrowsError(try CoverageServerConfiguration.normalizedServerURL(from: "http://user:pass@192.168.1.8:8765"))
        XCTAssertThrowsError(try CoverageServerConfiguration.normalizedServerURL(from: "http://192.168.1.8:8765?project=other"))
    }

    /// 验证新宿主使用中性地址 key，且不会把受限 Token 写入 UserDefaults。
    @MainActor
    func testConfigurationStoreUsesNeutralKeyWithoutPersistingToken() throws {
        let t_suiteName = "CodeCoverageKitTests.\(UUID().uuidString)"
        guard let t_defaults = UserDefaults(suiteName: t_suiteName) else {
            XCTFail("无法创建测试 UserDefaults")
            return
        }
        defer { t_defaults.removePersistentDomain(forName: t_suiteName) }
        let t_store = CoverageServerConfigurationStore(defaults: t_defaults)
        let t_url = try XCTUnwrap(URL(string: "http://10.0.0.8:8765"))

        t_store.saveServerURLOverride(t_url)

        XCTAssertEqual(t_store.loadServerURLOverride(), "http://10.0.0.8:8765")
        XCTAssertEqual(t_defaults.string(forKey: "CodeCoverageKit.server_url"), "http://10.0.0.8:8765")
        XCTAssertFalse(t_defaults.dictionaryRepresentation().values.contains { ($0 as? String) == CoverageTestFixtures.token })
    }
}
