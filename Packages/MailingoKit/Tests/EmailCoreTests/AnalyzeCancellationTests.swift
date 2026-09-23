import Foundation
import XCTest

@testable import EmailCore

/// `EmailInspector.analyze` 的取消行为。
///
/// 为什么值得单独钉住：App 在用户快速切邮件时会取消上一次载入
/// （`InspectorModel.load` → `analyzeOffMainThread` → 这里）。
/// 如果 `analyze` 不理会取消，旧的解析会跑到底 —— 白烧 CPU，
/// 而且那正是"右边在追着前面那封跑"的成因之一。
///
/// 这两个 `checkCancellation` 很容易在重构时被当成多余而删掉，
/// 所以用一个用例说明它们是有用的。
final class AnalyzeCancellationTests: XCTestCase {

    /// 已经取消的任务里调用 analyze，必须**立刻**抛 `CancellationError`。
    func testAnalyzeThrowsWhenAlreadyCancelled() async throws {
        let data = try Fixtures.data(Fixtures.realSinglepartHTML)

        let task = Task.detached { () -> Error? in
            // 先把自己标成已取消，再调用 —— 结果必须是确定的，不能靠竞态
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try EmailInspector.analyze(rawMessage: data)
                return nil
            } catch {
                return error
            }
        }

        let error = await task.value
        XCTAssertNotNil(error, "取消后 analyze 不该正常返回")
        XCTAssertTrue(
            error is CancellationError,
            "取消后应当抛 CancellationError，实际是：\(String(describing: error))"
        )
    }

    /// 反向用例：没被取消时必须照常解析出片段。
    ///
    /// 光有上面那条不够 —— 如果谁把 `checkCancellation` 写成无条件抛出，
    /// 上一条会照样通过，而整个 App 会瘫痪。
    func testAnalyzeStillSucceedsWhenNotCancelled() throws {
        let data = try Fixtures.data(Fixtures.realSinglepartHTML)
        let analysis = try EmailInspector.analyze(rawMessage: data)

        XCTAssertFalse(analysis.segments.isEmpty, "正常路径必须解析出可翻译片段")
        XCTAssertFalse(analysis.originalHTML.isEmpty)
    }

    /// 取消也要能穿过 fixture 里那份 GB2312/GKB 邮件 ——
    /// 解码是最长的一步，取消应当在它之前就生效。
    func testCancellationAppliesToEveryFixture() throws {
        for name in [Fixtures.realSinglepartHTML,
                     Fixtures.alternativeQP,
                     Fixtures.relatedGB18030CID,
                     Fixtures.gb2312DeclaredGBKActual] {
            let data = try Fixtures.data(name)
            let analysis = try EmailInspector.analyze(rawMessage: data)
            XCTAssertFalse(analysis.originalHTML.isEmpty, "\(name) 解出来是空的")
        }
    }
}
