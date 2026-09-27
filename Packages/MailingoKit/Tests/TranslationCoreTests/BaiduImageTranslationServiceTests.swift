import Foundation
import XCTest
import EmailCore

@testable import TranslationCore

/// 百度图片翻译 V2.0（/ait/api/picture/translate，Access Token 鉴权）的契约测试。
/// 不碰真实网络：URLProtocol stub 假装百度。
final class BaiduImageTranslationServiceTests: XCTestCase {

    private final class StubURLProtocol: URLProtocol {

        private static let lock = NSLock()
        private static var queue: [Result<(HTTPURLResponse, Data), Error>] = []
        private static var requestCount = 0
        private static var lastRequest: URLRequest?

        static func enqueue(_ result: Result<(HTTPURLResponse, Data), Error>) {
            lock.lock(); defer { lock.unlock() }
            queue.append(result)
        }
        static var requestCountValue: Int {
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
                ? Result<(HTTPURLResponse, Data), Error>.failure(URLError(.unsupportedURL))
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

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    private func httpResponse(_ statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://fanyi-api.baidu.com")!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }

    private func makeServiceWithStubbedResponse(_ statusCode: Int, _ body: Data) -> BaiduImageTranslationService {
        StubURLProtocol.enqueue(.success((httpResponse(statusCode), body)))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubURLProtocol.self]
        return BaiduImageTranslationService(
            appId: "test-appid",
            secretKey: "test-secret",
            session: URLSession(configuration: sessionConfiguration)
        )
    }

    // PNG 魔数开头的假"渲染图"
    private let fakePNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 7, count: 16)

    // MARK: - 正常路径

    func testTranslateSendsBearerAuthAndParsesPasteImage() async throws {
        let bodyObject: [String: Any] = [
            "from": "en", "to": "zh",
            "src": "hello", "dst": "你好",
            "paste_img": fakePNG.base64EncodedString()
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: bodyObject)
        let service = makeServiceWithStubbedResponse(200, bodyData)

        let result = try await service.translateImage(
            data: Data("fake image".utf8),
            mimeType: "image/jpeg",
            target: Locale.Language(identifier: "zh")
        )

        XCTAssertEqual(result.imageData, fakePNG, "渲染图应为响应里的整图贴合")
        XCTAssertEqual(result.mimeType, "image/png", "官方 paste_img 示例是 PNG 魔数")
        XCTAssertEqual(result.translatedText, "你好")

        let request = try XCTUnwrap(StubURLProtocol.lastURLRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://fanyi-api.baidu.com/ait/api/picture/translate")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testErrorCodeSurfacesWithMessage() async {
        let service = makeServiceWithStubbedResponse(200, Data(
            #"{"error_code": "55002", "error_msg": "token校验失败"}"#.utf8
        ))

        do {
            _ = try await service.translateImage(
                data: Data("fake".utf8), mimeType: "image/jpeg", target: Locale.Language(identifier: "zh")
            )
            XCTFail("应当抛错")
        } catch {
            XCTAssertTrue(((error as? TranslationEngineError)?.description ?? "").contains("55002"))
        }
    }

    // MARK: - 限制类报错（守卫在网络调用之前触发，不会碰真实网络）

    func testGifIsRejected() async {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubURLProtocol.self]
        let service = BaiduImageTranslationService(
            appId: "test-appid",
            secretKey: "test-secret",
            session: URLSession(configuration: sessionConfiguration)
        )
        do {
            _ = try await service.translateImage(
                data: Data([0x47, 0x49, 0x46]), mimeType: "image/gif", target: Locale.Language(identifier: "zh")
            )
            XCTFail("应当抛错")
        } catch {
            XCTAssertTrue(((error as? TranslationEngineError)?.description ?? "").contains("GIF"))
        }
        XCTAssertEqual(StubURLProtocol.requestCountValue, 0, "守卫应在网络调用之前触发")
    }

    func testOversizedImageIsRejected() async {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubURLProtocol.self]
        let service = BaiduImageTranslationService(
            appId: "test-appid",
            secretKey: "test-secret",
            session: URLSession(configuration: sessionConfiguration)
        )
        let oversized = Data(count: 5 * 1024 * 1024 + 1)
        do {
            _ = try await service.translateImage(
                data: oversized, mimeType: "image/jpeg", target: Locale.Language(identifier: "zh")
            )
            XCTFail("应当抛错")
        } catch {
            XCTAssertTrue(((error as? TranslationEngineError)?.description ?? "").contains("5M"))
        }
        XCTAssertEqual(StubURLProtocol.requestCountValue, 0)
    }

    // MARK: - 语言代码映射（纯逻辑）

    func testLanguageCodeMappingUsesBaiduAppendixCodes() throws {
        XCTAssertEqual(try BaiduImageTranslationService.languageCode(for: Locale.Language(identifier: "zh")), "zh")
        XCTAssertEqual(try BaiduImageTranslationService.languageCode(for: Locale.Language(identifier: "ja")), "jp")
        XCTAssertEqual(try BaiduImageTranslationService.languageCode(for: Locale.Language(identifier: "ko")), "kor")
        XCTAssertEqual(try BaiduImageTranslationService.languageCode(for: Locale.Language(identifier: "fr")), "fra")
        XCTAssertEqual(try BaiduImageTranslationService.languageCode(for: Locale.Language(identifier: "es")), "spa")
        // 附录里印尼语 = id
        XCTAssertEqual(try BaiduImageTranslationService.languageCode(for: Locale.Language(identifier: "id")), "id")
    }

    func testUnsupportedLanguageThrowsWithVendorHint() {
        // 繁体中文不在百度图片翻译的语种清单里 —— 报错要指路换厂商
        XCTAssertThrowsError(try BaiduImageTranslationService.languageCode(for: Locale.Language(identifier: "zh-TW"))) { error in
            let message = (error as? TranslationEngineError)?.description ?? ""
            XCTAssertTrue(message.contains("腾讯云"), "报错应提示可切换厂商：\(message)")
        }
    }
}
