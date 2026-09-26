import Foundation
import XCTest
import EmailCore

@testable import TranslationCore

/// LLM 引擎的单元测试。不碰真实网络：URLProtocol stub 假装服务商。
///
/// 重点钉住四条契约：
/// 1. 按 id 对账（不依赖返回顺序），缺失片段回退原文；
/// 2. 429/5xx/坏 JSON 重试一次，仍失败才抛；
/// 3. 401/403 等鉴权错误不重试、原样抛出；
/// 4. 缓存命名空间 id 随 host/模型变化。
final class LLMTranslationEngineTests: XCTestCase {

    // MARK: - URLProtocol stub

    private final class StubURLProtocol: URLProtocol {

        private static let lock = NSLock()
        private static var queue: [Result<(HTTPURLResponse, Data), Error>] = []
        private static var requestCount = 0
        private static var lastRequest: URLRequest?

        static func enqueue(_ result: Result<(HTTPURLResponse, Data), Error>) {
            lock.lock(); defer { lock.unlock() }
            queue.append(result)
        }
        static var count: Int {
            lock.lock(); defer { lock.unlock() }
            return requestCount
        }
        static var lastURLRequest: URLRequest? {
            lock.lock(); defer { lock.unlock() }
            return lastRequest
        }
        static func reset() {
            lock.lock(); defer { lock.unlock() }
            queue = []
            requestCount = 0
            lastRequest = nil
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.lock()
            Self.requestCount += 1
            Self.lastRequest = request
            let result = Self.queue.isEmpty
                ? Result<(HTTPURLResponse, Data), Error>.failure(URLError(.unsupportedURL))  // 队列空 = 测试没写对
                : Self.queue.removeFirst()
            Self.lock.unlock()

            switch result {
            case .success(let (response, data)):
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            case .failure(let error):
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    // MARK: - 夹具

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    private func makeEngine(apiKey: String = "test-key") -> LLMTranslationEngine {
        var configuration = LLMTranslationConfiguration.deepSeekTemplate
        configuration.apiKey = apiKey
        configuration.timeout = 5
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubURLProtocol.self]
        return LLMTranslationEngine(
            configuration: configuration,
            session: URLSession(configuration: sessionConfiguration),
            retryDelay: 0.01
        )
    }

    private func makeSegment(id: Int, text: String) -> TranslationSegment {
        let html = "<p>\(text)</p>"
        let range = html.range(of: text)!
        return TranslationSegment(
            id: id,
            kind: .paragraph,
            sourceText: text,
            range: range,
            coreRange: range,
            ancestorTags: ["p"]
        )
    }

    private static func httpResponse(_ statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://stub.test")!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }

    private static func completionBody(content: String) -> Data {
        let object: [String: Any] = ["choices": [["message": ["role": "assistant", "content": content]]]]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private static func translationsJSON(_ pairs: [(Int, String)]) -> String {
        let items = pairs.map { #"{"id":\#($0.0),"text":"\#($0.1)"}"# }.joined(separator: ",")
        return #"{"translations":[\#(items)]}"#
    }

    /// 把"模型返回 content"包装成一次成功的 HTTP 响并入队。
    private func enqueueCompletion(_ content: String, statusCode: Int = 200) {
        StubURLProtocol.enqueue(.success((Self.httpResponse(statusCode), Self.completionBody(content: content))))
    }

    /// 入队一次原始 HTTP 响应（模拟 429 / 鉴权失败等）。
    private func enqueueRaw(_ statusCode: Int) {
        StubURLProtocol.enqueue(.success((Self.httpResponse(statusCode), Data())))
    }

    private let zh = Locale.Language(identifier: "zh")

    // MARK: - 正常路径

    func testTranslatesByIdRegardlessOfReturnOrder() async throws {
        // 故意乱序返回 —— 按 id 对账，不依赖数组顺序
        enqueueCompletion(Self.translationsJSON([(1, "世界"), (0, "你好")]))

        let result = try await makeEngine().translate(
            segments: [makeSegment(id: 0, text: "Hello"), makeSegment(id: 1, text: "World")],
            sourceLanguage: nil,
            targetLanguage: zh
        )

        XCTAssertEqual(result.map(\.id), [0, 1], "结果顺序必须与入参一致")
        XCTAssertEqual(result.map(\.targetText), ["你好", "世界"])
    }

    func testMissingSegmentsFallBackToSourceText() async throws {
        // 模型漏回了 id 1 —— 该片段必须回退原文，而不是丢掉
        enqueueCompletion(Self.translationsJSON([(0, "你好")]))

        let result = try await makeEngine().translate(
            segments: [makeSegment(id: 0, text: "Hello"), makeSegment(id: 1, text: "World")],
            sourceLanguage: nil,
            targetLanguage: zh
        )

        XCTAssertEqual(result.first { $0.id == 0 }?.targetText, "你好")
        XCTAssertEqual(result.first { $0.id == 1 }?.targetText, "World")
    }

    func testSendsBearerAuthAndCorrectEndpoint() async throws {
        enqueueCompletion(Self.translationsJSON([(0, "你好")]))

        _ = try await makeEngine().translate(
            segments: [makeSegment(id: 0, text: "Hello")],
            sourceLanguage: nil,
            targetLanguage: zh
        )

        let request = try XCTUnwrap(StubURLProtocol.lastURLRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
    }

    func testParsesJSONWrappedInCodeFences() async throws {
        // 模型有时会把 JSON 包进 ```json 围栏 —— 必须能剥掉
        enqueueCompletion("```json\n" + Self.translationsJSON([(0, "你好")]) + "\n```")

        let result = try await makeEngine().translate(
            segments: [makeSegment(id: 0, text: "Hello")],
            sourceLanguage: nil,
            targetLanguage: zh
        )

        XCTAssertEqual(result.first?.targetText, "你好")
    }

    // MARK: - 重试

    func testRetriesOnceOn429AndThenSucceeds() async throws {
        enqueueRaw(429)
        enqueueCompletion(Self.translationsJSON([(0, "你好")]))

        let result = try await makeEngine().translate(
            segments: [makeSegment(id: 0, text: "Hello")],
            sourceLanguage: nil,
            targetLanguage: zh
        )

        XCTAssertEqual(result.first?.targetText, "你好")
        XCTAssertEqual(StubURLProtocol.count, 2, "429 之后应当恰好重试一次")
    }

    func testGivesUpAfterOneRetryOnPersistent429() async {
        enqueueRaw(429)
        enqueueRaw(429)

        do {
            _ = try await makeEngine().translate(
                segments: [makeSegment(id: 0, text: "Hello")],
                sourceLanguage: nil,
                targetLanguage: zh
            )
            XCTFail("应当抛错")
        } catch {
            XCTAssertEqual(StubURLProtocol.count, 2, "最多两次尝试，不能无限重试")
        }
    }

    func testBadJSONRetriesOnceThenThrows() async {
        enqueueCompletion("这不是 JSON")
        enqueueCompletion("这也不是 JSON")

        do {
            _ = try await makeEngine().translate(
                segments: [makeSegment(id: 0, text: "Hello")],
                sourceLanguage: nil,
                targetLanguage: zh
            )
            XCTFail("应当抛错")
        } catch {
            XCTAssertEqual(StubURLProtocol.count, 2)
        }
    }

    /// 401/403 是确定性失败（key 不对），重试没有意义 —— 必须立刻抛。
    func testAuthErrorDoesNotRetry() async {
        enqueueRaw(401)

        do {
            _ = try await makeEngine().translate(
                segments: [makeSegment(id: 0, text: "Hello")],
                sourceLanguage: nil,
                targetLanguage: zh
            )
            XCTFail("应当抛错")
        } catch {
            XCTAssertEqual(StubURLProtocol.count, 1, "鉴权错误不应重试")
        }
    }

    // MARK: - 分块（纯逻辑）

    func testChunkPacksByCharacterLimitWithoutSplittingSegments() {
        let segments = [
            makeSegment(id: 0, text: String(repeating: "a", count: 6)),
            makeSegment(id: 1, text: String(repeating: "b", count: 6)),
            makeSegment(id: 2, text: String(repeating: "c", count: 6))
        ]

        let chunks = LLMTranslationEngine.chunk(segments, limit: 10)

        // 任何一段都不会被拆开；超限即开新块
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.flatMap { $0.map(\.id) }, [0, 1, 2])
    }

    func testChunkKeepsOversizedSegmentAsItsOwnChunk() {
        let oversized = makeSegment(id: 0, text: String(repeating: "a", count: 20))
        let normal = makeSegment(id: 1, text: "hi")

        let chunks = LLMTranslationEngine.chunk([oversized, normal], limit: 10)

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].map(\.id), [0])
        XCTAssertEqual(chunks[1].map(\.id), [1])
    }

    // MARK: - 身份与可用性

    func testAvailabilityRequiresAPIKey() async {
        var configuration = LLMTranslationConfiguration.deepSeekTemplate
        configuration.apiKey = ""
        let engineWithoutKey = LLMTranslationEngine(configuration: configuration)

        let withoutKey = await engineWithoutKey.availability(source: nil, target: zh)
        XCTAssertEqual(withoutKey, .unsupported)

        configuration.apiKey = "k"
        let engineWithKey = LLMTranslationEngine(configuration: configuration)
        let withKey = await engineWithKey.availability(source: nil, target: zh)
        XCTAssertEqual(withKey, .installed)
    }

    func testCacheNamespaceChangesWithHostAndModel() {
        var configuration = LLMTranslationConfiguration.deepSeekTemplate
        configuration.apiKey = "k"
        let deepSeek = LLMTranslationEngine(configuration: configuration)

        configuration.baseURL = URL(string: "https://api.openai.com/v1")!
        configuration.model = "gpt-4o-mini"
        let openAI = LLMTranslationEngine(configuration: configuration)

        XCTAssertEqual(deepSeek.id, "llm.api.deepseek.com.deepseek-flash.v1")
        XCTAssertEqual(openAI.id, "llm.api.openai.com.gpt-4o-mini.v1")
        XCTAssertNotEqual(deepSeek.id, openAI.id, "换服务商/换模型必须隔离缓存")
    }

    // MARK: - endpoint 规整（纯逻辑）

    func testEndpointNormalization() {
        func endpoint(_ base: String) -> String {
            LLMTranslationEngine.endpoint(baseURL: URL(string: base)!).absoluteString
        }

        XCTAssertEqual(endpoint("https://api.deepseek.com"), "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(endpoint("https://api.deepseek.com/"), "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(endpoint("https://api.openai.com/v1"), "https://api.openai.com/v1/chat/completions")
        // 用户直接粘完整 endpoint 时原样使用
        XCTAssertEqual(endpoint("https://x.test/v1/chat/completions"), "https://x.test/v1/chat/completions")
    }
}
