import XCTest
@testable import CodexStatusCore

final class PromptTemplatesTests: XCTestCase {
    func testParsesTitlesBodiesAndProjectScope() {
        let text = """
        # 说明会被忽略
        ## 先读后改
        请先阅读代码。
        再给计划。

        ## 项目背景 @my-app
        这是 my-app。
        """
        XCTAssertEqual(parsePromptTemplates(text), [
            .init(title: "先读后改", body: "请先阅读代码。\n再给计划。", project: nil),
            .init(title: "项目背景", body: "这是 my-app。", project: "my-app")
        ])
    }

    func testSkipsEmptyBodiesAndEmptyTitlesAndTextBeforeFirstHeading() {
        let text = "无标题的文字\n## 空模板\n\n## \n有内容但没标题\n## 好的\n内容"
        XCTAssertEqual(parsePromptTemplates(text).map(\.title), ["好的"])
    }

    func testAtSignInsideTitleWithSpacesIsNotAProject() {
        let result = parsePromptTemplates("## 发邮件 @ 老板 看\n正文")
        XCTAssertEqual(result.first?.project, nil)
        XCTAssertEqual(result.first?.title, "发邮件 @ 老板 看")
    }

    func testLimitsCountAndLength() {
        let many = (0..<80).map { "## t\($0)\nbody" }.joined(separator: "\n")
        XCTAssertEqual(parsePromptTemplates(many, limit: 50).count, 50)
        let long = "## 长\n" + String(repeating: "字", count: 30_000)
        XCTAssertEqual(parsePromptTemplates(long).first?.body.count, 20_000)
    }

    func testDefaultTextHasCommonAndMoreTiers() {
        let templates = parsePromptTemplates(defaultPromptTemplateText)
        XCTAssertEqual(templates.count, 18)
        XCTAssertTrue(templates.allSatisfy { $0.project == nil })
        XCTAssertEqual(templates.filter { !$0.isMore }.count, 9)
        XCTAssertEqual(templates.first?.title, "开局约定")
        XCTAssertTrue(templates.first { $0.title == "先写测试" }?.isMore == true)
    }

    func testMoreMarkerSplitsTiersAndIsNotATemplate() {
        let result = parsePromptTemplates("## 甲\n内容\n## 更多\n## 乙\n内容")
        XCTAssertEqual(result.map(\.title), ["甲", "乙"])
        XCTAssertEqual(result.map(\.isMore), [false, true])
    }

    func testExpandReplacesAllVariablesInOnePass() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let day = DailyStats.dayKey(now)
        let out = expandTemplate("在 {项目} 修：{剪贴板}（{日期}）", project: "app", clipboard: "报错 {项目}", now: now)
        XCTAssertEqual(out.text, "在 app 修：报错 {项目}（\(day)）")
        XCTAssertTrue(out.unresolved.isEmpty)
    }

    func testExpandLeavesMissingValuesVisible() {
        let out = expandTemplate("{项目} {剪贴板} {剪贴板}", project: nil, clipboard: "  \n", now: Date())
        XCTAssertEqual(out.text, "{项目} {剪贴板} {剪贴板}")
        XCTAssertEqual(out.unresolved, ["{项目}", "{剪贴板}"])
        XCTAssertEqual(expandTemplate("无变量", project: nil, clipboard: nil, now: Date()).text, "无变量")
        XCTAssertEqual(expandTemplate("{未知}", project: "a", clipboard: nil, now: Date()).text, "{未知}")
    }

    func testInsertGoesBeforeMoreMarkerOrAtEnd() {
        let withMarker = insertingTemplate(into: "## 甲\n内容\n\n## 更多\n\n## 乙\n内容\n", title: "新", body: "新内容")!
        XCTAssertEqual(parsePromptTemplates(withMarker).map(\.title), ["甲", "新", "乙"])
        XCTAssertEqual(parsePromptTemplates(withMarker).map(\.isMore), [false, false, true])
        let plain = insertingTemplate(into: "## 甲\n内容\n", title: "## 新", body: "新内容")!
        XCTAssertEqual(parsePromptTemplates(plain).map(\.title), ["甲", "新"])
    }

    func testInsertRejectsBadInputAndNeutralisesHeadingsInBody() {
        XCTAssertNil(insertingTemplate(into: "", title: "  ", body: "x"))
        XCTAssertNil(insertingTemplate(into: "", title: "更多", body: "x"))
        XCTAssertNil(insertingTemplate(into: "", title: "t", body: " \n "))
        let text = insertingTemplate(into: "## 甲\n内容\n", title: "新", body: "第一行\n## 假标题\n第三行")!
        XCTAssertEqual(parsePromptTemplates(text).map(\.title), ["甲", "新"])
    }

    func testShortFinishedTasksAreFilteredButWaitingAlwaysNotifies() {
        func event(_ kind: StatusEvent.Kind, _ duration: TimeInterval?) -> StatusEvent {
            .init(kind: kind, sessionID: "a", title: "t", project: nil, occurredAt: Date(), duration: duration)
        }
        XCTAssertFalse(event(.finished, 5).shouldNotify(minimumDuration: 30))
        XCTAssertTrue(event(.finished, 30).shouldNotify(minimumDuration: 30))
        XCTAssertTrue(event(.finished, nil).shouldNotify(minimumDuration: 30))
        XCTAssertTrue(event(.needsInput, 1).shouldNotify(minimumDuration: 300))
        XCTAssertTrue(event(.finished, 1).shouldNotify(minimumDuration: 0))
    }
}

final class EnglishTemplateSyntaxTests: XCTestCase {
    func testMoreMarkerAcceptsEnglishInAnyCase() {
        for marker in ["## 更多", "## More", "## more", "## MORE"] {
            let result = parsePromptTemplates("## A\nbody\n\(marker)\n## B\nbody")
            XCTAssertEqual(result.map(\.isMore), [false, true], marker)
            XCTAssertEqual(result.map(\.title), ["A", "B"], marker)
        }
    }

    func testEnglishVariableNamesWorkLikeTheChineseOnes() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let out = expandTemplate("In {project} on {date}: {clipboard}", project: "app", clipboard: "boom", now: now)
        XCTAssertEqual(out.text, "In app on \(DailyStats.dayKey(now)): boom")
        XCTAssertTrue(out.unresolved.isEmpty)
        let missing = expandTemplate("{project} {clipboard}", project: nil, clipboard: nil, now: now)
        XCTAssertEqual(missing.unresolved, ["{project}", "{clipboard}"])
    }

    func testInsertingAboveAnEnglishMoreMarker() {
        let text = insertingTemplate(into: "## A\nbody\n\n## More\n\n## B\nbody\n", title: "New", body: "x")!
        XCTAssertEqual(parsePromptTemplates(text).map(\.title), ["A", "New", "B"])
        XCTAssertEqual(parsePromptTemplates(text).map(\.isMore), [false, false, true])
        XCTAssertNil(insertingTemplate(into: "", title: "More", body: "x"))
    }
}
