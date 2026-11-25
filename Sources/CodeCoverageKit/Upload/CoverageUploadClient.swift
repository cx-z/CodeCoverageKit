#if CODE_COVERAGE_KIT_ENABLED
import Foundation

final class CoverageUploadClient {
    struct PreparedUpload {
        let request: URLRequest
        let body: Data
        let uncompressedBodySize: Int
    }

    struct AcceptedRun: Sendable {
        let runID: String
        let cycleID: String
        let buildID: String
        let sha256: String
        let size: Int
        let receivedAt: String
        let analyzable: Bool
        let statusCode: Int
        let compressedBodySize: Int
        let uncompressedBodySize: Int
    }

    enum UploadError: LocalizedError {
        case encodingFailed
        case transport(String)
        case serverUnavailable(Int, String)
        case authenticationFailed
        case runConflict(String)
        case permanentRejection(Int, String)
        case invalidResponse(String)

        var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return "覆盖率上传压缩失败，原始数据已保留，请修复后重试。"
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

        /// 鉴权或编码失败停止整批，保留原始数据供后续用户操作恢复。
        var shouldStopBatch: Bool {
            switch self {
            case .authenticationFailed, .encodingFailed: return true
            default: return false
            }
        }

        /// 内容冲突和不可恢复拒绝为永久失败；编码失败保留原始 Run 供后续恢复。
        var isPermanent: Bool {
            switch self {
            case .runConflict, .permanentRejection, .invalidResponse:
                return true
            case .transport, .serverUnavailable, .authenticationFailed, .encodingFailed:
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
    private let vEncode: (Data) throws -> Data

    /// 创建无缓存会话和不可变 gzip 编码器；批次状态及重试由 Collector 所有。
    init(session: URLSession? = nil, encoder: @escaping (Data) throws -> Data = CoverageGzip.encode) {
        vEncode = encoder
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

    /// 上传既有 Run，并随严格校验后的响应返回该次请求体压缩前后的字节数。
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
            completion(p_validateResponse(data: data, response: response, error: error, record: record,
                                          compressedBodySize: t_preparedUpload.body.count,
                                          uncompressedBodySize: t_preparedUpload.uncompressedBodySize))
        }
        t_task.resume()
        return t_task
    }

    /// 校验原始 profile 并 gzip 编码 multipart，保留压缩前大小供展示，失败不发送原始数据。
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
        let t_encoded: Data
        do { t_encoded = try vEncode(t_body) }
        catch { throw UploadError.encodingFailed }
        let t_url = try p_endpointURL(baseURL: configuration.serverURL, path: "/api/v1/runs")
        var t_request = URLRequest(url: t_url)
        t_request.httpMethod = "POST"
        t_request.timeoutInterval = 120
        t_request.setValue("Bearer \(configuration.runUploadToken)", forHTTPHeaderField: "Authorization")
        t_request.setValue("multipart/form-data; boundary=\(t_boundary)", forHTTPHeaderField: "Content-Type")
        t_request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        t_request.setValue(String(t_encoded.count), forHTTPHeaderField: "Content-Length")
        return PreparedUpload(request: t_request, body: t_encoded, uncompressedBodySize: t_body.count)
    }

    /// 严格核对 HTTP 状态和身份回显，成功时携带本地请求大小，不改变原始 profile 校验口径。
    private func p_validateResponse(
        data: Data?,
        response: URLResponse?,
        error: Error?,
        record: CoverageSnapshotRecord,
        compressedBodySize: Int,
        uncompressedBodySize: Int
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
                statusCode: t_httpResponse.statusCode,
                compressedBodySize: compressedBodySize,
                uncompressedBodySize: uncompressedBodySize
            )
        )
    }

    /// 将编码失败与 Run 内容拒绝分开；截断请求仍可使用原始身份重试。
    private func p_serverError(statusCode: Int, data: Data) -> UploadError {
        let t_payload = try? JSONDecoder().decode(ErrorResponse.self, from: data)
        let t_detail = t_payload?.error ?? t_payload?.message ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
        if [400, 415].contains(statusCode),
           ["unsupported_content_encoding", "invalid_compressed_body"].contains(t_payload?.error ?? "") {
            return .encodingFailed
        }
        if statusCode == 400 && t_payload?.error == "incomplete_request" {
            return .transport("上传请求未完整接收")
        }
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
