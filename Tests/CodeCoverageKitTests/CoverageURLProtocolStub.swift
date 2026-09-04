import Foundation

final class CoverageURLProtocolStub: URLProtocol {
    struct StubResponse {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
        let error: Error?

        /// 创建一个可返回 HTTP 数据或传输错误的不可变响应。
        init(
            statusCode: Int = 200,
            headers: [String: String] = ["Content-Type": "application/json"],
            body: Data = Data(),
            error: Error? = nil
        ) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
            self.error = error
        }
    }

    typealias Handler = (URLRequest) -> StubResponse

    private static let vLock = NSLock()
    private static var vHandlers: [String: Handler] = [:]
    private static var vRequests: [String: URLRequest] = [:]

    /// 为唯一测试主机注册响应处理器，并清除该主机的旧请求记录。
    static func register(host: String, handler: @escaping Handler) {
        vLock.lock()
        vHandlers[host] = handler
        vRequests.removeValue(forKey: host)
        vLock.unlock()
    }

    /// 删除指定测试主机的处理器与请求记录，避免测试间共享状态泄漏。
    static func unregister(host: String) {
        vLock.lock()
        vHandlers.removeValue(forKey: host)
        vRequests.removeValue(forKey: host)
        vLock.unlock()
    }

    /// 在线程安全边界内返回指定主机最近收到的不可变请求值。
    static func lastRequest(host: String) -> URLRequest? {
        vLock.lock()
        defer { vLock.unlock() }
        return vRequests[host]
    }

    /// 仅接管已由测试注册处理器的 URL 请求。
    override class func canInit(with request: URLRequest) -> Bool {
        guard let t_host = request.url?.host else { return false }
        vLock.lock()
        defer { vLock.unlock() }
        return vHandlers[t_host] != nil
    }

    /// 保持测试请求原样，便于检查路径、Header 与 multipart body。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// 取出当前主机的响应后再调用 URLProtocolClient，避免在锁内执行外部回调。
    override func startLoading() {
        guard let t_host = request.url?.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.vLock.lock()
        Self.vRequests[t_host] = request
        let t_handler = Self.vHandlers[t_host]
        Self.vLock.unlock()
        guard let t_handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let t_stub = t_handler(request)
        if let t_error = t_stub.error {
            client?.urlProtocol(self, didFailWithError: t_error)
            return
        }
        guard let t_url = request.url,
              let t_response = HTTPURLResponse(
                url: t_url,
                statusCode: t_stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: t_stub.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: t_response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: t_stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// URLProtocolStub 没有可取消的底层资源，停止时无需额外动作。
    override func stopLoading() {}

    /// 创建只使用本 Stub 的临时 URLSession，禁止请求落到真实网络。
    static func makeSession() -> URLSession {
        let t_configuration = URLSessionConfiguration.ephemeral
        t_configuration.protocolClasses = [CoverageURLProtocolStub.self]
        return URLSession(configuration: t_configuration)
    }
}

