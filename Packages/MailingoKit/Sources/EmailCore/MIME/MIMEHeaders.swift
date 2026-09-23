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

    /// 归一化 Message-ID：去掉尖括号与首尾空白。
    ///
    /// 比较 Message-ID 时必须先过一遍：Mail 的 AppleScript 返回 `<xxx@yyy>`，
    /// 而我们存的是原始头部值，两边格式未必一致。
    public static func normalizeMessageID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
    ///
    /// **顺序很关键**：先按声明的 charset 严格解，只有解不出来才退到同族的超集。
    /// 这样本来能解的邮件行为完全不变，只有原本就会变成乱码的邮件才受影响。
    ///
    /// ## 为什么需要超集这一步（实测，2026-09-24，真实邮件）
    ///
    /// 一封邮件声明 `charset="gb2312"`，2260 字节的正文里却有**一个** GBK 才有的
    /// 字节序列 `A8 43`（GB18030 解作「–」）。而 `String(data:encoding:)` 是
    /// **全有或全无**的：这一个字节让整段正文返回 nil，于是掉进 Latin-1 兜底，
    /// 整篇中文变成「Èñ½ÝÍøÂç」这样的乱码 —— 实测 6 封真实邮件中招。
    ///
    /// "声明 gb2312、实际发 GBK" 在中文邮件里极其常见，因为 GB2312 是 GBK 的子集，
    /// 而几乎所有邮件客户端都按 GBK/GB18030 编码。所以 gb2312/gbk 一律退到
    /// gb18030 —— 它是 GBK 的**严格超集**，同一字节序列的解读不存在歧义。
    static func decodeText(_ data: Data, charset: String) -> String? {
        let name = charset.trimmingCharacters(in: .whitespaces).lowercased()

        // ① 按声明的 charset 严格解
        if let text = strictDecode(data, ianaName: name) { return text }

        // ② 解不出来才退到同族超集
        for superset in supersets(for: name) {
            if let text = strictDecode(data, ianaName: superset) { return text }
        }

        // ③ 最后兜底：UTF-8，再不行按 Latin-1（它永不失败，因此是终点）
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    /// 严格解码：认不出 charset 名、或字节里有该编码不接受的内容，都返回 nil。
    private static func strictDecode(_ data: Data, ianaName: String) -> String? {
        guard !ianaName.isEmpty else { return nil }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(ianaName as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        return String(data: data, encoding: String.Encoding(rawValue: nsEncoding))
    }

    /// 某个 charset 解不出来时可以尝试的同族超集。
    ///
    /// 只列**严格超集**（老编码能表示的，超集都能表示，且解读一致）。
    /// 故意不收 shift_jis → windows-31j：CP932 虽然覆盖面更大，但对少数码位的
    /// 映射与 JIS X 0208 不同，会对**本来解得好好的**邮件悄悄改字。
    private static func supersets(for name: String) -> [String] {
        switch name {
        case "gb2312", "gbk", "gb_2312", "gb_2312-80", "csgb2312", "euc-cn", "x-gbk", "chinese":
            return ["gb18030"]
        case "big5", "csbig5", "big-5":
            return ["big5-hkscs"]
        case "euc-kr", "cseuckr":
            return ["windows-949"]
        default:
            return []
        }
    }
}
