import AppKit
import XCTest
@testable import NeatGit

/// 原生差异视图的装载行为回归，由旧网页差异视图（Monaco / WebView）的三个用例改写而来。
///
/// 旧用例断言的都是网页内部状态（等网页桥就绪、篡改 `window.neatGit.setDiff`、读 Monaco 的主题类名与行号节点），
/// 随网页差异视图一起删除。其中还有价值的三条行为改为针对原生视图：
/// - 「连续切换只显示最后一份、不重新加载网页」→ 下面的「最后一份文档胜出、迟到的旧结果丢弃」。
/// - 「只看变更折叠、切换开关不重传正文」→ 下面的「开关与展开只重新排版，不重算差异、不换文本视图」。
/// - 「深色 / 高对比外观同步」「注入失败进入中文错误态并可重试」→ 只对网页内部成立，删除。
///   原生显示效果由真实窗口验收承担。
///
/// 直接驱动原生视图的装配器，视图不进窗口层级，不上屏。
@MainActor
final class NativeDiffViewHostTests: XCTestCase {
    func testLatestDocumentWinsAndLateResultOfThePreviousDocumentIsDropped() async throws {
        let host = makeHost()
        // 第一份很大、排版慢；紧接着换成小文档。大文档的结果迟到时必须丢弃，不能盖掉最后一份。
        let large = Self.makeLargeDocument(lineCount: 80_000)
        let latest = NativeDiffRenderSample.makeDocument(original: "", modified: "最后一份文档\n")
        TextDiffCalculator.resetRecordedCalculationCount()
        host.coordinator.render(into: host.container, document: large, layout: .sideBySide, showChangesOnly: false)
        host.coordinator.render(into: host.container, document: latest, layout: .sideBySide, showChangesOnly: false)

        try await waitUntil("最后一份文档应显示出来") {
            let panes = Self.textViews(in: host.container)
            return panes.count == 2 && panes[1].textStorage?.string.contains("最后一份文档") == true
        }
        // 留出大文档返回的时间：它迟到的结果不能替换掉最后一份。
        try await Task.sleep(for: .milliseconds(1_000))
        let panes = Self.textViews(in: host.container)
        XCTAssertEqual(panes.map { $0.accessibilityIdentifier() }, ["file-diff-original", "file-diff-modified"], "并排应有原文、改后两栏。")
        XCTAssertEqual(panes[0].textStorage?.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, true, "原文侧只有填充空行，不应伪造内容。实际内容：\(panes[0].textStorage?.string.debugDescription ?? "无")")
        XCTAssertEqual(panes[1].textStorage?.string.contains("最后一份文档"), true)
        for pane in panes {
            XCTAssertEqual(pane.textStorage?.string.contains(Self.largeLineMarker) == true, false, "迟到的旧文档结果不能覆盖最后一份。")
        }
        XCTAssertEqual(TextDiffCalculator.recordedCalculationCount, 0, "装配原生视图不应重新计算差异。")
        XCTAssertEqual(TextDiffCalculator.recordedMainThreadCalculationCount, 0)
    }

    func testChangesOnlyToggleAndExpandOnlyRelayoutWithoutRecalculatingOrReplacingPanes() async throws {
        let host = makeHost()
        let document = NativeDiffRenderSample.document()
        TextDiffCalculator.resetRecordedCalculationCount()
        host.coordinator.render(into: host.container, document: document, layout: .sideBySide, showChangesOnly: false)
        try await waitUntil("完整差异应显示出来") {
            Self.textViews(in: host.container).count == 2
                && Self.textViews(in: host.container).allSatisfy { $0.lineStyles.count == document.rows.count }
        }
        let panes = Self.textViews(in: host.container)
        XCTAssertEqual(panes[0].accessibilityIdentifier(), "file-diff-original")
        XCTAssertEqual(panes[1].accessibilityIdentifier(), "file-diff-modified")
        let fullNumbers = panes.map { $0.numberTexts }

        host.coordinator.render(into: host.container, document: document, layout: .sideBySide, showChangesOnly: true)
        try await waitUntil("只看变更应折叠未变更内容") {
            let current = Self.textViews(in: host.container)
            return current.count == 2 && current.allSatisfy { pane in
                pane.lineStyles.count < document.rows.count && pane.expanderKeys.contains { $0 >= 0 }
            }
        }
        XCTAssertEqual(TextDiffCalculator.recordedCalculationCount, 0, "开关只看变更不应重新计算差异。")

        // 逐个点击展开行：走文本视图的展开回调（与鼠标点击同一个入口）。
        var remaining = Self.textViews(in: host.container)[safe: 1]?.expanderKeys.filter { $0 >= 0 }.count ?? 0
        XCTAssertEqual(remaining, 3, "物料应有三处折叠。")
        while remaining > 0 {
            let before = Self.textViews(in: host.container)
            guard before.count == 2, let key = before[1].expanderKeys.first(where: { $0 >= 0 }) else {
                XCTFail("两栏应保留同一处折叠行。")
                break
            }
            XCTAssertEqual(before[0].expanderKeys.filter { $0 >= 0 }, before[1].expanderKeys.filter { $0 >= 0 }, "折叠行在两栏的位置应一致。")
            let countBefore = before[0].lineStyles.count
            before[0].onExpand?(key)
            try await waitUntil("点击展开后该折叠行应消失") {
                let current = Self.textViews(in: host.container)
                return current.count == 2 && current.allSatisfy { !$0.expanderKeys.contains(key) }
            }
            let after = Self.textViews(in: host.container)
            XCTAssertEqual(after[0], before[0])
            XCTAssertEqual(after[1], before[1])
            let lineCount = after[0].lineStyles.count
            XCTAssertGreaterThanOrEqual(lineCount, countBefore, "展开只恢复省略行；省略 1 行时总数不变。")
            XCTAssertEqual(after[1].lineStyles.count, lineCount, "两栏行数应保持一致。")
            remaining -= 1
            XCTAssertEqual(after[1].expanderKeys.filter { $0 >= 0 }.count, remaining)
            // 行号是文件里的真实行号：按顺序取自完整行号，只是少了仍被折叠的那些行。
            let shown = Set(after[1].numberTexts.filter { !$0.isEmpty })
            let expected = fullNumbers[1].filter { shown.contains($0) }
            XCTAssertEqual(after[1].numberTexts.filter { !$0.isEmpty }, expected)
        }
        XCTAssertEqual(Self.textViews(in: host.container)[0].numberTexts, fullNumbers[0], "全部展开后原文一栏回到完整行号。")
        XCTAssertEqual(Self.textViews(in: host.container)[1].numberTexts, fullNumbers[1], "全部展开后改后一栏回到完整行号。")

        // 切到单栏再切回：换一套面板，切回时仍是原来那两个文本视图。
        host.coordinator.render(into: host.container, document: document, layout: .unified, showChangesOnly: true)
        try await waitUntil("单栏应显示一个文本视图") {
            let current = Self.textViews(in: host.container)
            return current.count == 1 && current[0].accessibilityIdentifier() == "file-diff-unified" && !current[0].lineStyles.isEmpty
        }
        host.coordinator.render(into: host.container, document: document, layout: .sideBySide, showChangesOnly: true)
        try await waitUntil("切回并排应显示两个文本视图") {
            Self.textViews(in: host.container).count == 2
        }
        let restored = Self.textViews(in: host.container)
        XCTAssertEqual(restored[0], panes[0])
        XCTAssertEqual(restored[1], panes[1])
        XCTAssertEqual(TextDiffCalculator.recordedCalculationCount, 0, "切换布局不应重新计算差异。")
        XCTAssertEqual(TextDiffCalculator.recordedMainThreadCalculationCount, 0)
    }

    // MARK: - 辅助

    private func makeHost() -> (container: NativeDiffContainerView, coordinator: NativeDiffView.Coordinator) {
        let container = NativeDiffContainerView()
        container.frame = NSRect(x: 0, y: 0, width: 1_200, height: 600)
        return (container, NativeDiffView.Coordinator())
    }

    private static let largeLineMarker = "大文档行"

    private static func makeLargeDocument(lineCount: Int) -> RepositoryDiffDocument {
        let rows = (0..<lineCount).map { index in
            let line = RepositoryDiffLine(text: "\(largeLineMarker) \(index)", lineNumber: index + 1)
            return RepositoryDiffRow(kind: .context, original: line, modified: line, originalChangedRanges: [], modifiedChangedRanges: [])
        }
        return RepositoryDiffDocument(
            repositoryPath: "/装配物料",
            filePath: "大文件.txt",
            mode: .workingTree,
            originalText: "",
            modifiedText: "",
            languageHint: nil,
            rows: rows,
            originalLines: lineCount,
            modifiedLines: lineCount
        )
    }

    /// 容器里的文本视图，固定按「原文、改后、单栏」的标识顺序排列，不依赖子视图的叠放次序。
    private static func textViews(in container: NativeDiffContainerView) -> [NativeDiffTextView] {
        let identifiers = ["file-diff-original", "file-diff-modified", "file-diff-unified"]
        let views = container.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NativeDiffTextView }
        return identifiers.compactMap { identifier in views.first { $0.accessibilityIdentifier() == identifier } }
    }

    private func waitUntil(_ message: String, timeout: Double = 15, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("\(message)（等待 \(Int(timeout)) 秒超时）。")
    }
}

private extension Array {
    /// 越界返回 nil，断言表达式里不做会崩溃的运算。
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
