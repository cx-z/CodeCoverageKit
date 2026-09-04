#if CODE_COVERAGE_KIT_ENABLED
import Foundation

struct CoverageConsoleConfiguration: Decodable, Equatable, Sendable {
    static let resourceName = "CodeCoverageKitConfiguration"
    private static let resourceBundleName = "CodeCoverageKit"
    private final class BundleToken: NSObject {}

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

    /// 从当前分发方式的 SDK 资源 Bundle 读取控制台展示配置；资源缺失或格式错误时返回 nil。
    static func load() -> CoverageConsoleConfiguration? {
        guard let t_bundle = p_resourceBundle(),
              let t_url = t_bundle.url(forResource: resourceName, withExtension: "json"),
              let t_data = try? Data(contentsOf: t_url) else {
            return nil
        }
        return try? JSONDecoder().decode(CoverageConsoleConfiguration.self, from: t_data)
    }

    /// 解析 SwiftPM 或 CocoaPods 生成的资源 Bundle，不读取宿主业务资源。
    private static func p_resourceBundle() -> Bundle? {
        #if SWIFT_PACKAGE
        return .module
        #else
        let t_containingBundle = Bundle(for: BundleToken.self)
        if let t_url = t_containingBundle.url(forResource: resourceBundleName, withExtension: "bundle"),
           let t_bundle = Bundle(url: t_url) {
            return t_bundle
        }
        guard let t_url = Bundle.main.url(forResource: resourceBundleName, withExtension: "bundle") else {
            return nil
        }
        return Bundle(url: t_url)
        #endif
    }
}
#endif
