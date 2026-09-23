import CoreFoundation
import Foundation

/// MIME 头部解析与 RFC 2047 编码词解码。
///
/// ## 为什么单独成一个类型
///
/// 这份逻辑原先散在两个地方（MIME 解码器一份、appex 提取邮件元数据一份），
/// 而且**两处都踩过同样的坑**。合并成一份之后：只有一处需要修，也能被单测覆盖。
///
/// ## 两个真实踩过的坑
///
/// 1. **行尾**：`components(separatedBy: .newlines)` 会把 CRLF 拆成两个分隔符，
///    中间多出空串，导致"读到空行就结束"的逻辑在第一行后就退出；
///    而 `split(separator: "\n")` 更糟 —— **在 Swift 里 `"\r\n"` 是单个 Character**，
///    它完全不在 CRLF 处切分。必须用 `split(whereSeparator: \.isNewline)`。
/// 2. **大小写**：头部名比较必须两边都小写。曾写成
///    `line.lowercased().hasPrefix(key + ":")` —— 左边小写右边原始大小写，
///    于是永远不匹配，症状是"所有头部都读不到"。
public enum MIMEHeaders {

    /// 头部区可能有多长。
    ///
    /// Exchange / Office365 的头部区相当大（实测一封通知有 152 行，
    /// `From` 都在第 40 行往后），所以默认给 64KB，不要抠 8KB。
    public static let defaultLimit = 65536

    // MARK: - 解析

    public static func parse(_ rawMessage: Data, limit: Int = defaultLimit) -> [String: String] {
        parse(bytes: [UInt8](rawMessage.prefix(limit)))
    }

    /// 从字节解析。返回「小写头部名 → 值」，折行已拼接。
    public static func parse(bytes: [UInt8], limit: Int = defaultLimit) -> [String: String] {
        let slice = bytes.count > limit ? Array(bytes[0..<limit]) : bytes
        guard let text = String(bytes: slice, encoding: .utf8)
            ?? String(bytes: slice, encoding: .isoLatin1) else {
            return [:]
        }
        return parse(text: text)
    }

    public static func parse(text: String) -> [String: String] {
        var headers: [String: String] = [:]
        var currentName: String?
        var currentValue = ""

        func flush() {
            if let name = currentName {
                headers[name] = currentValue.trimmingCharacters(in: .whitespaces)
            }
            currentName = nil
            currentValue = ""
        }

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { break }   // 头部与正文的分界

            // 折行续行：以空白开头，接到上一个头部
            if let first = rawLine.first, first == " " || first == "\t" {
                currentValue += " " + line
                continue
            }

            flush()

            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            guard !name.isEmpty else { continue }
            currentName = name
            currentValue = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        flush()

        return headers
    }

    /// 取头部值。头部名大小写不敏感（解析时已统一小写，这里再兜一层）。
    public static func value(_ name: String, in headers: [String: String]) -> String? {
        headers[name.lowercased()]
    }

    // MARK: - RFC 2047 编码词

    /// 解码 `=?utf-8?B?...?=` / `=?gb2312?Q?...?=` 这类编码词。
    ///
    /// 主题与发件人里的非 ASCII 内容几乎都是这种形式；不解码的话，
    /// UI 里列出来的邮件标题会是一串天书。
    public static func decodeRFC2047(_ text: String) -> String {
        guard text.contains("=?") else { return text }

        var result = ""
        var rest = Substring(text)
        var previousWasEncodedWord = false

        while let start = rest.range(of: "=?") {
            let gap = rest[rest.startIndex..<start.lowerBound]

            // RFC 2047 §6.2：**相邻编码词之间的线性空白要忽略**。
            //   `=?utf-8?B?5L2g?= =?utf-8?B?5aW9?=` 应当是「你好」而不是「你 好」。
            // 只处理"紧跟在编码词之后"的纯空白；编码词前后的普通文本空格照常保留。
            if !(previousWasEncodedWord && gap.allSatisfy(\.isWhitespace)) {
                result += gap
            }

            guard let decoded = decodeEncodedWord(in: rest, startingAt: start.lowerBound) else {
                // 不是合法编码词（或不认识的 encoding）：原样保留剩余内容，
                // 绝不能把用户能看到的文本吃掉。
                result += rest[start.lowerBound...]
                return result
            }

            result += decoded.text
            rest = rest[decoded.end...]
            previousWasEncodedWord = true
        }

        result += rest
        return result
    }

    /// 尝试解析 `start` 处开始的编码词。
    /// - Returns: 解出的文本，以及编码词结束后的位置；不合法时返回 nil。
    private static func decodeEncodedWord(
        in text: Substring,
        startingAt start: Substring.Index
    ) -> (text: String, end: Substring.Index)? {
        let afterStart = text[text.index(start, offsetBy: 2)...]

        // 结构：charset?encoding?encoded-text?=
        guard let firstQuestion = afterStart.firstIndex(of: "?") else { return nil }
        let afterFirst = afterStart.index(after: firstQuestion)
        guard afterFirst < afterStart.endIndex,
              let secondQuestion = afterStart[afterFirst...].firstIndex(of: "?") else { return nil }

        let charset = String(afterStart[afterStart.startIndex..<firstQuestion])
        let encoding = afterStart[afterFirst]
        let encodedStart = afterStart.index(after: secondQuestion)

        guard let end = afterStart.range(of: "?=", range: encodedStart..<afterStart.endIndex) else {
            return nil
        }

        let encoded = String(afterStart[encodedStart..<end.lowerBound])
        guard let decoded = decodeWord(encoded, charset: charset, encoding: encoding) else {
            return nil
        }
        return (decoded, end.upperBound)
    }

    /// - Returns: 解出的文本；encoding 不认识或解码失败时返回 nil（上层会原样保留）。
    private static func decodeWord(_ encoded: String, charset: String, encoding: Character) -> String? {
        let bytes: Data?
        switch Character(encoding.uppercased()) {
        case "B":
            bytes = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
        case "Q":
            bytes = decodeQuotedPrintableWord(encoded)
        default:
            return nil
        }

        guard let bytes, let text = decodeText(bytes, charset: charset) else { return nil }
        return text
    }

    /// Q 编码里 `_` 代表空格，`=XX` 是十六进制字节。
    private static func decodeQuotedPrintableWord(_ text: String) -> Data {
        var out = Data()
        let chars = Array(text.utf8)
        var index = 0

        while index < chars.count {
            let byte = chars[index]
            if byte == 0x5F {                     // '_' → 空格
                out.append(0x20)
                index += 1
            } else if byte == 0x3D, index + 2 < chars.count,
                      let high = hexValue(chars[index + 1]), let low = hexValue(chars[index + 2]) {
                out.append(high << 4 | low)
                index += 3
            } else {
                out.append(byte)
                index += 1
            }
        }
        return out
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }

    /// 按 IANA charset 名解码文本。
    static func decodeText(_ data: Data, charset: String) -> String? {
        let name = charset.trimmingCharacters(in: .whitespaces).lowercased()
        if !name.isEmpty,
           let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString) as CFStringEncoding?,
           cfEncoding != kCFStringEncodingInvalidId {
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            if let text = String(data: data, encoding: String.Encoding(rawValue: nsEncoding)) {
                return text
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}
