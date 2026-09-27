import EmailCore
import Foundation
import CryptoKit
import os

/// 百度翻译开放平台 · 图片翻译 V2.0（`/ait/api/picture/translate`）。
///
/// 接口要点（2026-09 官方文档核对）：
/// - POST JSON 到 `https://fanyi-api.baidu.com/ait/api/picture/translate`；
/// - **Access Token 鉴权，两个凭证必须配对**：请求头
///   `Authorization: Bearer <密钥>`（即控制台的 API Key），**请求体再带
///   `appid`**（开发者后台的 APP ID）—— 只填一个或错配都会报
///   54001 invalid token（实测踩坑）；
/// - 请求体：`content` = 图片 Base64（原图 ≤5M）、`paste = 1`（整图贴合）、
///   `view_type = 1`（高精擦除）、`model_type = "nmt"`、`need_intervene = 0`；
/// - 响应 `paste_img` 为**整图贴合的渲染译文图**（Base64 PNG），
///   另有全文 `src` / `dst` 与逐行 `contents`；
/// - 语种附录：马来语 = may、印尼语 = id、日语 = jp、韩语 = kor、
///   法语 = fra、西班牙语 = spa（**无繁中 / 阿拉伯 / 印地 / 乌克兰 / 越南**）。
public struct BaiduImageTranslationService: ImageTranslationService {

    /// 开发者后台的 APP ID（放请求体）。
    public let appId: String
    /// 控制台的 API Key / 密钥（放 Bearer 头）。
    public let secretKey: String
    private let session: URLSession
    private let trace = Logger(subsystem: "com.zhuyuhao.Mailingo", category: "img")

    public init(appId: String, secretKey: String, timeout: TimeInterval = 120, session: URLSession? = nil) {
        self.appId = appId
        self.secretKey = secretKey
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout * 2
            self.session = URLSession(configuration: configuration)
        }
    }

    public var id: String { "imgtrans.baidu.v2" }

    /// 文档口径「原图大小上限为 5M」，留出安全余量按 3.5MB 压缩目标
    /// （base64 之后约 4.7M，低于服务端 5M 的判线）。
    public var maxImageBytes: Int { 3_500_000 }

    public func translateImage(
        data: Data,
        mimeType: String,
        target: Locale.Language
    ) async throws -> TranslatedImage {
        let lowerMime = mimeType.lowercased()
        guard lowerMime.contains("gif") == false else {
            throw TranslationEngineError.engineFailed("图片翻译不支持 GIF 动图")
        }
        guard data.count <= 5 * 1024 * 1024 else {
            throw TranslationEngineError.engineFailed("图片超过 5M，超出百度接口限制")
        }
        let targetCode = try Self.languageCode(for: target)

        let payload: [String: Any] = [
            "from": "auto",
            "to": targetCode,
            "appid": appId,
            "content": data.base64EncodedString(),
            "paste": 1,
            "need_intervene": 0,
            "view_type": 1,
            "model_type": "nmt"
        ]
        var request = URLRequest(url: URL(string: "https://fanyi-api.baidu.com/ait/api/picture/translate")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secretKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (responseData, httpResponse) = try await session.data(for: request)
        guard let http = httpResponse as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (httpResponse as? HTTPURLResponse)?.statusCode ?? -1
            throw TranslationEngineError.engineFailed("HTTP \(status)：\(String(decoding: responseData.prefix(300), as: UTF8.self))")
        }

        let decoded = try? JSONDecoder().decode(BaiduResponse.self, from: responseData)
        if let errorCode = decoded?.errorCode, errorCode != "0", !errorCode.isEmpty {
            var message = "百度翻译失败（\(errorCode)）：\(decoded?.errorMsg ?? "未知错误")"
            if errorCode == "54001" {
                message += " —— 请核对设置里百度翻译的 APP ID 与 API Key 是否**配对**（两个都要填，缺一或错配都会报这个错）"
            }
            throw TranslationEngineError.engineFailed(message)
        }
        // 诊断：paste_img 为空时把原始响应带出来（截断）—— 可能是图里没有可识别
        // 文字、贴合服务没生效，或接口形态与文档有出入，看到原文才能定位
        let rawResponse = String(decoding: responseData.prefix(800), as: UTF8.self)
        trace.notice("百度图片翻译响应 \(http.statusCode)：\(rawResponse, privacy: .public)")
        guard let pastedBase64 = decoded?.pasteImg, !pastedBase64.isEmpty else {
            throw TranslationEngineError.engineFailed(
                "百度没有返回整图贴合结果（paste_img 为空）。原始响应：\(rawResponse)"
            )
        }
        // 文档示例出现过 URL 转义形态（%252F = 编码过的 /）—— 解码失败先还原再试
        let rendered = Data(base64Encoded: pastedBase64)
            ?? pastedBase64.removingPercentEncoding.flatMap { Data(base64Encoded: $0) }
        guard let rendered, !rendered.isEmpty else {
            throw TranslationEngineError.engineFailed("整图贴合结果无法解码为图片（base64 长度 \(pastedBase64.count)）")
        }

        return TranslatedImage(
            imageData: rendered,
            // 官方示例的 paste_img 以 iVBORw0KGgo 开头 —— PNG
            mimeType: rendered.startsWithPNG ? "image/png" : "image/jpeg",
            detectedText: decoded?.src,
            translatedText: decoded?.dst
        )
    }

    // MARK: - 语言代码

    /// 百度图片翻译的语种附录（2026-09）。与系统/腾讯写法不同：
    /// 日语 = jp、韩语 = kor、法语 = fra、西班牙语 = spa、马来语 = may。
    /// 繁中、阿拉伯语、印地语、乌克兰语、越南语不在清单里 —— 明确报错并指路换厂商。
    static let languageAliases = [
        "ja": "jp", "ko": "kor", "fr": "fra", "es": "spa"
    ]

    static let supportedLanguages: Set<String> = [
        "zh", "en", "jp", "kor", "fra", "spa", "ru", "pt", "de", "it",
        "dan", "nl", "may", "swe", "id", "pl", "rom", "tr", "el", "hu"
    ]

    static func languageCode(for language: Locale.Language) throws -> String {
        let identifier = language.minimalIdentifier
        if let alias = languageAliases[identifier] { return alias }
        guard supportedLanguages.contains(identifier) else {
            throw TranslationEngineError.engineFailed(
                "百度图片翻译暂不支持目标语言：\(identifier) —— 可在设置里把图片翻译厂商切换为腾讯云"
            )
        }
        return identifier
    }

    // MARK: - 响应

    struct BaiduResponse: Decodable {
        let errorCode: String?
        let errorMsg: String?
        let src: String?
        let dst: String?
        let pasteImg: String?

        enum CodingKeys: String, CodingKey {
            case errorCode = "error_code"
            case errorMsg = "error_msg"
            case src
            case dst
            case pasteImg = "paste_img"
        }
    }
}

extension Data {
    /// 官方示例的 paste_img 以 PNG 魔数开头 —— 按真实字节决定 MIME。
    var startsWithPNG: Bool {
        starts(with: [0x89, 0x50, 0x4E, 0x47])
    }

    func starts(with bytes: [UInt8]) -> Bool {
        count >= bytes.count && zip(self, bytes).allSatisfy { $0 == $1 }
    }
}
