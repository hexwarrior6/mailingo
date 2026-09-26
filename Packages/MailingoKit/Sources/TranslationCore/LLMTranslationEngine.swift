import EmailCore
import Foundation

/// LLM 引擎的连接配置。字段都会进设置界面，由用户填写；
/// API Key 在钥匙串里，这里只携带明文（引擎请求时用）。
public struct LLMTranslationConfiguration: Sendable {
    /// OpenAI 兼容的 base 地址（如 `https://api.deepseek.com`）；
    /// 也可以直接填完整 endpoint（含 `chat/completions`），按原样使用。
    public var baseURL: URL
    public var apiKey: String
    public var model: String
    /// 单次请求超时。大模型出首字可能要几秒，整段 JSON 出完更久。
    public var timeout: TimeInterval

    public init(baseURL: URL, apiKey: String, model: String, timeout: TimeInterval = 90) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.timeout = timeout
    }

    /// DeepSeek 官方模板（2026-09 按 api-docs.deepseek.com 核对：
    /// deepseek-flash = V4.1-Flash，1M 上下文，支持 JSON 输出）。
    public static let deepSeekTemplate = LLMTranslationConfiguration(
        baseURL: URL(string: "https://api.deepseek.com")!,
        apiKey: "",
        model: "deepseek-flash"
    )
}

/// 通用 OpenAI 兼容的大模型翻译引擎（DeepSeek / 智谱 / Moonshot / OpenAI /
/// SiliconFlow……凡是 chat/completions 兼容接口都能接）。
///
/// PRODUCT.md §13 的模块草图早就画了它；协议侧 `hasFullContext = true`
/// 的语义正是为它定义的 —— 管线**不剔除孤立虚词**，全部片段按文档顺序
/// 拼成带编号的完整原文交给模型，让它在整封邮件的语境里翻，
/// ` to `、`th` 这类被行内标签切开的虚词也能翻对。
///
/// 与 Apple 引擎的两点结构差异：
/// - 不需要 `AppleTranslationSessionBroker`（那是 SwiftUI `.translationTask`
///   的桥，HTTP 请求直接 `URLSession` 就行）；
/// - 缓存命名空间 `id` 带上 host 与模型名 —— 换模型 = 换缓存，互不污染。
public struct LLMTranslationEngine: TranslationEngine {

    // MARK: - 引擎身份

    /// 进缓存 key：host + 模型名进入命名空间，换服务商/换模型即自动隔离。
    public var id: String {
        let host = configuration.baseURL.host ?? "unknown"
        return "llm.\(host).\(configuration.model).v1"
    }

    public var displayName: String { "大模型（\(configuration.model)）" }

    public let hasFullContext = true

    // MARK: - 构造

    public let configuration: LLMTranslationConfiguration
    /// 测试注入点：真机用默认的 ephemeral session（不共享 Cookie/缓存）。
    private let session: URLSession
    /// 429 / 5xx / 坏 JSON 的重试间隔。测试里传 0.01 避免真睡。
    private let retryDelay: TimeInterval

    public init(configuration: LLMTranslationConfiguration, session: URLSession? = nil, retryDelay: TimeInterval = 1.5) {
        self.configuration = configuration
        self.retryDelay = retryDelay
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = configuration.timeout
            config.timeoutIntervalForResource = configuration.timeout * 2
            self.session = URLSession(configuration: config)
        }
    }

    public func availability(source: Locale.Language?, target: Locale.Language) async -> TranslationAvailability {
        // LLM 引擎没有"语言对"概念，只看有没有配置 key。
        configuration.apiKey.isEmpty ? .unsupported : .installed
    }

    // MARK: - 翻译

    /// 单块的目标字符量。太大单请求慢且失败重试代价高，太小请求次数多；
    /// 典型邮件一两个块就能装下，长邮件自然切分并逐块上报进度。
    static let chunkCharacterLimit = 6_000

    public func translate(
        segments: [TranslationSegment],
        sourceLanguage: Locale.Language?,
        targetLanguage: Locale.Language,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> [TranslatedSegment] {
        guard !segments.isEmpty else { return [] }
        guard !configuration.apiKey.isEmpty else {
            throw TranslationEngineError.engineFailed("大模型翻译还没有配置 API Key —— 到 设置 → 翻译（大模型）里填写。")
        }

        let chunks = Self.chunk(segments, limit: Self.chunkCharacterLimit)
        var collected: [Int: String] = [:]
        var completed = 0

        for chunk in chunks {
            try Task.checkCancellation()
            let translations = try await translateChunk(chunk, source: sourceLanguage, target: targetLanguage)
            for (id, text) in translations where collected[id] == nil {
                collected[id] = text
            }
            completed += chunk.count
            progress(completed, segments.count)
        }

        // 与 Apple 引擎同一约定：按 id 装配，缺失的回退原文，顺序与入参一致。
        return segments.map { segment in
            TranslatedSegment(id: segment.id, targetText: collected[segment.id] ?? segment.sourceText)
        }
    }

    // MARK: - 连接测试

    /// 设置里「测试连接」用：一条最小请求，返回模型回复的原文。
    public func verifyConnection() async throws -> String {
        let request = try chatRequest(
            messages: [ChatMessage(role: "user", content: "请只回复两个字：成功")],
            sourceLanguage: nil,
            target: nil,
            maxTokens: 256
        )
        let response = try await withRetry {
            try await sendOnce(request)
        }
        guard let content = response.choices?.first?.message?.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationEngineError.engineFailed(
                "模型返回了空内容（finish_reason=\(response.choices?.first?.finish_reason ?? "unknown")）"
            )
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 分块（纯逻辑，便于单测）

    /// 按字符量把片段装箱。单个超长片段（SegmentExtractor 上限 4000 字符）
    /// 自成一块；块与块之间不跨越片段边界。
    static func chunk(_ segments: [TranslationSegment], limit: Int) -> [[TranslationSegment]] {
        var chunks: [[TranslationSegment]] = []
        var current: [TranslationSegment] = []
        var currentCount = 0

        for segment in segments {
            let count = segment.sourceText.count
            if !current.isEmpty, currentCount + count > limit {
                chunks.append(current)
                current = []
                currentCount = 0
            }
            current.append(segment)
            currentCount += count
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: - 单块翻译

    private func translateChunk(
        _ chunk: [TranslationSegment],
        source: Locale.Language?,
        target: Locale.Language
    ) async throws -> [(Int, String)] {
        let request = try chatRequest(
            messages: [
                ChatMessage(role: "system", content: Self.systemPrompt),
                ChatMessage(role: "user", content: try Self.userPayload(chunk: chunk, source: source, target: target))
            ],
            sourceLanguage: source,
            target: target,
            maxTokens: 16_384
        )
        // 「请求 + 解析」整体进重试：429/5xx/传输失败/模型偶发输出残缺 JSON，
        // 重试一次常常就好了；仍失败才把真实原因抛给调用方。
        return try await withRetry {
            let response = try await sendOnce(request)
            let content = response.choices?.first?.message?.content ?? ""
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 空正文多半是输出被截断（finish_reason=length）——带上原因便于定位
                throw Retryable(underlying: TranslationEngineError.engineFailed(
                    "模型返回了空内容（finish_reason=\(response.choices?.first?.finish_reason ?? "unknown")）"
                ))
            }
            switch Self.parseTranslations(from: content) {
            case .success(let translations):
                return translations
            case .failure(let error):
                throw Retryable(underlying: error)
            }
        }
    }

    static let systemPrompt = """
    你是专业的邮件翻译引擎。用户会给出一份 JSON：目标语言、以及带编号的邮件文本片段（按阅读顺序）。
    把每个片段翻译成目标语言。要求：
    - 译文自然、忠实，保持原文的语气与礼貌等级；
    - URL、电子邮箱地址、代码与命令、文件名、纯数字保持原样，不要翻译；
    - 严格按片段边界翻译，不要合并或拆分片段；
    - 片段可能被行内链接切开，语义上前后相连，请结合整份上下文理解；
    - 只输出 JSON 对象 {"translations":[{"id":编号,"text":"译文"}]}，不要输出任何其他文字。
    """

    private static func userPayload(chunk: [TranslationSegment], source: Locale.Language?, target: Locale.Language) throws -> String {
        let payload: [String: Any] = [
            "source_language": source.map { TranslationLanguages.displayName(for: $0) } ?? "自动检测",
            "target_language": TranslationLanguages.displayName(for: target),
            "segments": chunk.map { ["id": $0.id, "text": $0.sourceText] }
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }

    /// 模型输出解析：剥掉可能的 ```json 围栏/前后闲话，取首尾大括号之间解码。
    /// 解析失败抛可重试错误 —— 模型偶发输出残缺，重试一次常常就好了。
    static func parseTranslations(from content: String) -> Result<[(Int, String)], TranslationEngineError> {
        var cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = cleaned.firstIndex(of: "{"), let end = cleaned.lastIndex(of: "}"), start < end {
            cleaned = String(cleaned[start...end])
        }
        guard let data = cleaned.data(using: .utf8),
              let payload = try? JSONDecoder().decode(TranslationPayload.self, from: data) else {
            return .failure(.engineFailed("模型返回的内容不是有效的翻译 JSON"))
        }
        return .success(payload.translations.map { ($0.id, $0.text) })
    }

    private struct TranslationPayload: Decodable {
        struct Item: Decodable {
            let id: Int
            let text: String
        }
        let translations: [Item]
    }

    // MARK: - HTTP

    private struct ChatMessage: Encodable {
        let role: String
        let content: String
    }

    private struct Thinking: Encodable {
        let type: String
    }

    private struct ResponseFormat: Encodable {
        let type: String
    }

    private struct ChatCompletionRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double
        let max_tokens: Int?
        let response_format: ResponseFormat?
        let thinking: Thinking?
    }

    struct ChatCompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message?
            let finish_reason: String?
        }
        let choices: [Choice]?
        let error: APIError?
        struct APIError: Decodable {
            struct Detail: Decodable { let message: String? }
            let error: Detail?
        }
    }

    /// DeepSeek V4.1 系列默认开启思考模式（effort=high），思维链会先吃掉
    /// max_tokens 预算，正文 `content` 就空了 —— 翻译不需要思考，明确关掉。
    ///
    /// 只对 DeepSeek 系模型发送这个参数：通用 OpenAI 兼容服务商可能拒绝
    /// 未知参数。命中规则：模型名含 "deepseek"（官方 flash/pro 与
    /// 第三方托管站上的 DeepSeek 模型都覆盖）。
    static func disablesThinking(forModel model: String) -> Bool {
        model.lowercased().contains("deepseek")
    }

    private func chatRequest(
        messages: [ChatMessage],
        sourceLanguage: Locale.Language?,
        target: Locale.Language?,
        maxTokens: Int?
    ) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint(baseURL: configuration.baseURL))
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ChatCompletionRequest(
                model: configuration.model,
                messages: messages,
                temperature: 0.3,
                max_tokens: maxTokens,
                response_format: target == nil ? nil : ResponseFormat(type: "json_object"),
                thinking: Self.disablesThinking(forModel: configuration.model) ? Thinking(type: "disabled") : nil
            )
        )
        return request
    }

    /// base 地址 + `/chat/completions`。用户直接粘完整 endpoint 时按原样使用；
    /// 兼容带不带 `/v1` 与尾斜杠的写法。
    static func endpoint(baseURL: URL) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return baseURL }
        let path = components.path
        if path.contains("chat/completions") { return baseURL }
        if path.hasSuffix("/") {
            components.path = path + "chat/completions"
        } else {
            components.path = path + "/chat/completions"
        }
        return components.url ?? baseURL
    }

    /// 可重试错误包装：429 / 5xx / 传输失败 / 200 但 JSON 无效。
    private struct Retryable: Error { let underlying: Error }

    /// 统一重试骨架：可重试错误退避后**最多再试一次**（共 2 次尝试），
    /// 其余错误原样抛出。取消在睡眠后立即响应。
    private func withRetry<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await operation()
            } catch let retryable as Retryable {
                if attempt >= 2 { throw retryable.underlying }
                try? await Task.sleep(for: .seconds(retryDelay))
                try Task.checkCancellation()
            }
        }
    }

    private func sendOnce(_ request: URLRequest) async throws -> ChatCompletionResponse {
        let data: Data
        let httpResponse: HTTPURLResponse
        do {
            let (payload, response) = try await session.data(for: request)
            data = payload
            guard let http = response as? HTTPURLResponse else {
                throw TranslationEngineError.engineFailed("服务商返回了非 HTTP 响应")
            }
            httpResponse = http
        } catch let error as TranslationEngineError {
            throw error
        } catch {
            // 传输层失败（超时、断网）—— 可重试
            throw Retryable(underlying: TranslationEngineError.engineFailed("网络请求失败：\(error.localizedDescription)"))
        }

        switch httpResponse.statusCode {
        case 200..<300:
            do {
                return try decode(data)
            } catch {
                // 200 但内容不可解析 —— 模型偶发输出残缺，值得重试一次
                throw Retryable(underlying: TranslationEngineError.engineFailed("模型返回内容无法解析：\(Self.prefix(data))"))
            }
        case 429, 500...599:
            throw Retryable(underlying: TranslationEngineError.engineFailed(
                "服务商暂时不可用（HTTP \(httpResponse.statusCode)）：\(Self.apiErrorMessage(data) ?? Self.prefix(data))"
            ))
        case 401, 403:
            throw TranslationEngineError.engineFailed("API Key 无效或没有权限（HTTP \(httpResponse.statusCode)）：\(Self.apiErrorMessage(data) ?? Self.prefix(data))")
        default:
            throw TranslationEngineError.engineFailed("HTTP \(httpResponse.statusCode)：\(Self.apiErrorMessage(data) ?? Self.prefix(data))")
        }
    }

    private func decode(_ data: Data) throws -> ChatCompletionResponse {
        let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        if let apiError = response.error {
            throw TranslationEngineError.engineFailed(apiError.error?.message ?? "服务商返回了错误")
        }
        return response
    }

    private static func apiErrorMessage(_ data: Data) -> String? {
        guard let response = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data),
              let message = response.error?.error?.message else { return nil }
        return message
    }

    private static func prefix(_ data: Data) -> String {
        String(decoding: data.prefix(300), as: UTF8.self)
    }
}
