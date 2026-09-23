import EmailCore
import Foundation
import OSLog
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
/// 把拿到的 session 交给排队的作业。作业的**整个执行过程都在这个闭包内部**，
/// 这样 session 的生命周期由 SwiftUI 保证 —— 不会出现"闭包返回后 session 失效"。
///
/// ## 四个必须守住的细节（前两条都真的踩过）
///
/// 1. **宿主视图必须挂在真实可见窗口的层级里**。放在离屏 window 或没有 window 的
///    视图树里，`onAppear` 不触发、session 拿不到；而且语言包未安装时的系统下载
///    确认弹窗需要一个父窗口才能弹出来。
///
/// 2. **★ 必须复用同一个 `Configuration` 实例反复 `invalidate()`，不能每次新建。**
///
///    这是踩过的最深的坑。`Configuration` 是 `Equatable`，比较里包含 `version`；
///    而 `invalidate()` 只把 version 加一。如果每个作业都
///    `Configuration(source:target:)` **新建**再 `invalidate()`，那么
///    **每个作业拿到的 version 都是 1，配置彼此相等** →
///    SwiftUI 认为配置没变，**不再触发** `.translationTask` →
///    第二个作业永远等不到 session。
///
///    症状极具误导性：**第一次翻译完全正常，之后每次都卡在"翻译中"，
///    直到超时报错**。看起来像"翻译服务变慢了"，其实是根本没去要 session。
///
///    正确做法：持有一个存储的 `Configuration`，每个作业只改 source/target
///    再 `invalidate()`，让 version 在同一个实例上单调递增，保证相邻两次必然不等。
///
/// 3. **超时只能覆盖"等 session"这一段**，绝不能覆盖作业本身。
///    一次翻译会翻几百段、可能要等用户点语言包下载确认，把它纳入超时范围
///    会误杀正常的长任务。
///
/// 4. **同一时刻只借出一个 session**。`TranslationSession` 不支持并发调用。
@MainActor
public final class AppleTranslationSessionBroker: ObservableObject {

    public static let shared = AppleTranslationSessionBroker()

    /// 等待 session 的默认上限。**只**覆盖"取 session"，不覆盖翻译本身。
    public nonisolated static let defaultSessionTimeout: TimeInterval = 20

    /// 由 SwiftUI 观察。变化会触发 `.translationTask` 用新的 session 重新执行。
    @Published var configuration: TranslationSession.Configuration?

    /// ★ 见类型注释第 2 条。
    private var configurationSequencer = TranslationConfigurationSequencer()

    /// 排队等 session 的作业
    private var waiting: [Job] = []
    /// 当前正持有 session 的作业
    private var active: Job?

    private let logger = Logger(subsystem: "com.zhuyuhao.Mailingo", category: "translation-broker")

    private final class Job {
        let source: Locale.Language?
        let target: Locale.Language
        let body: (TranslationSession) async throws -> Void
        let submitOrder: Int

        /// 等 session 的 continuation（受超时约束）
        private var sessionContinuation: CheckedContinuation<Void, Error>?
        /// 等 body 跑完的 continuation（**不**受超时约束）
        private var completionContinuation: CheckedContinuation<Void, Error>?
        /// body 已跑完、调用方还没来取结果时暂存在这里，避免竞态挂死
        private var completedResult: Result<Void, Error>?
        private(set) var isFinished = false

        init(
            source: Locale.Language?,
            target: Locale.Language,
            submitOrder: Int,
            body: @escaping (TranslationSession) async throws -> Void
        ) {
            self.source = source
            self.target = target
            self.submitOrder = submitOrder
            self.body = body
        }

        func waitForSession(_ continuation: CheckedContinuation<Void, Error>) {
            sessionContinuation = continuation
        }

        /// session 到了，解除第一段等待。**不等于作业结束** —— body 还没跑。
        func sessionArrived() {
            sessionContinuation?.resume()
            sessionContinuation = nil
        }

        func awaitCompletion() async throws {
            if let completedResult {
                try completedResult.get()
                return
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                completionContinuation = continuation
            }
        }

        /// 结束作业。幂等 —— continuation 重复 resume 会直接崩。
        func finish(_ result: Result<Void, Error>) {
            guard !isFinished else { return }
            isFinished = true

            // 还在等 session 就被放弃：把那段也解开，别留悬空 continuation
            sessionContinuation?.resume(with: result)
            sessionContinuation = nil

            if let completionContinuation {
                completionContinuation.resume(with: result)
                self.completionContinuation = nil
            } else {
                completedResult = result
            }
        }
    }

    private var nextSubmitOrder = 0

    init() {}

    // MARK: - 供引擎调用

    /// 借出一个 session 执行 `body`，直到 `body` 结束才归还。
    ///
    /// - Parameter sessionTimeout: **只**约束"等 session"这一段。
    ///   `body` 内部可以跑任意久（翻几百段、等用户确认语言包下载）。
    public func run<T>(
        source: Locale.Language?,
        target: Locale.Language,
        sessionTimeout: TimeInterval = AppleTranslationSessionBroker.defaultSessionTimeout,
        body: @escaping (TranslationSession) async throws -> T
    ) async throws -> T {
        let box = ValueBox<T>()
        let job = Job(source: source, target: target, submitOrder: nextSubmitOrder) { session in
            box.value = try await body(session)
        }
        nextSubmitOrder += 1

        try await submit(job, sessionTimeout: sessionTimeout)
        try await job.awaitCompletion()

        guard let value = box.value else {
            throw TranslationEngineError.engineFailed("翻译会话没有返回结果")
        }
        return value
    }

    /// 不需要返回值的版本。
    public func runVoid(
        source: Locale.Language?,
        target: Locale.Language,
        sessionTimeout: TimeInterval = AppleTranslationSessionBroker.defaultSessionTimeout,
        body: @escaping (TranslationSession) async throws -> Void
    ) async throws {
        let job = Job(source: source, target: target, submitOrder: nextSubmitOrder, body: body)
        nextSubmitOrder += 1
        try await submit(job, sessionTimeout: sessionTimeout)
        try await job.awaitCompletion()
    }

    // MARK: - 供 SwiftUI 调用

    /// `.translationTask` 每次都从这里进来。
    func sessionIsReady(_ session: TranslationSession) async {
        guard active == nil, let job = waiting.first else { return }

        waiting.removeFirst()
        active = job

        logger.notice("session 到达（作业 #\(job.submitOrder)），仍在等待 \(self.waiting.count) 个")

        // ① 解除"等 session"的等待 —— 之后 body 跑多久都不再受超时约束
        job.sessionArrived()

        // ② 跑作业。整个执行过程留在闭包内，保证 session 有效。
        do {
            try await job.body(session)
            job.finish(.success(()))
        } catch {
            job.finish(.failure(error))
        }

        active = nil

        // ③ 还有排队的就再要一个 session
        if waiting.isEmpty {
            logger.notice("队列已空")
        } else {
            triggerNextSession()
        }
    }

    /// 视图消失等意外情况下，别让排队的作业永远挂着。
    public func failPendingJobs(reason: String) {
        let error = TranslationEngineError.sessionUnavailable(reason)
        logger.error("放弃所有排队作业：\(reason, privacy: .public)")

        for job in waiting { job.finish(.failure(error)) }
        waiting.removeAll()
        active?.finish(.failure(error))
        active = nil
        configuration = nil
    }

    // MARK: - 私有

    private func submit(_ job: Job, sessionTimeout: TimeInterval) async throws {
        logger.notice("提交作业 #\(job.submitOrder)，当前排队 \(self.waiting.count) 个")

        try await withThrowingTaskGroup(of: Void.self) { group in
            // 排队等 session
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    job.waitForSession(continuation)
                    self.waiting.append(job)
                    if self.active == nil, self.waiting.count == 1 {
                        self.triggerNextSession()
                    }
                }
            }

            // 超时。**只**管这一段等待，作业体不在这个 race 里。
            group.addTask { @MainActor in
                try await Task.sleep(nanoseconds: UInt64(sessionTimeout * 1_000_000_000))
                throw TranslationEngineError.sessionUnavailable(
                    "等待翻译会话超时（\(Int(sessionTimeout)) 秒）。"
                    + "语言包可能未安装，或翻译宿主视图不在可见窗口里。"
                )
            }

            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                abandon(job, error: error)
                throw error
            }
        }
    }

    private func abandon(_ job: Job, error: Error) {
        waiting.removeAll { $0 === job }
        job.finish(.failure(error))
        logger.error("作业 #\(job.submitOrder) 被放弃：\(String(describing: error), privacy: .public)")
    }

    /// ★ 关键：复用同一个 `reusableConfiguration`，只 invalidate()，不新建。
    private func triggerNextSession() {
        guard active == nil, let job = waiting.first else { return }

        let next = configurationSequencer.next(source: job.source, target: job.target)

        logger.notice("请求 session（作业 #\(job.submitOrder)）version=\(next.version)")
        configuration = next
    }

    /// 作业结果的搬运盒。所有访问都在 MainActor 上，不需要加锁。
    private final class ValueBox<T> {
        var value: T?
    }
}

/// 生成用于触发 `.translationTask` 的配置序列。
///
/// 单独抽出来是为了能被单元测试钉住 —— 这个坑很隐蔽（第一次翻译正常、
/// 之后全部超时），回归一次的排查成本远高于留一个测试。
///
/// **必须复用同一个 `Configuration` 实例反复 `invalidate()`。**
/// `Configuration` 的相等性包含 `version`，而 `invalidate()` 只在当前值上加一。
/// 每次新建再 invalidate 的话，每个配置的 version 都是 1、彼此相等，
/// SwiftUI 会认为"配置没变"而**不再触发** `.translationTask`。
struct TranslationConfigurationSequencer {
    private var configuration = TranslationSession.Configuration()

    mutating func next(source: Locale.Language?, target: Locale.Language) -> TranslationSession.Configuration {
        configuration.source = source
        configuration.target = target
        configuration.invalidate()
        return configuration
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
                // 宿主不该参与布局，也不该拦住鼠标事件
                .allowsHitTesting(false)
                .accessibilityHidden(true)
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
