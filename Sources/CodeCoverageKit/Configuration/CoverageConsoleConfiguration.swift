#if CODE_COVERAGE_KIT_ENABLED
import Foundation

struct CoverageConsoleConfiguration: Decodable, Equatable, Sendable {
    static let resourceName = "CodeCoverageKitConfiguration"

    let serverAddress: String
    let serverPort: Int

    enum CodingKeys: String, CodingKey {
        case serverAddress = "server_address"
        case serverPort = "server_port"
    }

    /// 返回由中性地址和端口组成的控制台输入占位提示，不参与实际网络请求。
    var serverURLPlaceholder: String {
        "http://\(serverAddress):\(serverPort)"
    }

    /// 从 SDK 资源读取控制台展示配置；资源缺失或格式错误时返回 nil，不影响动态 Build metadata。
    static func load(bundle: Bundle = .module) -> CoverageConsoleConfiguration? {
        guard let t_url = bundle.url(forResource: resourceName, withExtension: "json"),
              let t_data = try? Data(contentsOf: t_url) else {
            return nil
        }
        return try? JSONDecoder().decode(CoverageConsoleConfiguration.self, from: t_data)
    }
}
#endif
