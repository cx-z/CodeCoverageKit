#if CODE_COVERAGE_KIT_ENABLED
import Foundation

final class CoverageUploadClient {
    struct PreparedUpload {
        let request: URLRequest
        let body: Data
    }

    struct AcceptedRun {
        let runID: String
        let cycleID: String
        let buildID: String
        let sha256: String
        let size: Int
        let receivedAt: String
        let analyzable: Bool
        let statusCode: Int
    }

    enum UploadError: LocalizedError {
        case transport(String)
        case serverUnavailable(Int, String)
        case authenticationFailed
        case runConflict(String)
        case permanentRejection(Int, String)
        case invalidResponse(String)

        var errorDescription: String? {
            switch self {
            case .transport(let detail):
                return "网络请求失败：\(detail)"
            case .serverUnavailable(let status, let detail):
                return "服务暂不可用（HTTP \(status)）：\(detail)"
            case .authenticationFailed:
                return "当前测试包的上传凭证不属于该服务器，已停止本轮覆盖率上传。"
            case .runConflict(let detail):
                return "Run 身份永久冲突：\(detail)"
            case .permanentRejection(let status, let detail):
                return "服务端永久拒绝该 Run（HTTP \(status)）：\(detail)"
            case .invalidResponse(let detail):
                return "服务端响应未通过严格回显校验：\(detail)"
            }
        }

        /// 仅允许网络错误和 5xx 在当前这次用户操作内有限重试。
        var isRetryableInCurrentOperation: Bool {
            switch self {
            case .transport, .serverUnavailable:
                return true
            default:
                return false
            }
        }

        /// 401/403 表示整批请求继续发送没有意义，必须立即结束本轮。
        var shouldStopBatch: Bool {
            if case .authenticationFailed = self {
                return true
            }
            return false
        }

        /// 409 及不可恢复的协议/4xx 错误不会在后续用户操作中自动重试。
        var isPermanent: Bool {
            switch self {
            case .runConflict, .permanentRejection, .invalidResponse:
                return true
            case .transport, .serverUnavailable, .authenticationFailed:
                return false
            }
        }
    }

    private struct RunResponse: Decodable {
        let status: String
        let runID: String
        let cycleID: String
        let buildID: String
        let sha256: String
        let size: Int
        let receivedAt: String
        let analyzable: Bool

        enum CodingKeys: String, CodingKey {
            case status
            case runID = "run_id"
            case cycleID = "cycle_id"
            case buildID = "build_id"
            case sha256
            case size
            case receivedAt = "received_at"
            case analyzable
        }
    }

    private struct ErrorResponse: Decodable {
        let error: String?
        let message: String?
    }

    private let vSession: URLSession

    /// 创建独立的无缓存上传会话；该客户端不保存队列状态，也不会自行重试或后台上传。
    init(session: URLSession? = nil) {
        if let session {
            vSession = session
        } else {
            let t_configuration = URLSessionConfiguration.ephemeral
            t_configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            t_configuration.timeoutIntervalForRequest = 30
            t_configuration.timeoutIntervalForResource = 120
            t_configuration.waitsForConnectivity = false
            vSession = URLSession(configuration: t_configuration)
        }
    }

    /// 上传一个既有 Run；multipart 严格只含 metadata、sha256、profile，且不在内部创建新 run_id。
    @discardableResult
    func upload(
        record: CoverageSnapshotRecord,
        profileURL: URL,
        configuration: CoverageServerConfiguration,
        completion: @escaping (Result<AcceptedRun, UploadError>) -> Void
    ) throws -> URLSessionUploadTask {
        let t_preparedUpload = try prepareUpload(
            record: record,
            profileURL: profileURL,
            configuration: configuration
        )
        let t_task = vSession.uploadTask(with: t_preparedUpload.request, from: t_preparedUpload.body) { [weak self] data, response, error in
            guard let self else { return }
            completion(p_validateResponse(data: data, response: response, error: error, record: record))
        }
        t_task.resume()
        return t_task
    }

    /// 读取并校验既有 profile，构造一次不可变 Run 请求供上传流程和协议测试共用。
    func prepareUpload(
        record: CoverageSnapshotRecord,
        profileURL: URL,
        configuration: CoverageServerConfiguration
    ) throws -> PreparedUpload {
        guard !configuration.runUploadToken.isEmpty else {
            throw UploadError.authenticationFailed
        }
        let t_metadata = try record.makeRunMetadataData()
        let t_profile = try Data(contentsOf: profileURL, options: [.mappedIfSafe])
        guard t_profile.count == record.size else {
            throw UploadError.invalidResponse("上传前 profile 大小已变化")
        }
        let t_boundary = "code-coverage-kit-run-\(UUID().uuidString)"
        let t_body = p_makeMultipartBody(
            metadata: t_metadata,
            sha256: record.sha256,
            profile: t_profile,
            filename: "\(record.runID).profraw",
            boundary: t_boundary
        )
        let t_url = try p_endpointURL(baseURL: configuration.serverURL, path: "/api/v1/runs")
        var t_request = URLRequest(url: t_url)
        t_request.httpMethod = "POST"
        t_request.timeoutInterval = 120
        t_request.setValue("Bearer \(configuration.runUploadToken)", forHTTPHeaderField: "Authorization")
        t_request.setValue("multipart/form-data; boundary=\(t_boundary)", forHTTPHeaderField: "Content-Type")
        t_request.setValue(String(t_body.count), forHTTPHeaderField: "Content-Length")
        return PreparedUpload(request: t_request, body: t_body)
    }

    /// 严格核对 HTTP 状态和六个身份字段，只有全部一致才返回服务端已接收。
    private func p_validateResponse(
        data: Data?,
        response: URLResponse?,
        error: Error?,
        record: CoverageSnapshotRecord
    ) -> Result<AcceptedRun, UploadError> {
        if let error {
            return .failure(.transport(error.localizedDescription))
        }
        guard let t_httpResponse = response as? HTTPURLResponse else {
            return .failure(.invalidResponse("缺少 HTTP 状态码"))
        }
        let t_data = data ?? Data()
        guard [200, 201, 202].contains(t_httpResponse.statusCode) else {
            return .failure(p_serverError(statusCode: t_httpResponse.statusCode, data: t_data))
        }
        guard let t_payload = try? JSONDecoder().decode(RunResponse.self, from: t_data) else {
            return .failure(.invalidResponse("成功响应不是约定 JSON"))
        }
        guard t_payload.status == "accepted" else {
            return .failure(.invalidResponse("status 不是 accepted"))
        }
        guard t_payload.runID == record.runID,
              t_payload.cycleID == record.cycleID,
              t_payload.buildID == record.buildID,
              t_payload.sha256.lowercased() == record.sha256,
              t_payload.size == record.size else {
            return .failure(.invalidResponse("run_id、cycle_id、build_id、sha256 或 size 回显不一致"))
        }
        return .success(
            AcceptedRun(
                runID: t_payload.runID,
                cycleID: t_payload.cycleID,
                buildID: t_payload.buildID,
                sha256: t_payload.sha256,
                size: t_payload.size,
                receivedAt: t_payload.receivedAt,
                analyzable: t_payload.analyzable,
                statusCode: t_httpResponse.statusCode
            )
        )
    }

    /// 将非成功 HTTP 响应分类为鉴权停止、永久冲突、可重试 5xx 或其他永久拒绝。
    private func p_serverError(statusCode: Int, data: Data) -> UploadError {
        let t_payload = try? JSONDecoder().decode(ErrorResponse.self, from: data)
        let t_detail = t_payload?.error ?? t_payload?.message ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
        switch statusCode {
        case 401, 403:
            return .authenticationFailed
        case 409:
            return .runConflict(t_detail)
        case 500...599:
            return .serverUnavailable(statusCode, t_detail)
        default:
            return .permanentRejection(statusCode, t_detail)
        }
    }

    /// 在已校验的局域网根地址上构造固定 Run API 路径。
    private func p_endpointURL(baseURL: URL, path: String) throws -> URL {
        guard var t_components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw UploadError.invalidResponse("无法构造 Run API 地址")
        }
        t_components.path = path
        guard let t_url = t_components.url else {
            throw UploadError.invalidResponse("无法构造 Run API 地址")
        }
        return t_url
    }

    /// 按平台 Run 协议构造恰好三个 multipart 字段，不附带 Build 产物或额外表单项。
    private func p_makeMultipartBody(
        metadata: Data,
        sha256: String,
        profile: Data,
        filename: String,
        boundary: String
    ) -> Data {
        var t_body = Data()
        t_body.append(p_utf8Data("--\(boundary)\r\n"))
        t_body.append(p_utf8Data("Content-Disposition: form-data; name=\"metadata\"\r\n"))
        t_body.append(p_utf8Data("Content-Type: application/json\r\n\r\n"))
        t_body.append(metadata)
        t_body.append(p_utf8Data("\r\n--\(boundary)\r\n"))
        t_body.append(p_utf8Data("Content-Disposition: form-data; name=\"sha256\"\r\n\r\n"))
        t_body.append(p_utf8Data("\(sha256)\r\n"))
        t_body.append(p_utf8Data("--\(boundary)\r\n"))
        t_body.append(p_utf8Data("Content-Disposition: form-data; name=\"profile\"; filename=\"\(filename)\"\r\n"))
        t_body.append(p_utf8Data("Content-Type: application/octet-stream\r\n\r\n"))
        t_body.append(profile)
        t_body.append(p_utf8Data("\r\n--\(boundary)--\r\n"))
        return t_body
    }

    /// 将 multipart 头字段稳定转换为 UTF-8 字节。
    private func p_utf8Data(_ string: String) -> Data {
        Data(string.utf8)
    }
}
#endif
