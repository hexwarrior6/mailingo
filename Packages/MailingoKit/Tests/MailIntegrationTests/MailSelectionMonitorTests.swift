import EmailCore
import XCTest

@testable import MailIntegration

/// 解析 Mail 返回的选中邮件信息。
///
/// 这些是纯逻辑：脚本真正执行要 Mail 在跑、还要有「自动化」授权，
/// 不适合放进自动化测试；但**返回值怎么解析**必须钉住 ——
/// 它是"跟随 Mail 自动切换"能否对上号的关键。
final class MailSelectionMonitorTests: XCTestCase {

    private let separator = "\u{1F}"   // 脚本用的分隔符

    // MARK: - 正常返回

    func testParsesSelection() throws {
        let selection = try MailSelectionMonitor.parse("OK\(separator)<abc@example.com>\(separator)4211")

        XCTAssertEqual(selection.internetMessageID, "abc@example.com")
        XCTAssertEqual(selection.mailMessageID, 4211)
    }

    /// 尖括号必须被去掉 —— 我们存的是原始头部值，格式未必和 Mail 返回的一致。
    func testStripsAngleBrackets() throws {
        let selection = try MailSelectionMonitor.parse("OK\(separator)  <xyz@host>  \(separator)7")
        XCTAssertEqual(selection.internetMessageID, "xyz@host")
    }

    /// Mail 给不出数字 id 时要能容忍。
    func testToleratesMissingNumericID() throws {
        let selection = try MailSelectionMonitor.parse("OK\(separator)<a@b>\(separator)")
        XCTAssertEqual(selection.internetMessageID, "a@b")
        XCTAssertNil(selection.mailMessageID)
    }

    // MARK: - "现在没得可跟"的几种情况

    func testNoViewer() {
        XCTAssertThrowsError(try MailSelectionMonitor.parse("NOVIEWER")) { error in
            XCTAssertEqual(error as? MailSelectionError, .noViewer)
        }
    }

    func testNoSelection() {
        XCTAssertThrowsError(try MailSelectionMonitor.parse("NOSELECTION")) { error in
            XCTAssertEqual(error as? MailSelectionError, .noSelection)
        }
    }

    func testEmptyReturnIsNoViewer() {
        XCTAssertThrowsError(try MailSelectionMonitor.parse(""))
    }

    /// Message-ID 为空的邮件（草稿等）没法对上号，按"没选中"处理，
    /// 而不是拿一个空字符串去匹配所有邮件。
    func testEmptyMessageIDIsTreatedAsNoSelection() {
        XCTAssertThrowsError(try MailSelectionMonitor.parse("OK\(separator)\(separator)99")) { error in
            XCTAssertEqual(error as? MailSelectionError, .noSelection)
        }
    }

    func testGarbageIsScriptFailure() {
        XCTAssertThrowsError(try MailSelectionMonitor.parse("something unexpected")) { error in
            guard case .scriptFailed = (error as? MailSelectionError) else {
                return XCTFail("应当是 scriptFailed，实际是 \(error)")
            }
        }
    }

    // MARK: - 哪些算"错误"，哪些算"安静跳过"

    /// 这三种是正常的瞬时状态（Mail 没开、没有阅读窗口、没选中），
    /// 不该弹错误给用户。
    func testTransientErrorsAreMarked() {
        XCTAssertTrue(MailSelectionError.noViewer.isTransient)
        XCTAssertTrue(MailSelectionError.noSelection.isTransient)
        XCTAssertTrue(MailSelectionError.mailNotRunning.isTransient)
    }

    /// 权限被拒是**要告诉用户**的，不能安静跳过 —— 否则开关打开了却毫无反应。
    func testDeniedPermissionIsNotTransient() {
        XCTAssertFalse(MailSelectionError.automationDenied.isTransient)
        XCTAssertFalse(MailSelectionError.scriptFailed(code: 1, message: "x").isTransient)
    }

    // MARK: - Message-ID 归一化

    func testNormalizeMessageID() {
        XCTAssertEqual(MIMEHeaders.normalizeMessageID("<a@b>"), "a@b")
        XCTAssertEqual(MIMEHeaders.normalizeMessageID("  <a@b>  "), "a@b")
        XCTAssertEqual(MIMEHeaders.normalizeMessageID("a@b"), "a@b")
        XCTAssertEqual(MIMEHeaders.normalizeMessageID("<>"), "")
        XCTAssertEqual(MIMEHeaders.normalizeMessageID(""), "")
    }

    /// 两边格式不同也要能对上号 —— 这是"跟随 Mail"能找到对应邮件的关键。
    func testNormalizedComparisonMatchesAcrossFormats() {
        let fromMail = MIMEHeaders.normalizeMessageID("<SG2PR01MB4097@apcprd01.prod.exchangelabs.com>")
        let fromStore = MIMEHeaders.normalizeMessageID("SG2PR01MB4097@apcprd01.prod.exchangelabs.com")
        XCTAssertEqual(fromMail, fromStore)
    }
}
