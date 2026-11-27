import AppKit
import XCTest
@testable import NeatGit

/// 原生差异视图纯渲染部分的回归：把逐行对照结果变成各面板的显示内容。
///
/// 全部是纯计算，不创建窗口、不上屏。折叠与展开在界面上的装配行为见 `NativeDiffViewHostTests`。
final class NativeDiffRenderTests: XCTestCase {
    // MARK: - 折叠阈值与上下文

    /// 中间的未变更内容超过 6 行才折叠（前后各留 3 行后仍有剩余）；文档开头、结尾只留靠改动的一侧 3 行。
    func testChangesOnlyFoldsOnlyUnchangedRunsLongerThanSixLines() {
        for runLength in 5...7 {
            let middle = (1...runLength).map { "第 \($0) 行" }.joined(separator: "\n")
            let document = NativeDiffRenderSample.makeDocument(
                original: "开头原文\n\(middle)\n结尾原文\n",
                modified: "开头改后\n\(middle)\n结尾改后\n"
            )
            let display = NativeDiffRenderBuilder.displayRows(document.rows, onlyChanges: true, expanded: [])
            let expanderCount = Self.expanderCount(display)
            XCTAssertEqual(document.rows.count, runLength + 2, "物料应有 \(runLength) 行未变更内容和首尾两处改动。")
            XCTAssertEqual(display.count, runLength + 2)
            XCTAssertEqual(expanderCount, runLength == 7 ? 1 : 0, "中间 \(runLength) 行未变更内容是否折叠。")
        }

        for runLength in [3, 4] {
            let lines = (1...runLength).map { "第 \($0) 行\n" }.joined()
            let leading = NativeDiffRenderSample.makeDocument(original: lines + "原文\n", modified: lines + "改后\n")
            let trailing = NativeDiffRenderSample.makeDocument(original: "原文\n" + lines, modified: "改后\n" + lines)
            let folded = runLength > 3
            XCTAssertEqual(Self.expanderCount(NativeDiffRenderBuilder.displayRows(leading.rows, onlyChanges: true, expanded: [])), folded ? 1 : 0, "文档开头 \(runLength) 行未变更内容。")
            XCTAssertEqual(Self.expanderCount(NativeDiffRenderBuilder.displayRows(trailing.rows, onlyChanges: true, expanded: [])), folded ? 1 : 0, "文档结尾 \(runLength) 行未变更内容。")
        }
    }

    /// 每处改动前后各保留 3 行未变更内容，被折叠的只有再往外的部分；行号始终是文件里的真实行号。
    func testChangesOnlyKeepsThreeContextLinesAroundEachChangeWithRealLineNumbers() throws {
        let document = NativeDiffRenderSample.document()
        let result = try NativeDiffRenderBuilder.render(document: document, layout: .sideBySide, showChangesOnly: true, expanded: [], id: 1)
        XCTAssertEqual(result.panes.count, 2)

        // 物料：第 1–10 行未变更、第 11 行改动、第 12–21 行未变更、第 22 行删加、第 23–29 行未变更、第 30 行删除、第 31–32 行未变更。
        // 开头只留 8–10，结尾 31–32 不折叠；三处改动前后各 3 行可见。
        let originalNumbers = [nil, 8, 9, 10, 11, 12, 13, 14, nil, 19, 20, 21, 22, nil, 23, 24, 25, nil, 27, 28, 29, 30, 31, 32]
        let modifiedNumbers = [nil, 8, 9, 10, 11, 12, 13, 14, nil, 19, 20, 21, nil, 22, 23, 24, 25, nil, 27, 28, 29, nil, 30, 31]
        XCTAssertEqual(result.panes[0].lines.map(\.number), originalNumbers, "原文一栏的行号。")
        XCTAssertEqual(result.panes[1].lines.map(\.number), modifiedNumbers, "改后一栏的行号。")
        XCTAssertEqual(result.panes[0].lines[1].text, "第 8 行")
        XCTAssertEqual(result.panes[0].lines[4].text, "let target = \"原值\"")
        XCTAssertEqual(result.panes[1].lines[4].text, "let target = \"新值\"")
        XCTAssertEqual(result.panes[1].lines[4].style, .added, "改动行在改后一栏按新增着色。")
        XCTAssertEqual(result.panes[0].lines[4].style, .removed, "改动行在原文一栏按删除着色。")
        XCTAssertEqual(result.panes[1].lines[12].style, .filler, "原文独有的行在改后一栏是填充行。")
        XCTAssertEqual(result.panes[0].lines[13].style, .filler)

        let expanders = result.panes[1].lines.filter { $0.style == .expander }
        XCTAssertEqual(expanders.map(\.expanderKey), [0, 14, 26])
        XCTAssertTrue(expanders[0].text.contains("省略 7 行"), expanders[0].text)
        XCTAssertTrue(expanders[1].text.contains("省略 4 行"), expanders[1].text)
        XCTAssertTrue(expanders[2].text.contains("省略 1 行"), expanders[2].text)
        for expander in expanders {
            XCTAssertTrue(expander.text.contains("点击展开"), "展开行要提示可以点击。")
            XCTAssertNil(expander.number, "展开行没有行号。")
        }
    }

    /// 逐个展开后行数回到完整行数，行号与不折叠时逐行一致。
    func testExpandingRestoresFullLinesWithRealLineNumbers() throws {
        let document = NativeDiffRenderSample.document()
        var expanded: Set<Int> = []
        var previousCount = 0
        for _ in 0..<10 {
            let result = try NativeDiffRenderBuilder.render(document: document, layout: .sideBySide, showChangesOnly: true, expanded: expanded, id: 1)
            let keys = result.panes[1].lines.compactMap(\.expanderKey)
            XCTAssertEqual(result.panes[1].lines.compactMap(\.expanderKey), result.panes[0].lines.compactMap(\.expanderKey), "两栏的折叠行位置一致。")
            guard let key = keys.first else { break }
            if previousCount > 0 {
                XCTAssertGreaterThanOrEqual(result.panes[0].lines.count, previousCount, "展开只恢复省略行；省略 1 行时总数不变。")
            }
            previousCount = result.panes[0].lines.count
            expanded.insert(key)
        }
        XCTAssertEqual(expanded.count, 3, "物料应有三处折叠。")
        for layout in [NativeDiffLayout.sideBySide, .unified] {
            let expandedResult = try NativeDiffRenderBuilder.render(document: document, layout: layout, showChangesOnly: true, expanded: expanded, id: 1)
            let fullResult = try NativeDiffRenderBuilder.render(document: document, layout: layout, showChangesOnly: false, expanded: [], id: 1)
            for (restoredPane, fullPane) in zip(expandedResult.panes, fullResult.panes) {
                XCTAssertEqual(restoredPane.lines.map(\.number), fullPane.lines.map(\.number), "\(layout) 全部展开后行号应与不折叠时一致。")
                XCTAssertEqual(restoredPane.lines.map(\.text), fullPane.lines.map(\.text), "\(layout) 全部展开后文本应与不折叠时一致。")
            }
        }
        XCTAssertEqual(Self.expanderCount(NativeDiffRenderBuilder.displayRows(document.rows, onlyChanges: true, expanded: expanded)), 0)
    }

    /// 并排时一个差异行占左右各一行，单侧独有的行在另一侧放填充行，两栏行数始终相同。
    func testSideBySidePanesAlwaysHaveTheSameLineCount() throws {
        let document = NativeDiffRenderSample.document()
        let cases: [(showChangesOnly: Bool, expanded: Set<Int>)] = [
            (false, []),
            (true, []),
            (true, [0]),
            (true, [0, 14, 26]),
        ]
        for testCase in cases {
            let result = try NativeDiffRenderBuilder.render(document: document, layout: .sideBySide, showChangesOnly: testCase.showChangesOnly, expanded: testCase.expanded, id: 1)
            let left = result.panes[0].lines
            let right = result.panes[1].lines
            XCTAssertEqual(left.count, right.count, "两栏行数应相同：只看变更 \(testCase.showChangesOnly)，已展开 \(testCase.expanded.count) 处。")
            XCTAssertEqual(result.panes[0].documentHeight, result.panes[1].documentHeight, "两栏文档高度应相同。")
            for (original, modified) in zip(left, right) {
                // 填充行只出现在单侧独有行的另一侧，两栏不会同时是填充行，也不会同时没有行号而不是填充行。
                let bothEmpty = original.style == .filler && modified.style == .filler
                XCTAssertFalse(bothEmpty, "同一行不能两栏都是填充。")
                if original.style == .filler {
                    XCTAssertNil(original.number)
                    XCTAssertEqual(modified.style, .added)
                }
                if modified.style == .filler {
                    XCTAssertNil(modified.number)
                    XCTAssertEqual(original.style, .removed)
                }
                XCTAssertEqual(original.expanderKey, modified.expanderKey, "折叠行在两栏的位置应一致。")
            }
        }

        // 没有任何改动时不折叠，两栏行数等于原文行数。
        let unchanged = NativeDiffRenderSample.makeDocument(original: "第一行\n第二行\n", modified: "第一行\n第二行\n")
        let unchangedResult = try NativeDiffRenderBuilder.render(document: unchanged, layout: .sideBySide, showChangesOnly: true, expanded: [], id: 1)
        XCTAssertEqual(unchangedResult.panes[0].lines.count, 2)
        XCTAssertEqual(unchangedResult.panes[1].lines.count, 2)
    }

    // MARK: - 换行符

    /// "\r\n" 换行的文件：行尾回车符不进入显示文本与富文本，两种布局都一样。
    func testCarriageReturnsAreNotShownInEitherLayout() throws {
        let document = NativeDiffRenderSample.makeDocument(
            original: "第一行\r\nlet value = \"旧\"\r\n第三行\r\n",
            modified: "第一行\r\nlet value = \"新\"\r\n第三行\r\n"
        )
        // 物料本身带着回车符，这样「不显示」才有意义。
        XCTAssertEqual(document.rows[1].modified?.text, "let value = \"新\"\r")
        for layout in NativeDiffLayout.allCases {
            let result = try NativeDiffRenderBuilder.render(document: document, layout: layout, showChangesOnly: false, expanded: [], id: 1)
            XCTAssertEqual(result.panes.count, layout == .sideBySide ? 2 : 1)
            for pane in result.panes {
                XCTAssertFalse(pane.attributed.string.contains("\r"), "\(layout) 布局的富文本不应含回车符。")
                for line in pane.lines {
                    XCTAssertFalse(line.text.contains("\r"), "\(layout) 布局的行文本不应含回车符：\(line.text.debugDescription)")
                }
                XCTAssertTrue(pane.attributed.string.contains("第三行"))
            }
            // 单栏：改动的两行分别带增删前缀。
            if layout == .unified {
                XCTAssertEqual(result.panes[0].lines.map(\.text), ["  第一行", "- let value = \"旧\"", "+ let value = \"新\"", "  第三行"])
                XCTAssertEqual(result.panes[0].lines.map(\.number), [1, 2, 2, 3])
            }
        }
    }

    // MARK: - 辅助

    /// 显示行里的展开行数量。
    static func expanderCount(_ rows: [NativeDiffRenderBuilder.DisplayRow]) -> Int {
        var count = 0
        for row in rows {
            if case .expander = row { count += 1 }
        }
        return count
    }
}

/// 渲染验证共用的物料：一处改动、一处删除加新增、一处删除，中间夹着不同长度的未变更内容。
enum NativeDiffRenderSample {
    /// 原文 32 行：1–10 未变更，11 改动，12–21 未变更，22 被删除，23–29 未变更，30 被删除，31–32 未变更。
    static let originalText = contextLines(1...10)
        + "let target = \"原值\"\n"
        + contextLines(12...21)
        + "被删除的行\n"
        + contextLines(23...29)
        + "删除的第二行\n"
        + contextLines(31...32)

    /// 改后 31 行：1–21 同上（第 11 行内容变了），22 是新增行，23–29 未变更，31–32 未变更。
    static let modifiedText = contextLines(1...10)
        + "let target = \"新值\"\n"
        + contextLines(12...21)
        + "插入的新行\n"
        + contextLines(23...29)
        + contextLines(31...32)

    static func document() -> RepositoryDiffDocument {
        makeDocument(original: originalText, modified: modifiedText)
    }

    static func makeDocument(original: String, modified: String) -> RepositoryDiffDocument {
        RepositoryDiffDocument(
            repositoryPath: "/渲染物料",
            filePath: "示例.swift",
            mode: .workingTree,
            originalText: original,
            modifiedText: modified,
            languageHint: "swift"
        ).calculatingDiffRows()
    }

    private static func contextLines(_ range: ClosedRange<Int>) -> String {
        range.map { "第 \($0) 行\n" }.joined()
    }
}
