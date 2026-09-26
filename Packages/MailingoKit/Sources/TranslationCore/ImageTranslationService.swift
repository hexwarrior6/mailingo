import EmailCore
import Foundation
import CryptoKit

/// 图片翻译的结果：渲染好的**整图**（可直接替换原图）加上识别/译文的纯文本。
public struct TranslatedImage: Sendable {
    /// 渲染后的整图字节（腾讯返回 JPG）。
    public let imageData: Data
    public let mimeType: String
    /// 图中识别出的原文（供调试与过滤：没有文字的图不值得翻）。
    public let detectedText: String?
    /// 译文全文。
    public let translatedText: String?

    public init(imageData: Data, mimeType: String, detectedText: String?, translatedText: String?) {
        self.imageData = imageData
        self.mimeType = mimeType
        self.detectedText = detectedText
        self.translatedText = translatedText
    }
}

/// 图片翻译服务抽象 —— 厂商可换（腾讯 / 百度……），渲染管线只认这个协议。
public protocol ImageTranslationService: Sendable {
    /// 进缓存命名空间的稳定标识（厂商 + 接口版本）。
    var id: String { get }
    /// 翻译一张图片。`target` 不受支持时抛 `TranslationEngineError`。
    func translateImage(
        data: Data,
        mimeType: String,
        target: Locale.Language
    ) async throws -> TranslatedImage
}

/// 腾讯云机器翻译 · 端到端图片翻译（`ImageTranslateLLM`）。
///
/// 接口要点（cloud.tencent.com/document/product/551/118482，2026-09 核对）：
/// - POST JSON 到 `tmt.tencentcloudapi.com`，`X-TC-Action: ImageTranslateLLM`；
/// - **Region 是必选公共参数**（`X-TC-Region`）—— 漏了它请求连地域都归不了位，
///   会直接被鉴权层拒绝（实测报 AuthFailure.SignatureFailure）；
/// - 鉴权是腾讯云 API 3.0 的 TC3-HMAC-SHA256 签名（SecretId + SecretKey）；
/// - 图片走 Base64（≤9M，PNG/JPG/JPEG，不支持 GIF）；
/// - `Mode`：0 = 端到端大模型 pro 版，1 = lite 版（更便宜）；
/// - 响应里的 `Data` 是**渲染好译文的整图**（Base64 JPG），
///   另有逐行 `TransDetails` 与全文 `SourceText` / `TargetText`；
/// - 频率限制 1 次/秒 —— 批量翻译时调用方要自己拉开间隔。
///
/// 密钥存钥匙串（见 App 层 `KeychainStore`），这里只拿明文。
public struct TencentImageTranslationService: ImageTranslationService {

    public let secretId: String
    public let secretKey: String
    /// 请求地域（必选）。tmt 的文档示例与默认可用区挂在广州。
    public let region: String
    /// 调用模式：0 = 端到端大模型 pro，1 = lite（默认，便宜）。
    public let mode: Int
    private let session: URLSession

    public init(
        secretId: String,
        secretKey: String,
        timeout: TimeInterval = 120,
        region: String = "ap-guangzhou",
        mode: Int = 1
    ) {
        self.secretId = secretId
        self.secretKey = secretKey
        self.region = region
        self.mode = mode
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        self.session = URLSession(configuration: configuration)
    }

    public var id: String { "imgtrans.tencent.v1" }

    /// 图片翻译接口支持的 18 种语言（文档口径，2026-09）。
    static let supportedLanguages: Set<String> = [
        "zh", "zh-TW", "zh-HK", "en", "ja", "ko", "th", "vi", "ru",
        "de", "fr", "ar", "es", "it", "id", "ms", "pt", "tr"
    ]

    /// 常见变体名 → 腾讯语言码。系统翻译的语言清单用的是它自己的写法
    /// （`zh` / `zh-TW`），这里做一层兜底映射。
    static let languageAliases = ["zh-Hans": "zh", "zh-Hant": "zh-TW"]

    static func languageCode(for language: Locale.Language) throws -> String {
        let identifier = language.minimalIdentifier
        if let alias = languageAliases[identifier] { return alias }
        guard supportedLanguages.contains(identifier) else {
            throw TranslationEngineError.engineFailed("图片翻译暂不支持目标语言：\(identifier)")
        }
        return identifier
    }

    public func translateImage(
        data: Data,
        mimeType: String,
        target: Locale.Language
    ) async throws -> TranslatedImage {
        // GIF 是动图，接口不支持；直接明确报错，让上层跳过这张图
        guard !mimeType.lowercased().contains("gif") else {
            throw TranslationEngineError.engineFailed("图片翻译不支持 GIF 动图")
        }
        let targetCode = try Self.languageCode(for: target)

        let body: [String: Any] = [
            "Data": data.base64EncodedString(),
            "Target": targetCode,
            "Mode": mode  // 0 = 端到端 pro，1 = lite
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let request = try signedRequest(payload: payload)

        let (responseData, httpResponse) = try await session.data(for: request)
        guard let http = httpResponse as? HTTPURLResponse else {
            throw TranslationEngineError.engineFailed("服务商返回了非 HTTP 响应")
        }

        let container = try? JSONDecoder().decode(Container.self, from: responseData)
        if let apiError = container?.response?.error {
            throw TranslationEngineError.engineFailed("腾讯云图片翻译失败（\(apiError.code ?? "?")）：\(apiError.message ?? "未知错误")")
        }
        guard http.statusCode == 200, let payloadResponse = container?.response else {
            throw TranslationEngineError.engineFailed("HTTP \(http.statusCode)：\(String(decoding: responseData.prefix(300), as: UTF8.self))")
        }
        // 文档示例里的 Data 字段出现过 URL 转义形态（%252F = 编码过的 /）——
        // 直接解码失败时先做一次百分号还原再试
        guard let renderedBase64 = payloadResponse.data, !renderedBase64.isEmpty else {
            throw TranslationEngineError.engineFailed("图片翻译没有返回渲染结果")
        }
        let rendered = Data(base64Encoded: renderedBase64)
            ?? renderedBase64.removingPercentEncoding.flatMap { Data(base64Encoded: $0) }
        guard let rendered, !rendered.isEmpty else {
            throw TranslationEngineError.engineFailed("渲染结果无法解码为图片（base64 长度 \(renderedBase64.count)）")
        }

        return TranslatedImage(
            imageData: rendered,
            mimeType: "image/jpeg",
            detectedText: payloadResponse.sourceText,
            translatedText: payloadResponse.targetText
        )
    }

    // MARK: - 腾讯云 API 3.0 签名（TC3-HMAC-SHA256）

    private struct Container: Decodable {
        let response: Payload?
        struct Payload: Decodable {
            let data: String?
            let sourceText: String?
            let targetText: String?
            let error: APIError?

            enum CodingKeys: String, CodingKey {
                case data = "Data"
                case sourceText = "SourceText"
                case targetText = "TargetText"
                case error = "Error"
            }
        }
        struct APIError: Decodable {
            let code: String?
            let message: String?

            enum CodingKeys: String, CodingKey {
                case code = "Code"
                case message = "Message"
            }
        }

        enum CodingKeys: String, CodingKey {
            case response = "Response"
        }
    }

    private func signedRequest(payload: Data) throws -> URLRequest {
        let host = "tmt.tencentcloudapi.com"
        let action = "ImageTranslateLLM"
        let version = "2018-03-21"
        let service = "tmt"

        let timestamp = Int(Date().timeIntervalSince1970)
        let date = Self.utcDateString(from: timestamp)
        let hashedPayload = Self.sha256Hex(payload)

        // 规范请求串：方法\n URI\n 查询串(空)\n 规范头(每行以\n结尾)\n 参与签名的头\n 哈希后的载荷
        // ⚠️ 规范头自身以 \n 结尾，公式又要求一个 \n —— 所以 x-tc-action 行和
        // 参与签名的头之间有一个**空行**（少了它签名必挂，官方算例可证）。
        let canonicalRequest = """
        POST
        /

        content-type:application/json; charset=utf-8
        host:\(host)
        x-tc-action:\(action.lowercased())

        content-type;host;x-tc-action
        \(hashedPayload)
        """

        // 签名串
        let stringToSign = """
        TC3-HMAC-SHA256
        \(timestamp)
        \(date)/\(service)/tc3_request
        \(Self.sha256Hex(Data(canonicalRequest.utf8)))
        """

        // 签名：TC3+SecretKey 逐级派生
        let secretDate = Self.hmac(Data(("TC3" + secretKey).utf8), Data(date.utf8))
        let secretService = Self.hmac(secretDate, Data(service.utf8))
        let secretSigning = Self.hmac(secretService, Data("tc3_request".utf8))
        let signature = Self.hex(Self.hmac(secretSigning, Data(stringToSign.utf8)))

        var request = URLRequest(url: URL(string: "https://\(host)/")!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(action, forHTTPHeaderField: "X-TC-Action")
        request.setValue(version, forHTTPHeaderField: "X-TC-Version")
        request.setValue(region, forHTTPHeaderField: "X-TC-Region")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-TC-Timestamp")
        request.setValue(
            "TC3-HMAC-SHA256 Credential=\(secretId)/\(date)/\(service)/tc3_request, "
                + "SignedHeaders=content-type;host;x-tc-action, Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = payload
        return request
    }

    static func utcDateString(from timestamp: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hmac(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
