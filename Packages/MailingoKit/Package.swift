// swift-tools-version:6.0
import PackageDescription

/// Mailingo 的核心逻辑。
///
/// 分模块的意义在于让编译器替我们守住边界（见 docs/IMPLEMENTATION_PLAN.md §3.1）：
/// `EmailCore` 只依赖 Foundation —— 不碰 AppKit / SwiftUI / WebKit / 网络 ——
/// 所以它能在没有 Mail、没有权限、没有翻译引擎的情况下被完整测试。
let package = Package(
    name: "MailingoKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "EmailCore", targets: ["EmailCore"]),
        .library(name: "TranslationCore", targets: ["TranslationCore"])
    ],
    targets: [
        .target(name: "EmailCore"),
        .target(name: "TranslationCore", dependencies: ["EmailCore"]),
        .testTarget(
            name: "EmailCoreTests",
            dependencies: ["EmailCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "TranslationCoreTests",
            dependencies: ["TranslationCore", "EmailCore"]
        )
    ],
    // 与 App target 的 SWIFT_VERSION=5.0 保持一致。
    // 迁到 Swift 6 语言模式（严格并发）是独立的一件事，方案 §6 已列为要求，
    // 但不在 M3 范围内 —— 避免和管线实现混在一个改动里，出问题不好定位。
    swiftLanguageModes: [.v5]
)
