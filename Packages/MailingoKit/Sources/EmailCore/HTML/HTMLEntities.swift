import Foundation

/// HTML 实体的解码 / 转义。
///
/// 为什么必须成对处理：翻译引擎吃的是**解码后**的纯文本（`&amp;` → `&`），
/// 而写回 HTML 时必须重新转义，否则 `&` `<` `>` 会破坏结构。
enum HTMLEntities {

    // MARK: - 解码

    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }

        var result = ""
        result.reserveCapacity(text.count)
        var i = text.startIndex

        while i < text.endIndex {
            guard text[i] == "&" else {
                result.append(text[i])
                i = text.index(after: i)
                continue
            }

            // 实体最长也就 ~10 字符，超出就直接当普通字符
            let searchEnd = text.index(i, offsetBy: 32, limitedBy: text.endIndex) ?? text.endIndex
            guard let semi = text[i..<searchEnd].firstIndex(of: ";") else {
                result.append("&")
                i = text.index(after: i)
                continue
            }

            let body = text[text.index(after: i)..<semi]
            if let decoded = resolve(String(body)) {
                result.append(decoded)
                i = text.index(after: semi)
            } else {
                // 不认识就原样保留，别擅自改写
                result.append(contentsOf: text[i...semi])
                i = text.index(after: semi)
            }
        }
        return result
    }

    private static func resolve(_ body: String) -> String? {
        guard !body.isEmpty else { return nil }

        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let scalarValue: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                scalarValue = UInt32(digits.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(digits)
            }
            guard let value = scalarValue, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }

        guard let scalar = named[body] else { return nil }
        return String(scalar)
    }

    // MARK: - 转义

    /// 转义文本节点里必须转义的字符，并把不换行空格写回 `&nbsp;`
    /// （直接留 U+00A0 也能渲染，但写回实体更贴近原邮件的写法，diff 更干净）。
    static func escapeText(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\u{00A0}": result += "&nbsp;"
            default: result.append(ch)
            }
        }
        return result
    }

    // MARK: - 常用命名实体

    private static let named: [String: Unicode.Scalar] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}",
        "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}",
        "hellip": "\u{2026}", "mdash": "\u{2014}", "ndash": "\u{2013}", "minus": "\u{2212}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "laquo": "\u{00AB}", "raquo": "\u{00BB}", "lsaquo": "\u{2039}", "rsaquo": "\u{203A}",
        "bull": "\u{2022}", "middot": "\u{00B7}", "dagger": "\u{2020}", "Dagger": "\u{2021}",
        "sect": "\u{00A7}", "para": "\u{00B6}", "permil": "\u{2030}", "prime": "\u{2032}",
        "deg": "\u{00B0}", "plusmn": "\u{00B1}", "times": "\u{00D7}", "divide": "\u{00F7}",
        "frac12": "\u{00BD}", "frac14": "\u{00BC}", "frac34": "\u{00BE}",
        "sup2": "\u{00B2}", "sup3": "\u{00B3}", "micro": "\u{00B5}",
        "euro": "\u{20AC}", "pound": "\u{00A3}", "yen": "\u{00A5}", "cent": "\u{00A2}",
        "curren": "\u{00A4}", "brvbar": "\u{00A6}",
        "larr": "\u{2190}", "uarr": "\u{2191}", "rarr": "\u{2192}", "darr": "\u{2193}",
        "harr": "\u{2194}", "crarr": "\u{21B5}", "there4": "\u{2234}",
        "spades": "\u{2660}", "clubs": "\u{2663}", "hearts": "\u{2665}", "diams": "\u{2666}",
        "star": "\u{2606}", "starf": "\u{2605}", "check": "\u{2713}", "cross": "\u{2717}",
        "alpha": "\u{03B1}", "beta": "\u{03B2}", "gamma": "\u{03B3}", "delta": "\u{03B4}",
        "epsilon": "\u{03B5}", "theta": "\u{03B8}", "lambda": "\u{03BB}", "mu": "\u{03BC}",
        "pi": "\u{03C0}", "sigma": "\u{03C3}", "phi": "\u{03C6}", "omega": "\u{03C9}",
        "Alpha": "\u{0391}", "Beta": "\u{0392}", "Gamma": "\u{0393}", "Delta": "\u{0394}",
        "Theta": "\u{0398}", "Lambda": "\u{039B}", "Pi": "\u{03A0}", "Sigma": "\u{03A3}",
        "Phi": "\u{03A6}", "Omega": "\u{03A9}",
        "iexcl": "\u{00A1}", "iquest": "\u{00BF}",
        "agrave": "\u{00E0}", "aacute": "\u{00E1}", "acirc": "\u{00E2}", "atilde": "\u{00E3}",
        "auml": "\u{00E4}", "aring": "\u{00E5}", "aelig": "\u{00E6}", "ccedil": "\u{00E7}",
        "egrave": "\u{00E8}", "eacute": "\u{00E9}", "ecirc": "\u{00EA}", "euml": "\u{00EB}",
        "igrave": "\u{00EC}", "iacute": "\u{00ED}", "icirc": "\u{00EE}", "iuml": "\u{00EF}",
        "ntilde": "\u{00F1}", "ograve": "\u{00F2}", "oacute": "\u{00F3}", "ocirc": "\u{00F4}",
        "otilde": "\u{00F5}", "ouml": "\u{00F6}", "oslash": "\u{00F8}",
        "ugrave": "\u{00F9}", "uacute": "\u{00FA}", "ucirc": "\u{00FB}", "uuml": "\u{00FC}",
        "yacute": "\u{00FD}", "yuml": "\u{00FF}", "szlig": "\u{00DF}",
        "Agrave": "\u{00C0}", "Aacute": "\u{00C1}", "Auml": "\u{00C4}", "Ccedil": "\u{00C7}",
        "Eacute": "\u{00C9}", "Euml": "\u{00CB}", "Iuml": "\u{00CF}", "Ntilde": "\u{00D1}",
        "Ouml": "\u{00D6}", "Oslash": "\u{00D8}", "Uuml": "\u{00DC}"
    ]
}
