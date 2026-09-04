import XCTest
@testable import CodeCoverageKit

final class CoverageConsoleConfigurationTests: XCTestCase {
    /// 验证 SDK 控制台从资源配置读取中性服务器地址占位值，且不会硬编码真实环境地址。
    func testLoadsNeutralServerAddressPlaceholder() throws {
        let t_configuration = try XCTUnwrap(CoverageConsoleConfiguration.load())

        XCTAssertEqual(t_configuration.serverAddress, "x.x.x.x")
        XCTAssertEqual(t_configuration.serverPort, 8765)
        XCTAssertEqual(t_configuration.serverURLPlaceholder, "http://x.x.x.x:8765")
    }
}
