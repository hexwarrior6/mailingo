import EmailCore
import Foundation
import NaturalLanguage
import Translation

/// 源语言检测。
///
/// 用 `NLLanguageRecognizer`（NaturalLanguage）而不是让翻译引擎自己判断：
/// 本地、免费、无权限、快，而且**我们**能拿到检测结果用于缓存 key 和 UI 提示。
public enum LanguageDetector {

    /// 低于这个置信度就不下结论，返回 nil 交给引擎自己检测 ——
    /// 猜错源语言比不猜更糟（会翻出莫名其妙的语言）。
    private static let minimumConfidence = 0.35

    /// 采样上限。标题、按钮这类短文本用 NLLanguageRecognizer 判定极不稳定
    /// （"OK" 几乎可以是任何语言），所以拼多段、给足样本。
    private static let sampleLimit = 2000

    /// 从一组片段里检测源语言。
    public static func detect(in segments: [TranslationSegment]) -> Locale.Language? {
        var sample = ""
        for segment in segments {
            sample += segment.sourceText
            sample += "\n"
            if sample.count >= sampleLimit { break }
        }

        // 样本太短就别猜了
        guard sample.count >= 12 else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)

        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        guard let (language, confidence) = hypotheses.first,
              confidence >= minimumConfidence else {
            return nil
        }

        return Locale.Language(identifier: language.rawValue)
    }

    /// 纯文本版本，给测试和调试用。
    public static func detect(inText text: String) -> Locale.Language? {
        guard text.count >= 12 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        guard let (language, confidence) = hypotheses.first,
              confidence >= minimumConfidence else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }
}

/// 语言相关的常量与便利。
public enum TranslationLanguages {
    /// 默认目标语言（PRODUCT.md §7）。用户可以在翻译菜单里换成别的。
    public static let simplifiedChinese = Locale.Language(identifier: "zh-Hans")

    /// 系统翻译支持的全部语言，按显示名（中文 locale）排序。
    ///
    /// 翻译菜单和设置面板的语言清单都从这来。注意"支持"≠"已安装"：
    /// 装没装要看 `LanguageAvailability.status(from:to:)`（设置面板逐行显示）。
    /// 标识符是系统自己的写法（比如 `zh`、`zh-TW`、`en-GB`），调用方要拿
    /// 存储的选中值与这份清单对齐，不能假设清单里一定有 `zh-Hans`。
    public static func supported() async -> [Locale.Language] {
        let languages = await LanguageAvailability().supportedLanguages
        return languages.sorted { displayName(for: $0) < displayName(for: $1) }
    }

    /// 把语言显示成人类可读的名字，用于 UI。
    public static func displayName(for language: Locale.Language, locale: Locale = Locale(identifier: "zh-Hans")) -> String {
        locale.localizedString(forIdentifier: language.minimalIdentifier)
            ?? language.minimalIdentifier
    }
}
