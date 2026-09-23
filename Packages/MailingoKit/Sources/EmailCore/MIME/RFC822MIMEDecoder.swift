import CoreFoundation
import Foundation

/// 精简 RFC 822 / MIME 解码器。
///
/// ## 为什么是自研而不是第三方
///
/// 方案 §11 D3 原本选了 Kitura/SwiftMail，实施时改为自研，理由：
/// 1. 我们需要的输入面很窄 —— Mail 递来的已经是**归一化过**的单封邮件
///    （实测 LF 行尾、Exchange 产出），不是任意互联网邮件；
/// 2. 我们需要**字节级控制**：要精确取出 `text/html` 那一段的原始字节，
///    第三方库的序列化/再编码会破坏这一点；
/// 3. 它是 Mail 扩展的一部分，扩展是沙盒 appex，少一个第三方依赖更干净。
///
/// 仍然实现 `MIMEDecoding` 协议，将来要换 SwiftMail 是受控改动。
///
/// 全程在 `[UInt8]` 上操作而不是 `Data` 切片 —— `Data` 的切片会保留原始
/// 索引基准，容易写出"看起来对、越界才炸"的代码。
public struct RFC822MIMEDecoder: MIMEDecoding {

    public init() {}

    public func decode(_ rawMessage: Data) throws -> DecodedEmail {
        let bytes = [UInt8](rawMessage)
        guard !bytes.isEmpty else { throw MIMEDecodingError.emptyMessage }
        guard let root = Self.parsePart(bytes) else { throw MIMEDecodingError.malformedHeaders }

        var accumulator = Accumulator()
        Self.walk(root, depth: 0, into: &accumulator)

        return DecodedEmail(
            html: accumulator.html,
            plainText: accumulator.plainText,
            inlineResources: accumulator.inlineResources,
            structureSummary: accumulator.structureSummary
        )
    }

    // MARK: - 内部状态

    private struct Accumulator {
        var html: String?
        var plainText: String?
        var inlineResources: [String: InlineResource] = [:]
        var structureSummary: [String] = []
    }

    /// 一个已解析出头部与正文字节的 MIME 部分。
    private struct Part {
        var headers: [String: String]   // 名称统一小写
        var body: [UInt8]

        var contentType: (type: String, params: [String: String]) {
            Self.parseContentType(headers["content-type"] ?? "text/plain; charset=us-ascii")
        }

        static func parseContentType(_ raw: String) -> (type: String, params: [String: String]) {
            let pieces = raw.split(separator: ";", omittingEmptySubsequences: false)
            let type = pieces.first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "text/plain"

            var params: [String: String] = [:]
            for piece in pieces.dropFirst() {
                let pair = piece.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { continue }
                let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
                var value = pair[1].trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                params[key] = value
            }
            return (type, params)
        }
    }

    // MARK: - 遍历

    private static func walk(_ part: Part, depth: Int, into accumulator: inout Accumulator) {
        let ct = part.contentType
        let indent = String(repeating: "  ", count: depth)
        let charset = ct.params["charset"] ?? "-"
        accumulator.structureSummary.append(
            "\(indent)\(ct.type)  charset=\(charset)  \(part.body.count) B"
        )

        if ct.type.hasPrefix("multipart/") {
            guard let boundary = ct.params["boundary"] else { return }
            for child in splitMultipart(part.body, boundary: boundary) {
                guard let sub = parsePart(child) else { continue }
                walk(sub, depth: depth + 1, into: &accumulator)
            }
            return
        }

        let decoded = decodeTransferEncoding(part.body, encoding: part.headers["content-transfer-encoding"])

        // 内联资源（cid: 引用的图片）
        if let rawCID = part.headers["content-id"] {
            let cid = rawCID.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))
            if !cid.isEmpty {
                accumulator.inlineResources[cid] = InlineResource(
                    contentID: cid,
                    mimeType: ct.type,
                    data: Data(decoded)
                )
            }
        }

        switch ct.type {
        case "text/html":
            // 空的正文部分等同于"没有" —— 让上层能干净地回退到 text/plain，
            // 而不是拿到一个空字符串还要自己判空。
            if accumulator.html == nil, !decoded.isEmpty {
                accumulator.html = decodeText(decoded, charset: ct.params["charset"])
            }
        case "text/plain":
            if accumulator.plainText == nil, !decoded.isEmpty {
                accumulator.plainText = decodeText(decoded, charset: ct.params["charset"])
            }
        default:
            break
        }
    }

    // MARK: - 头部 / 正文切分

    private static func parsePart(_ bytes: [UInt8]) -> Part? {
        guard let (headerEnd, bodyStart) = headerBodySplit(bytes) else {
            // 没有分隔空行：整段当头部，正文为空（有些最小化的邮件是这样）
            return Part(headers: parseHeaders(Array(bytes)), body: [])
        }
        return Part(headers: parseHeaders(Array(bytes[0..<headerEnd])), body: Array(bytes[bodyStart...]))
    }

    /// 找到头部与正文之间的空行。CRLF 与 LF 都要支持
    /// （RFC 5322 规定 CRLF，但 Mail 实测给的是 LF）。
    private static func headerBodySplit(_ b: [UInt8]) -> (headerEnd: Int, bodyStart: Int)? {
        var i = 0
        while i < b.count {
            if i + 3 < b.count, b[i] == 0x0D, b[i + 1] == 0x0A, b[i + 2] == 0x0D, b[i + 3] == 0x0A {
                return (i, i + 4)
            }
            if i + 1 < b.count, b[i] == 0x0A, b[i + 1] == 0x0A {
                return (i, i + 2)
            }
            i += 1
        }
        return nil
    }

    /// 头部解析统一走 `MIMEHeaders` —— 那份实现踩过 CRLF 与大小写两个坑，
    /// 只保留一处才不会又踩第二次。
    private static func parseHeaders(_ bytes: [UInt8]) -> [String: String] {
        MIMEHeaders.parse(bytes: bytes)
    }

    // MARK: - 分隔 boundary

    private static func splitMultipart(_ body: [UInt8], boundary: String) -> [[UInt8]] {
        let delimiter = Array("--\(boundary)".utf8)
        guard !delimiter.isEmpty else { return [] }

        struct Mark { let lineStart: Int; let afterLine: Int; let isTerminator: Bool }
        var marks: [Mark] = []

        var i = 0
        while i < body.count {
            let atLineStart = (i == 0) || body[i - 1] == 0x0A
            if atLineStart, matches(body, at: i, delimiter) {
                var k = i + delimiter.count
                // 闭合分隔符是 `--boundary--`
                let isTerminator = k + 1 < body.count && body[k] == 0x2D && body[k + 1] == 0x2D
                while k < body.count, body[k] != 0x0A { k += 1 }
                let afterLine = min(k + 1, body.count)
                marks.append(Mark(lineStart: i, afterLine: afterLine, isTerminator: isTerminator))
                i = afterLine
                continue
            }
            i += 1
        }

        guard !marks.isEmpty else { return [] }

        var parts: [[UInt8]] = []
        for (index, mark) in marks.enumerated() {
            guard !mark.isTerminator else { continue }

            let start = mark.afterLine
            var end: Int
            if index + 1 < marks.count {
                end = marks[index + 1].lineStart
                // 去掉分隔行之前那个换行
                if end > start, body[end - 1] == 0x0A { end -= 1 }
                if end > start, body[end - 1] == 0x0D { end -= 1 }
            } else {
                end = body.count
            }

            parts.append(start <= end ? Array(body[start..<end]) : [])
        }
        return parts
    }

    private static func matches(_ haystack: [UInt8], at index: Int, _ needle: [UInt8]) -> Bool {
        guard index + needle.count <= haystack.count else { return false }
        for offset in 0..<needle.count where haystack[index + offset] != needle[offset] {
            return false
        }
        return true
    }

    // MARK: - 传输编码

    private static func decodeTransferEncoding(_ bytes: [UInt8], encoding: String?) -> [UInt8] {
        switch encoding?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64":
            return decodeBase64(bytes)
        case "quoted-printable":
            return decodeQuotedPrintable(bytes)
        default:
            // 7bit / 8bit / binary / 未声明：原样
            return bytes
        }
    }

    private static func decodeBase64(_ bytes: [UInt8]) -> [UInt8] {
        // 去掉空白后再解，避免换行破坏 padding。
        // 用 ignoreUnknownCharacters 容错非法字符（真实邮件里 base64 段常混入垃圾字符）。
        let compact = Data(bytes.filter { !isASCIIWhitespace($0) })
        guard let decoded = Data(base64Encoded: compact, options: .ignoreUnknownCharacters) else {
            return bytes
        }
        return [UInt8](decoded)
    }

    private static func decodeQuotedPrintable(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0

        while i < bytes.count {
            guard bytes[i] == 0x3D else {   // '='
                out.append(bytes[i])
                i += 1
                continue
            }

            // 软换行：`=` 后紧跟 CRLF 或 LF → 整段丢弃
            if i + 1 < bytes.count, bytes[i + 1] == 0x0A {
                i += 2
                continue
            }
            if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A {
                i += 3
                continue
            }

            // `=XX`
            if i + 2 < bytes.count,
               let high = hexValue(bytes[i + 1]),
               let low = hexValue(bytes[i + 2]) {
                out.append(high << 4 | low)
                i += 3
                continue
            }

            out.append(bytes[i])
            i += 1
        }
        return out
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30          // 0-9
        case 0x41...0x46: byte - 0x41 + 10     // A-F
        case 0x61...0x66: byte - 0x61 + 10     // a-f
        default: nil
        }
    }

    // MARK: - 字符集

    static func decodeText(_ bytes: [UInt8], charset: String?) -> String {
        MIMEHeaders.decodeText(Data(bytes), charset: charset ?? "") ?? ""
    }
}
