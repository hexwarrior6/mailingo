import Foundation
import XCTest

@testable import EmailCore

/// 读取测试 fixture。
///
/// `Package.swift` 用 `.copy("Fixtures")`，所以整个目录被原样拷进 bundle，
/// 里面的字节就是我们提交进仓库的字节 —— 对 MIME 测试很重要，
/// 任何"顺手规范化一下"都会让测试失去意义。
enum Fixtures {

    /// 真实邮件（已脱敏）：单部分 `text/html`，UTF-8。
    static let realSinglepartHTML = "real-singlepart-html.eml"
    /// 合成：`multipart/alternative` + CRLF + quoted-printable。
    static let alternativeQP = "synthetic-alternative-qp.eml"
    /// 合成：`multipart/related` + GB18030 + base64 + CID 内联图。
    static let relatedGB18030CID = "synthetic-related-gb18030-cid.eml"
    /// 合成：头部区超过 8KB。
    static let headerHeavy = "synthetic-header-heavy.eml"
    /// 合成：只有 `text/plain`。
    static let plainOnly = "synthetic-plain-only.eml"
    /// 合成：**声明 gb2312、正文实际含 GBK 独有字节**（A8 43 = 短破折号）。
    /// 用来钉住"一个字节让整段解码返回 nil、整篇中文变乱码"这个真实缺陷。
    static let gb2312DeclaredGBKActual = "synthetic-gb2312-declared-gbk-actual.eml"

    static func data(_ name: String) throws -> Data {
        let file = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        guard let url = Bundle.module.url(forResource: "Fixtures/\(file)", withExtension: ext) else {
            throw FixtureError.notFound(name)
        }
        return try Data(contentsOf: url)
    }

    static func text(_ name: String) throws -> String {
        let raw = try data(name)
        guard let text = String(data: raw, encoding: .utf8) else {
            throw FixtureError.notUTF8(name)
        }
        return text
    }

    enum FixtureError: Error, CustomStringConvertible {
        case notFound(String)
        case notUTF8(String)

        var description: String {
            switch self {
            case .notFound(let name): "找不到 fixture：\(name)"
            case .notUTF8(let name): "fixture 不是 UTF-8：\(name)"
            }
        }
    }
}
