#if CODE_COVERAGE_KIT_ENABLED
import Foundation

@MainActor
final class CoverageServerConfigurationStore {
    private enum Key {
        static let serverURL = "CodeCoverageKit.server_url"
    }

    private let vDefaults: UserDefaults

    /// 创建由主 Actor 约束的中性服务器地址覆盖存储。
    init(defaults: UserDefaults = .standard) {
        vDefaults = defaults
    }

    /// 读取用户显式保存的可选服务地址覆盖值，不读取任何上传凭证。
    func loadServerURLOverride() -> String? {
        vDefaults.string(forKey: Key.serverURL)
    }

    /// 保存一份已经过统一校验和规范化的用户服务地址覆盖值。
    func saveServerURLOverride(_ serverURL: URL) {
        vDefaults.set(serverURL.absoluteString, forKey: Key.serverURL)
    }

    /// 删除用户服务地址覆盖值，使后续请求立即回到当前安装包的默认地址。
    func removeServerURLOverride() {
        vDefaults.removeObject(forKey: Key.serverURL)
    }
}
#endif
