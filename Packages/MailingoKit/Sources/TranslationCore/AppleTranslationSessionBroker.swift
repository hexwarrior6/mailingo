import EmailCore
import Foundation
import SwiftUI
import Translation

/// 把 SwiftUI 的 `.translationTask` 桥接成一个普通的 `async` 服务。
///
/// ## 为什么需要这一层
///
/// macOS 15 上 `TranslationSession` **没有公开的构造器** —— 唯一那个
/// `init(installedSource:target:)` 标注的是 macOS 26.0+。想在 AppKit 代码里
/// 直接用 session，只能通过 SwiftUI 的跨导入 overlay：
///
/// ```swift
/// .translationTask(configuration) { session in ... }
/// ```
///
/// 所以这里反过来做：由一个挂在真实窗口里的 1x1 隐藏视图持有 `.translationTask`，
/// 把拿到的 session 交给排队的作业使用。作业的**整个执行过程都在这个闭包内部**，
/// 这样 session 的生命周期由 SwiftUI 保证 —— 不会出现"闭包返回后 session 失效"。
///
/// ## 三个必须守住的细节
///
/// 1. **宿主视图必须挂在真实可见窗口的层级里**。放在离屏 window 或没有 window 的
///    视图树里，`onAppear` 不触发、session 拿不到；而且语言包未安装时的系统下载
///    确认弹窗需要一个父窗口才能弹出来。
/// 2. **每次都要 `configuration.invalidate()`**。`Configuration` 是 `Equatable`
///    且内部带一个 version；用同 source/target 造一个新配置会因为"相等"而
///    **不会**重新触发 `.translationTask`，第二个作业就永远等不到 session。
///    这个坑会表现为"第一段能翻，之后就卡死"。
/// 3. **必须有超时**。宿主的 `.translationTask` 因为任何原因没触发（视图没进窗口、
///    被系统拒绝、弹窗被忽略），作业就会永远挂着，UI 跟着转圈到天荒地老。
@MainActor
public final class AppleTranslationSessionBroker: ObservableObject {

    public static let shared = AppleTranslationSessionBroker()

    /// 等待 session 的默认上限。超过就报错，绝不无限期挂起。
    /// `nonisolated`：它是不可变 Sendable 值，要被用作非隔离上下文的默认参数。
    public nonisolated static let defaultSessionTimeout: TimeInterval = 30

    /// 由 SwiftUI 观察。变化会触发 `.translationTask` 用新的 session 重新执行。
    @Published var configuration: TranslationSession.Configuration?

    private var queue: [Job] = []
    private var isRunning = false

    private final class Job {
        let source: Locale.Language?
        let target: Locale.Language
        let body: (TranslationSession) async throws -> Void

        private var continuation: CheckedContinuation<Void, Error>?
        /// 已经结束（正常完成 / 出错 / 超时放弃）。
        /// 用来保证 continuation 只被 resume 一次 —— 重复 resume 会直接崩。
        private(set) var isFinished = false

        init(
            source: Locale.Language?,
            target: Locale.Language,
            body: @escaping (TranslationSession) async throws -> Void
        ) {
            self.source = source
            self.target = target
            self.body = body
        }

        func attach(_ continuation: CheckedContinuation<Void, Error>) {
            self.continuation = continuation
        }

        /// 结束这个作业。幂等。
        func finish(_ result: Result<Void, Error>) {
            guard !isFinished else { return }
            isFinished = true
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    init() {}

    // MARK: - 供引擎调用

    /// 提交一个需要 session 的作业并等待它完成。作业串行执行：
    /// 同一个 `TranslationSession` 不支持并发调用，而且并发批会让限流和错误处理变复杂。
    public func run<T>(
        source: Locale.Language?,
        target: Locale.Language,
        timeout: TimeInterval = AppleTranslationSessionBroker.defaultSessionTimeout,
        body: @escaping (TranslationSession) async throws -> T
    ) async throws -> T {
        let box = ValueBox<T>()

        try await runVoid(source: source, target: target, timeout: timeout) { session in
            box.value = try await body(session)
        }

        if let value = box.value {
            return value
        }
        throw TranslationEngineError.engineFailed("翻译会话没有返回结果")
    }

    /// 不需要返回值的版本。
    public func runVoid(
        source: Locale.Language?,
        target: Locale.Language,
        timeout: TimeInterval = AppleTranslationSessionBroker.defaultSessionTimeout,
        body: @escaping (TranslationSession) async throws -> Void
    ) async throws {
        let job = Job(source: source, target: target, body: body)

        // 把「排队等 session」和「超时」赛跑。
        // 不能靠 group.cancelAll() 收尾 —— 取消不会 resume continuation，
        // 必须显式把作业 finish 掉。
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    job.attach(continuation)
                    self.queue.append(job)
                    if !self.isRunning { self.startNext() }
                }
            }

            group.addTask { @MainActor in
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw TranslationEngineError.sessionUnavailable(
                    "等待翻译会话超时（\(Int(timeout)) 秒）。语言包可能未安装，或翻译窗口不在前台。"
                )
            }

            do {
                try await group.next()
                group.cancelAll()
                // 正常路径：sessionIsReady 已经 resume 过 continuation
            } catch {
                group.cancelAll()
                // 超时 / 取消：摘掉作业并显式结束，别让它稍后又跑起来
                abandon(job, error: error)
                throw error
            }
        }
    }

    // MARK: - 供 SwiftUI 调用

    /// `.translationTask` 每次都从这里进来。
    func sessionIsReady(_ session: TranslationSession) async {
        guard let job = queue.first else { return }

        // 已经被超时放弃的作业不要再执行
        guard !job.isFinished else {
            queue.removeFirst()
            startNext()
            return
        }

        do {
            try await job.body(session)
            job.finish(.success(()))
        } catch {
            job.finish(.failure(error))
        }

        queue.removeFirst()
        startNext()
    }

    /// 视图消失等意外情况下，别让排队的作业永远挂着。
    public func failPendingJobs(reason: String) {
        let error = TranslationEngineError.sessionUnavailable(reason)
        for job in queue {
            job.finish(.failure(error))
        }
        queue.removeAll()
        isRunning = false
        configuration = nil
    }

    // MARK: - 私有

    private func abandon(_ job: Job, error: Error) {
        queue.removeAll { $0 === job }
        job.finish(.failure(error))
        if queue.isEmpty {
            isRunning = false
        }
    }

    private func startNext() {
        guard !queue.isEmpty else {
            isRunning = false
            return
        }
        isRunning = true

        let job = queue[0]
        var config = TranslationSession.Configuration(source: job.source, target: job.target)
        // ★ 见类型注释第 2 条：不 invalidate 的话同语言对的第二个作业不会被触发。
        config.invalidate()
        configuration = config
    }

    /// 作业结果的搬运盒。所有访问都在 MainActor 上（`run` 与 translationTask
    /// 闭包都在主 actor），所以不需要额外加锁。
    private final class ValueBox<T> {
        var value: T?
    }
}

// MARK: - SwiftUI 宿主

/// 1x1 的隐藏宿主。它存在的唯一意义是持有 `.translationTask`。
struct AppleTranslationTaskHost: View {

    @ObservedObject var broker: AppleTranslationSessionBroker

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(broker.configuration) { session in
                await broker.sessionIsReady(session)
            }
    }
}

private struct AppleTranslationHostModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            AppleTranslationTaskHost(broker: .shared)
        }
    }
}

public extension View {
    /// 把 Apple Translation 的隐藏宿主挂进视图树。
    ///
    /// **必须挂在真实可见窗口里**（见 `AppleTranslationSessionBroker` 的说明）——
    /// 所以调用点是 App 的根视图，而不是某个不可见的地方。
    func appleTranslationHost() -> some View {
        modifier(AppleTranslationHostModifier())
    }
}
