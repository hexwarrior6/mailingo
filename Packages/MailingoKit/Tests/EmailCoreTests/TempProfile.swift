import XCTest
@testable import EmailCore

/// 临时：量真实大邮件各步骤耗时。
final class TempProfile: XCTestCase {
    func testProfileBigEmail() throws {
        let store = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/com.zhuyuhao.Mailingo.MailExtension/Data/Library/Application Support/Mailingo/messages")
        for name in ["04b7239d291fc623.eml", "21f7a66c1b3b9785.eml"] {
            let data = try Data(contentsOf: store.appendingPathComponent(name))
            print("\n===== \(name)  原始 \(data.count / 1024) KB =====")

            func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
                let t0 = Date()
                let r = try body()
                print(String(format: "  %-34s %7.1f ms", (label as NSString).utf8String!, Date().timeIntervalSince(t0) * 1000))
                return r
            }

            let decoded = try time("decode (MIME)") { try RFC822MIMEDecoder().decode(data) }
            let html = decoded.html ?? ""
            print("  HTML 长度 = \(html.count) 字符, plainText = \(decoded.plainText?.count ?? -1)")
            print("  内嵌资源 \(decoded.inlineResources.count) 个, 合计 \(decoded.inlineResources.values.reduce(0) { $0 + $1.data.count } / 1024) KB")
            for (k, v) in decoded.inlineResources.prefix(4) {
                print("    \(k.prefix(30))  \(v.mimeType)  \(v.data.count / 1024) KB")
            }

            let analysis = try time("analyze (分词+分段)") { try EmailInspector.analyze(rawMessage: data) }
            print("  片段数 = \(analysis.segments.count)")

            let inspection0 = time("apply(空译文) splice+verify") { EmailInspector.apply(translations: [:], to: analysis) }
            print("  spliced 长度 = \(inspection0.splicedHTML.count)")

            var tr: [Int: String] = [:]
            for s in analysis.segments { tr[s.id] = s.sourceText }
            _ = time("apply(全译文) splice+verify") { EmailInspector.apply(translations: tr, to: analysis) }

            _ = time("CIDReferenceRewriter.rewrite") { CIDReferenceRewriter.rewrite(html) }
            _ = time("RemoteContentScanner") { RemoteContentScanner.remoteImageCount(in: html) }
        }
    }
}
