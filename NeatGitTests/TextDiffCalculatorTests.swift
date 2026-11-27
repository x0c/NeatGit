import Foundation
import XCTest
@testable import NeatGit

/// 文本差异计算器的行为与自洽性测试。
///
/// 重点不是某一种写死的输出，而是三条独立于实现的性质：
/// 1. 从结果行能逐字节还原两侧全文；
/// 2. 去掉行内高亮区间后，一对改动行的两侧剩余文本相等；
/// 3. 预算充足时，未变更的行数等于最朴素的最长公共子序列动态规划给出的理论最大值。
final class TextDiffCalculatorTests: XCTestCase {

    // MARK: - 辅助

    private typealias Options = TextDiffCalculator.Options
    private typealias Row = RepositoryDiffRow

    private func calculate(_ original: String, _ modified: String, options: Options = Options()) -> TextDiffCalculator.Result {
        TextDiffCalculator.calculate(originalText: original, modifiedText: modified, options: options)
    }

    /// 不配对改动行：让每一行差异都直接表现为删除与新增，便于和 git 的输出逐行对照。
    private var unpaired: Options {
        var options = Options()
        options.pairingThreshold = 2
        return options
    }

    /// 1 起的连续行号；行数为 0 时为空（不能构造 1...0）。
    private static func lineNumbers(_ count: Int) -> [Int] {
        count > 0 ? Array(1...count) : []
    }

    /// 从结果行去掉指定一侧的行内区间后得到的文本。
    private func stripping(_ ranges: [Range<Int>], from text: String) -> String {
        var units = Array(text.utf16)
        var end = units.count
        for range in ranges.reversed() {
            // 先判合法再切：任何输入都不允许让测试自己崩溃。
            guard range.lowerBound >= 0, range.upperBound <= end, range.lowerBound <= range.upperBound else {
                return "\(text)（区间越界：\(ranges)）"
            }
            units.removeSubrange(range)
            end = range.lowerBound
        }
        return String(decoding: units, as: UTF16.self)
    }

    private func rebuiltText(_ lines: [String], endsWithoutNewline: Bool) -> String {
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n") + (endsWithoutNewline ? "" : "\n")
    }

    /// 自洽性校验：结构合法、可逐字节还原、未变更行两侧相等、去掉高亮区间后两侧相等。
    private func assertConsistent(
        _ result: TextDiffCalculator.Result,
        original: String,
        modified: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let context = "原文=\(original.debugDescription) 修改=\(modified.debugDescription)"
        var originalNumbers: [Int] = []
        var modifiedNumbers: [Int] = []

        for (index, row) in result.rows.enumerated() {
            let where_ = "第 \(index) 行 \(row.kind) \(context)"
            switch row.kind {
            case .context:
                XCTAssertNotNil(row.original, where_, file: file, line: line)
                XCTAssertNotNil(row.modified, where_, file: file, line: line)
                XCTAssertEqual(row.original?.text, row.modified?.text, "未变更行两侧文本应相等：\(where_)", file: file, line: line)
                XCTAssertTrue(row.originalChangedRanges.isEmpty, where_, file: file, line: line)
                XCTAssertTrue(row.modifiedChangedRanges.isEmpty, where_, file: file, line: line)
            case .added:
                XCTAssertNil(row.original, where_, file: file, line: line)
                XCTAssertNotNil(row.modified, where_, file: file, line: line)
            case .removed:
                XCTAssertNotNil(row.original, where_, file: file, line: line)
                XCTAssertNil(row.modified, where_, file: file, line: line)
            case .modified:
                XCTAssertNotNil(row.original, where_, file: file, line: line)
                XCTAssertNotNil(row.modified, where_, file: file, line: line)
                XCTAssertNotEqual(row.original?.text, row.modified?.text, where_, file: file, line: line)
                XCTAssertFalse(row.originalChangedRanges.isEmpty && row.modifiedChangedRanges.isEmpty, "改动行至少一侧要有区间：\(where_)", file: file, line: line)
            }

            if let side = row.original {
                originalNumbers.append(side.lineNumber)
                assertValidRanges(row.originalChangedRanges, in: side.text, where_: where_, file: file, line: line)
            }
            if let side = row.modified {
                modifiedNumbers.append(side.lineNumber)
                assertValidRanges(row.modifiedChangedRanges, in: side.text, where_: where_, file: file, line: line)
            }
            if let a = row.original, let b = row.modified, row.kind == .modified {
                XCTAssertEqual(
                    stripping(row.originalChangedRanges, from: a.text),
                    stripping(row.modifiedChangedRanges, from: b.text),
                    "去掉行内区间后两侧剩余文本应相等：\(where_)",
                    file: file, line: line
                )
            }
        }

        XCTAssertEqual(originalNumbers, Self.lineNumbers(result.originalLines), "原文侧行号应从 1 连续递增：\(context)", file: file, line: line)
        XCTAssertEqual(modifiedNumbers, Self.lineNumbers(result.modifiedLines), "修改侧行号应从 1 连续递增：\(context)", file: file, line: line)
        XCTAssertEqual(originalNumbers.count, result.originalLines, context, file: file, line: line)
        XCTAssertEqual(modifiedNumbers.count, result.modifiedLines, context, file: file, line: line)

        let rebuiltOriginal = rebuiltText(result.rows.compactMap { $0.original?.text }, endsWithoutNewline: result.originalEndsWithoutNewline)
        let rebuiltModified = rebuiltText(result.rows.compactMap { $0.modified?.text }, endsWithoutNewline: result.modifiedEndsWithoutNewline)
        XCTAssertEqual(rebuiltOriginal, original, "原文应可逐字节还原", file: file, line: line)
        XCTAssertEqual(rebuiltModified, modified, "修改后文本应可逐字节还原", file: file, line: line)
        // 末尾没有换行符：`"\r\n"` 也算换行符。
        func lacksTrailingNewline(_ text: String) -> Bool {
            !text.isEmpty && !text.hasSuffix("\n") && !text.hasSuffix("\r\n")
        }
        XCTAssertEqual(result.originalEndsWithoutNewline, lacksTrailingNewline(original), context, file: file, line: line)
        XCTAssertEqual(result.modifiedEndsWithoutNewline, lacksTrailingNewline(modified), context, file: file, line: line)
    }

    /// 行内区间：非空、落在 UTF-16 长度内、升序、互不重叠。
    private func assertValidRanges(_ ranges: [Range<Int>], in text: String, where_: String, file: StaticString, line: UInt) {
        let length = text.utf16.count
        var previousUpperBound = 0
        for range in ranges {
            XCTAssertFalse(range.isEmpty, "区间不应为空：\(where_)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(range.lowerBound, previousUpperBound, "区间应升序且互不重叠：\(where_)", file: file, line: line)
            XCTAssertLessThanOrEqual(range.upperBound, length, "区间不应超出 UTF-16 长度 \(length)：\(where_)", file: file, line: line)
            previousUpperBound = range.upperBound
        }
    }

    private func modifiedRow(_ result: TextDiffCalculator.Result, at index: Int = 0, file: StaticString = #filePath, line: UInt = #line) -> Row {
        let rows = result.rows.filter { $0.kind == .modified }
        guard rows.indices.contains(index) else {
            XCTFail("应存在第 \(index) 个配对改动行，实际 \(result.rows.map(\.kind))", file: file, line: line)
            return Row(kind: .context, original: nil, modified: nil, originalChangedRanges: [], modifiedChangedRanges: [])
        }
        return rows[index]
    }

    // MARK: - 基本情形

    func testIdenticalTextHasOnlyContextRows() {
        let text = "一\n二\n\n三\r\n"
        let result = calculate(text, text)
        XCTAssertFalse(result.didFallBack)
        XCTAssertEqual(result.originalLines, 4)
        XCTAssertEqual(result.modifiedLines, 4)
        XCTAssertEqual(result.rows.map(\.kind), [.context, .context, .context, .context])
        XCTAssertEqual(result.rows.first?.original?.lineNumber, 1)
        XCTAssertEqual(result.rows.last?.original?.lineNumber, 4)
        XCTAssertEqual(result.rows.last?.original?.text, "三\r")
        XCTAssertFalse(result.originalEndsWithoutNewline)
        assertConsistent(result, original: text, modified: text)
    }

    func testPureAdditionAndPureDeletion() {
        let added = calculate("", "a\nb\n")
        XCTAssertEqual(added.rows.map(\.kind), [.added, .added])
        XCTAssertEqual(added.rows.map(\.modified?.lineNumber), [1, 2])
        XCTAssertEqual(added.originalLines, 0)
        assertConsistent(added, original: "", modified: "a\nb\n")

        let removed = calculate("a\nb", "")
        XCTAssertEqual(removed.rows.map(\.kind), [.removed, .removed])
        XCTAssertEqual(removed.rows.map(\.original?.lineNumber), [1, 2])
        XCTAssertTrue(removed.originalEndsWithoutNewline)
        XCTAssertFalse(removed.modifiedEndsWithoutNewline)
        assertConsistent(removed, original: "a\nb", modified: "")

        let bothEmpty = calculate("", "")
        XCTAssertTrue(bothEmpty.rows.isEmpty)
        XCTAssertFalse(bothEmpty.originalEndsWithoutNewline)
    }

    func testChangedLineIsPairedWithInlineRanges() {
        let result = calculate("keep\nlet value = 1\nend\n", "keep\nlet value = 2\nend\n")
        XCTAssertEqual(result.rows.map(\.kind), [.context, .modified, .context])
        let row = modifiedRow(result)
        XCTAssertEqual(row.original?.lineNumber, 2)
        XCTAssertEqual(row.modified?.lineNumber, 2)
        XCTAssertEqual(row.originalChangedRanges, [12..<13])
        XCTAssertEqual(row.modifiedChangedRanges, [12..<13])
        assertConsistent(result, original: "keep\nlet value = 1\nend\n", modified: "keep\nlet value = 2\nend\n")
    }

    func testDissimilarLinesAreAddedAndRemovedInOrder() {
        // 三行里只有一行能和修改侧配成一处改动（beta → zeta），其余输出为新增；两侧行号各自保持顺序。
        let original = "alpha\nbeta\ngamma\n"
        let modified = "alpha\ndelta\nepsilon\nzeta\ngamma\n"
        let result = calculate(original, modified)
        XCTAssertEqual(result.rows.map(\.kind), [.context, .added, .added, .modified, .context])
        XCTAssertEqual(result.rows.compactMap(\.original?.lineNumber), [1, 2, 3])
        XCTAssertEqual(result.rows.compactMap(\.modified?.lineNumber), [1, 2, 3, 4, 5])
        assertConsistent(result, original: original, modified: modified)

        // 关掉配对后同一份输入是「先删除后新增」：gamma 仍是未变更行，只有 beta 被删、三行被增。
        let loose = calculate(original, modified, options: unpaired)
        XCTAssertEqual(loose.rows.map(\.kind), [.context, .removed, .added, .added, .added, .context])
        assertConsistent(loose, original: original, modified: modified)
    }

    func testCommonPrefixAndSuffixAreContext() {
        let original = (1...30).map { "前 \($0)" } + ["旧 A", "旧 B"] + (31...60).map { "后 \($0)" }
        let modified = (1...30).map { "前 \($0)" } + ["新 A", "新 B", "新 C"] + (31...60).map { "后 \($0)" }
        let result = calculate(original.joined(separator: "\n") + "\n", modified.joined(separator: "\n") + "\n")
        XCTAssertEqual(result.rows.first?.kind, .context)
        XCTAssertEqual(result.rows.last?.kind, .context)
        XCTAssertEqual(result.rows.filter { $0.kind == .context }.count, 60)
        assertConsistent(result, original: original.joined(separator: "\n") + "\n", modified: modified.joined(separator: "\n") + "\n")
    }

    func testMissingTrailingNewlineIsRecordedNotMadeIntoEmptyLine() {
        let result = calculate("a\nb", "a\nb\n")
        XCTAssertEqual(result.originalLines, 2)
        XCTAssertEqual(result.modifiedLines, 2)
        XCTAssertTrue(result.originalEndsWithoutNewline)
        XCTAssertFalse(result.modifiedEndsWithoutNewline)
        XCTAssertEqual(result.rows.map(\.kind), [.context, .context])
        assertConsistent(result, original: "a\nb", modified: "a\nb\n")

        let single = calculate("only", "only")
        XCTAssertEqual(single.rows.count, 1)
        assertConsistent(single, original: "only", modified: "only")
    }

    func testCarriageReturnStaysInsideLine() {
        let original = "a\r\nb\r\n"
        let modified = "a\r\nc\r\n"
        let result = calculate(original, modified)
        XCTAssertEqual(result.originalLines, 2, "\r\n 是一个字符，必须仍然按 \n 切成两行")
        XCTAssertEqual(result.modifiedLines, 2)
        XCTAssertEqual(result.rows.map(\.kind), [.context, .modified])
        XCTAssertEqual(result.rows.first?.original?.text, "a\r")
        let row = modifiedRow(result)
        XCTAssertEqual(row.original?.text, "b\r")
        XCTAssertEqual(row.modified?.text, "c\r")
        XCTAssertEqual(row.originalChangedRanges, [0..<1])
        assertConsistent(result, original: original, modified: modified)

        // 以 \r\n 结尾同样算「末尾有换行符」。
        XCTAssertFalse(result.originalEndsWithoutNewline)
        XCTAssertFalse(result.modifiedEndsWithoutNewline)

        // 没有 \r 的文件不受影响；单字符行 b → c 毫无相似之处，按删除加新增输出。
        let plain = calculate("a\nb\n", "a\nc\n")
        XCTAssertEqual(plain.rows.map(\.kind), [.context, .removed, .added])
        assertConsistent(plain, original: "a\nb\n", modified: "a\nc\n")
    }

    // MARK: - 按需计算入口

    func testDocumentCalculatesDiffRowsOnDemand() {
        let original = "keep\nlet value = 1\n"
        let modified = "keep\nlet value = 2\nmore"
        let document = RepositoryDiffDocument(
            repositoryPath: "示例仓库",
            filePath: "a.swift",
            mode: .workingTree,
            originalText: original,
            modifiedText: modified,
            languageHint: "swift"
        )

        // 未调用入口：逐行对照结果保持默认值。
        XCTAssertTrue(document.rows.isEmpty)
        XCTAssertEqual(document.originalLines, 0)
        XCTAssertEqual(document.modifiedLines, 0)
        XCTAssertFalse(document.originalEndsWithoutNewline)
        XCTAssertFalse(document.modifiedEndsWithoutNewline)

        let expected = calculate(original, modified)
        let calculated = document.calculatingDiffRows()
        XCTAssertEqual(calculated.rows.map(\.kind), [.context, .modified, .added])
        XCTAssertEqual(calculated.rows, expected.rows, "按需入口的结果应与直接计算一致")
        XCTAssertEqual(calculated.originalLines, 2)
        XCTAssertEqual(calculated.modifiedLines, 3)
        XCTAssertFalse(calculated.originalEndsWithoutNewline)
        XCTAssertTrue(calculated.modifiedEndsWithoutNewline, "修改后文本末尾没有换行符")

        // 是否算出逐行对照结果不影响等值，也不改变原文档。
        XCTAssertEqual(calculated, document)
        XCTAssertEqual(document.rows.count, 0)
        XCTAssertEqual(document.modifiedLines, 0)
        XCTAssertFalse(document.modifiedEndsWithoutNewline)
    }

    // MARK: - 行内区间

    func testInlineSingleSidedInsertionAndDeletion() {
        let inserted = modifiedRow(calculate("value\n", "vaXlue\n"))
        XCTAssertEqual(inserted.modifiedChangedRanges, [2..<3])
        XCTAssertEqual(inserted.originalChangedRanges, [])

        let deleted = modifiedRow(calculate("vaXlue\n", "value\n"))
        XCTAssertEqual(deleted.originalChangedRanges, [2..<3])
        XCTAssertEqual(deleted.modifiedChangedRanges, [])

        // 中段一侧为空：为空的那一侧得到空区间，另一侧标出中间整段。
        let shrunk = modifiedRow(calculate("abcd\n", "ab\n"))
        XCTAssertEqual(shrunk.originalChangedRanges, [2..<4])
        XCTAssertEqual(shrunk.modifiedChangedRanges, [])
        let grown = modifiedRow(calculate("ab\n", "abcd\n"))
        XCTAssertEqual(grown.originalChangedRanges, [])
        XCTAssertEqual(grown.modifiedChangedRanges, [2..<4])
    }

    func testInlineOffsetsCountUTF16Units() {
        // “中”占 1 个单元，“😀”占 2 个单元，“é”占 2 个单元。
        // “é” 用预先组合的形式书写，占 1 个单元，避免源文件的规范化方式影响预期。
        let row = modifiedRow(calculate("a中😀\u{E9}z\n", "a中\u{E9}z\n"))
        XCTAssertEqual(row.original?.text.utf16.count, 6)
        XCTAssertEqual(row.originalChangedRanges, [2..<4])
        XCTAssertEqual(row.modifiedChangedRanges, [])

        let replaced = modifiedRow(calculate("x😀y\n", "x中y\n"))
        XCTAssertEqual(replaced.originalChangedRanges, [1..<3])
        XCTAssertEqual(replaced.modifiedChangedRanges, [1..<2])
    }

    func testInlineRangesStayInsideLineAndNeverOverlap() {
        for _ in 0..<300 {
            let original = Self.randomText(maximumLines: 6)
            let modified = Self.randomText(maximumLines: 6)
            let result = calculate(original, modified)
            assertConsistent(result, original: original, modified: modified)
        }
    }

    func testOverlongLineMarksOnlyTheMiddleSection() {
        var options = Options()
        options.inlineLineLengthLimit = 8
        let result = calculate("abcddddef\n", "abef\n", options: options)
        let row = modifiedRow(result)
        XCTAssertEqual(row.originalChangedRanges, [2..<7], "应标出 cdddd")
        XCTAssertEqual(row.modifiedChangedRanges, [])
        assertConsistent(result, original: "abcddddef\n", modified: "abef\n")

        // 缺省上限 2,000 字符：超长行同样只标一整段，且不进入字符级搜索。
        let longOriginal = "头" + String(repeating: "甲", count: 1_500) + "旧" + String(repeating: "乙", count: 1_200) + "尾\n"
        let longModified = "头" + String(repeating: "甲", count: 1_500) + "新" + String(repeating: "乙", count: 1_200) + "尾\n"
        let long = calculate(longOriginal, longModified)
        let longRow = modifiedRow(long)
        XCTAssertEqual(longRow.originalChangedRanges.count, 1)
        XCTAssertEqual(longRow.modifiedChangedRanges.count, 1)
        XCTAssertEqual(longRow.originalChangedRanges.first?.lowerBound, 1_501)
        assertConsistent(long, original: longOriginal, modified: longModified)
    }

    func testSeparateChangesOnOneLineAreNotMergedWhenFartherThanOneCharacter() {
        let row = modifiedRow(calculate("aXbcdefgYh\n", "aQbcdefgZh\n"))
        XCTAssertEqual(row.originalChangedRanges, [1..<2, 8..<9])
        XCTAssertEqual(row.modifiedChangedRanges, [1..<2, 8..<9])

        // 只隔一个未变字符的区间会合并成一段。
        let merged = modifiedRow(calculate("aXbYc\n", "aQbZc\n"))
        XCTAssertEqual(merged.originalChangedRanges, [1..<4])
        XCTAssertEqual(merged.modifiedChangedRanges, [1..<4])
    }

    // MARK: - 预算降级

    func testEditDistanceBudgetIsAnExactLimit() {
        // 距离为 6 的输入：预算 6 必须求出最优结果，预算 5 必须降级。
        let original = "a\nb\nc\nd\ne\nf\n"
        let modified = "a\nB\nc\nD\n"
        XCTAssertEqual(lcsLineCount(original, modified), 2)
        XCTAssertEqual(original.split(separator: "\n").count + modified.split(separator: "\n").count - 4, 6)

        let enough = calculate(original, modified, options: options(editDistanceBudget: 6))
        XCTAssertFalse(enough.didFallBack)
        XCTAssertEqual(enough.rows.filter { $0.kind == .context }.count, 2)

        let short = calculate(original, modified, options: options(editDistanceBudget: 5))
        XCTAssertTrue(short.didFallBack)
        assertConsistent(short, original: original, modified: modified)
    }

    func testZeroBudgetDegradesButEmptySideDoesNot() {
        let options = options(editDistanceBudget: 0)
        XCTAssertTrue(calculate("a\nb\n", "a\nB\n", options: options).didFallBack)
        XCTAssertTrue(calculate("a\nb\n", "c\nd\n", options: options).didFallBack)
        // 一侧为空（新增 / 删除文件）无需搜索，不算降级。
        XCTAssertFalse(calculate("", "a\nb\n", options: options).didFallBack)
        XCTAssertFalse(calculate("a\nb\n", "", options: options).didFallBack)
        XCTAssertFalse(calculate("a\nb\n", "a\nb\n", options: options).didFallBack)
    }

    func testSearchStepBudgetStopsSearchAndKeepsResultConsistent() {
        var generator = SeededGenerator(seed: 2026)
        let original = (0..<400).map { index in "行 \(index) \(index % 7)" }.joined(separator: "\n") + "\n"
        let modified = (0..<400).map { index in "行 \(index) \(index % 7)" }.map { $0 }
            .map { $0 + (Int.random(in: 0...2, using: &generator) == 0 ? " 改" : "") }
            .joined(separator: "\n") + "\n"

        let complete = calculate(original, modified)
        XCTAssertFalse(complete.didFallBack)

        // 总步数预算小到搜不完：必须能返回、带降级标记，结果仍然自洽。
        for budget in [0, 1, 10, 100, 1_000] {
            let degraded = calculate(original, modified, options: options(lineSearchBudget: budget))
            XCTAssertTrue(degraded.didFallBack, "预算 \(budget) 应降级")
            assertConsistent(degraded, original: original, modified: modified)
        }

        // 预算耗尽后不再做无谓搜索：极小预算下的结果不应比充足预算时更多行。
        let tiny = calculate(original, modified, options: options(lineSearchBudget: 1))
        XCTAssertGreaterThanOrEqual(tiny.rows.filter { $0.kind != .context }.count, complete.rows.filter { $0.kind != .context }.count)
    }

    func testInlineWorkBudgetIsSharedAcrossLines() {
        // 10 个改动块、每块 20 行，每行都需要字符级搜索；把总量压到只够少数几行，其余行只标整段。
        // 每块行数要小于单块配对上限（「删除行数 × 新增行数」不超过 1,024）。
        func text(_ middle: String) -> String {
            (0..<200).map { index in
                (index % 20 == 19 ? "分隔行 \(index / 20) 保持不变" : "prefix \(index) alpha beta gamma delta epsilon suffix".replacingOccurrences(of: "alpha beta gamma", with: middle))
            }.joined(separator: "\n") + "\n"
        }
        let original = text("alpha beta gamma")
        let modified = text("axpha bzta gzmma")
        var options = Options()
        options.inlineWorkBudget = 1_000
        let result = calculate(original, modified, options: options)
        assertConsistent(result, original: original, modified: modified)
        XCTAssertEqual(result.rows.filter { $0.kind == .modified }.count, 190)

        let wholeMiddleRows = result.rows.filter { row in
            guard row.kind == .modified, let a = row.original?.text, let b = row.modified?.text else { return false }
            let whole = TextDiffCalculator.wholeMiddleRanges(original: a[...], modified: b[...])
            return row.originalChangedRanges == whole.original && row.modifiedChangedRanges == whole.modified
        }
        XCTAssertGreaterThan(wholeMiddleRows.count, 20, "预算耗尽后的改动行应只标整段")

        // 预算充足时同样的输入不会大面积只标整段。
        let complete = calculate(original, modified)
        XCTAssertEqual(complete.rows.filter { row in
            row.kind == .modified && row.originalChangedRanges.count == 1
        }.count, 0)
    }

    // MARK: - 自洽性

    func testRandomInputsRebuildBothSidesAndStayConsistent() {
        var generator = SeededGenerator(seed: 11_26)
        for round in 0..<600 {
            let original = Self.randomText(maximumLines: round % 3 == 0 ? 4 : 60, using: &generator)
            var modified = original
            for _ in 0..<Int.random(in: 0...5, using: &generator) {
                modified = Self.mutate(modified, using: &generator)
            }
            let result = calculate(original, modified)
            assertConsistent(result, original: original, modified: modified)

            // 关掉「隔一个字符合并」后：两侧剩余文本相等，且都不含被标为变化的字符。
            let unmerged = calculate(original, modified, options: options(mergeSingleCharacterGaps: false))
            assertConsistent(unmerged, original: original, modified: modified)
        }
    }

    /// 对文本做一次随机改动：插入、删除、改写一段连续行；末尾换行符可能被改变。
    private static func mutate(_ text: String, using generator: inout SeededGenerator) -> String {
        guard !text.isEmpty else { return randomText(maximumLines: 4, using: &generator) }
        let hadTrailingNewline = text.hasSuffix("\n")
        var lines = TextDiffCalculator.splitLines(text)
        let position = Int.random(in: 0...lines.count, using: &generator)
        let length = Int.random(in: 0...min(6, lines.count - position), using: &generator)
        let replacement = (0..<Int.random(in: 0...4, using: &generator)).map { _ in
            ["", "新", "😀行", "x", "中文 行", ""].randomElement(using: &generator)!
        }
        lines.replaceSubrange(position..<min(position + length, lines.count), with: replacement)
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : (hadTrailingNewline || Bool.random(using: &generator) ? "\n" : ""))
    }

    private func options(
        editDistanceBudget: Int? = nil,
        lineSearchBudget: Int? = nil,
        mergeSingleCharacterGaps: Bool? = nil
    ) -> Options {
        var options = Options()
        options.editDistanceBudget = editDistanceBudget ?? options.editDistanceBudget
        options.lineSearchBudget = lineSearchBudget ?? options.lineSearchBudget
        options.mergeSingleCharacterGaps = mergeSingleCharacterGaps ?? options.mergeSingleCharacterGaps
        return options
    }

    // MARK: - 最优性对照

    /// 最朴素的最长公共子序列动态规划（行级）。
    private func lcs(_ a: [Int], _ b: [Int]) -> Int {
        var previous = [Int](repeating: 0, count: b.count + 1)
        for i in 0..<a.count {
            var current = [Int](repeating: 0, count: b.count + 1)
            for j in 0..<b.count {
                current[j + 1] = a[i] == b[j] ? previous[j] + 1 : max(previous[j + 1], current[j])
            }
            previous = current
        }
        return previous[b.count]
    }

    private func lcsLineCount(_ original: String, _ modified: String) -> Int {
        var ids: [String: Int] = [:]
        let a = TextDiffCalculator.intern(TextDiffCalculator.splitLines(original), into: &ids)
        let b = TextDiffCalculator.intern(TextDiffCalculator.splitLines(modified), into: &ids)
        return lcs(a, b)
    }

    private func matchLines(_ a: [Int], _ b: [Int], budget: Int) -> TextDiffCalculator.Matching {
        var work = 0
        return a.withUnsafeBufferPointer { pointerA in
            b.withUnsafeBufferPointer { pointerB in
                TextDiffCalculator.lineMatching(a: pointerA, b: pointerB, budget: budget, workBudget: Int.max, work: &work)
            }
        }
    }

    func testLineMatchingMatchesNaiveLongestCommonSubsequence() {
        var generator = SeededGenerator(seed: 7)
        let alphabet = ["a", "b", "c", "", "中", "😀"]
        var casesWithDistance = 0

        for _ in 0..<1_000 {
            let original = (0..<Int.random(in: 0...12, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! }
            let modified = (0..<Int.random(in: 0...12, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! }

            var ids: [String: Int] = [:]
            let a = TextDiffCalculator.intern(original, into: &ids)
            let b = TextDiffCalculator.intern(modified, into: &ids)
            // 理论最大匹配行数：最朴素的动态规划。
            let expected = lcs(a, b)
            let matching = matchLines(a, b, budget: 20_000)
            let matched = matching.runs.reduce(0) { $0 + $1.aEnd - $1.aStart }
            let input = "原文=\(original) 修改=\(modified)"
            XCTAssertFalse(matching.exceededBudget, input)
            XCTAssertEqual(matched, expected, "未变更行数必须等于理论最大匹配数：\(input)")

            // 匹配段自身必须合法：两侧等长且逐项相等、按原文顺序互不重叠。
            var lastA = 0
            var lastB = 0
            for run in matching.runs {
                let length = run.aEnd - run.aStart
                XCTAssertTrue(run.aStart >= lastA && run.bStart >= lastB && length == run.bEnd - run.bStart && length >= 0, input)
                XCTAssertTrue(run.aEnd <= a.count && run.bEnd <= b.count, input)
                if run.aStart >= lastA && run.bStart >= lastB && length >= 0 && run.aEnd <= a.count && run.bEnd <= b.count {
                    XCTAssertTrue(zip(a[run.aStart..<run.aEnd], b[run.bStart..<run.bEnd]).allSatisfy { $0 == $1 }, input)
                }
                lastA = run.aEnd
                lastB = run.bEnd
            }

            // 预算边界：预算等于真实编辑距离时必须求出，少 1 时必须降级。
            let distance = a.count + b.count - 2 * expected
            // 剔除公共前后缀后两侧都还有内容，才真的需要搜索；否则距离再大也不算降级。
            var commonPrefix = 0
            while commonPrefix < a.count, commonPrefix < b.count, a[commonPrefix] == b[commonPrefix] { commonPrefix += 1 }
            var commonSuffix = 0
            while commonSuffix < a.count - commonPrefix, commonSuffix < b.count - commonPrefix,
                  a[a.count - 1 - commonSuffix] == b[b.count - 1 - commonSuffix] { commonSuffix += 1 }
            let needsSearch = a.count - commonPrefix - commonSuffix > 0 && b.count - commonPrefix - commonSuffix > 0
            if a.isEmpty || b.isEmpty || distance == 0 || !needsSearch { continue }
            casesWithDistance += 1
            XCTAssertFalse(matchLines(a, b, budget: distance).exceededBudget, "预算等于距离时不应降级：\(input)")
            XCTAssertTrue(matchLines(a, b, budget: distance - 1).exceededBudget, "预算比距离少 1 时应降级：\(input)")
        }
        XCTAssertGreaterThan(casesWithDistance, 300, "随机样本应覆盖到需要搜索的输入")
    }

    func testRowsNeverLoseMatchableLines() {
        var generator = SeededGenerator(seed: 99)
        for _ in 0..<300 {
            let original = Self.randomText(maximumLines: 14, using: &generator)
            let modified = Self.randomText(maximumLines: 14, using: &generator)
            let result = calculate(original, modified)
            XCTAssertFalse(result.didFallBack)
            // 未变更行数不少于理论最大值：配对可能把对称位置上的相同行也归为未变更，所以是下界。
            XCTAssertGreaterThanOrEqual(result.rows.filter { $0.kind == .context }.count, lcsLineCount(original, modified))
            assertConsistent(result, original: original, modified: modified)
        }
    }

    // MARK: - 与 git 对照

    /// 跑一次 `git diff --no-index --minimal -U0`，返回被删除的原文行号与被新增的修改侧行号。
    private func gitLineNumbers(original: String, modified: String) throws -> (removed: Set<Int>, added: Set<Int>) {
        let gitPath = "/usr/bin/git"
        guard FileManager.default.isExecutableFile(atPath: gitPath) else {
            throw XCTSkip("本机没有可执行的 git，跳过对照")
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("neatgit-text-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let originalURL = directory.appendingPathComponent("a.txt")
        let modifiedURL = directory.appendingPathComponent("b.txt")
        try Data(original.utf8).write(to: originalURL)
        try Data(modified.utf8).write(to: modifiedURL)

        // 不读用户与系统配置，避免外部差异工具或缩进启发式干扰。
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        // --minimal：git 缺省的启发式在大段交错重复行上给出的不是最小差异，这里要拿最小差异来对照。
        process.arguments = ["diff", "--no-index", "--minimal", "--no-color", "--no-ext-diff", "--text", "-U0", "--src-prefix=a/", "--dst-prefix=b/", originalURL.path, modifiedURL.path]
        process.environment = ["HOME": directory.path, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // 0 表示无差异，1 表示有差异；其余是 git 自身出错。
        guard process.terminationStatus <= 1 else {
            throw XCTSkip("git 不可用（退出码 \(process.terminationStatus)），跳过对照")
        }

        var removed: Set<Int> = []
        var added: Set<Int> = []
        var originalLine = 0
        var modifiedLine = 0
        // 文件头（diff --git / --- / +++）不是差异内容，遇到第一个块头之前全部跳过。
        var inHunk = false
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@ ") {
                let parts = line.split(separator: " ")
                // "-起始[,数量]"：数量为 0 时起始行指插入点的前一行。字段不全时原样报失败，不取下标。
                guard parts.count >= 3, parts[1].first == "-", parts[2].first == "+" else {
                    XCTFail("无法解析 git 的块头：\(line)")
                    inHunk = true
                    continue
                }
                let originalPart = parts[1].dropFirst().split(separator: ",")
                let modifiedPart = parts[2].dropFirst().split(separator: ",")
                let originalStart = Int(originalPart.first ?? "") ?? 0
                let modifiedStart = Int(modifiedPart.first ?? "") ?? 0
                originalLine = originalPart.count > 1 && originalPart[1] == "0" ? originalStart + 1 : originalStart
                modifiedLine = modifiedPart.count > 1 && modifiedPart[1] == "0" ? modifiedStart + 1 : modifiedStart
                inHunk = true
            } else if !inHunk {
                continue
            } else if line.hasPrefix("-") {
                removed.insert(originalLine)
                originalLine += 1
            } else if line.hasPrefix("+") {
                added.insert(modifiedLine)
                modifiedLine += 1
            } else if line.hasPrefix(" ") {
                originalLine += 1
                modifiedLine += 1
            }
        }
        return (removed, added)
    }

    private func removedAndAddedLineNumbers(_ result: TextDiffCalculator.Result) -> (removed: Set<Int>, added: Set<Int>) {
        (
            Set(result.rows.filter { $0.kind == .removed }.compactMap(\.original?.lineNumber)),
            Set(result.rows.filter { $0.kind == .added }.compactMap(\.modified?.lineNumber))
        )
    }

    func testSimpleSamplesAgreeWithGitLineNumbers() throws {
        // 每行内容互不相同，最优对齐方式唯一，可以与 git 逐行号对照。
        let samples: [(original: String, modified: String, removed: Set<Int>, added: Set<Int>)] = [
            ("one\ntwo\nthree\n", "one\nTWO\nthree\n", [2], [2]),
            ("a\nb\nc\n", "a\nb\nX\nc\n", [], [3]),
            ("a\nb\nc\n", "a\nc\n", [2], []),
            ("l1\nl2\nl3\nl4\nl5\n", "l0\nl2\nl3x\nl4\nl5\nl6\n", [1, 3], [1, 3, 6]),
            // 两侧都缺末尾换行符；「末行从无换行变成有换行」git 会记成删一行加一行，这里用单独的末尾标记表示，不拿来对照。
            ("a\nb\nc", "a\nB\nc", [2], [2]),
            ("a\nb\nc\nd\ne\nf\n", "a\nB\nC\nD\nD\ne\nf\n", [2, 3, 4], [2, 3, 4, 5]),
            ("", "new\nfile\n", [], [1, 2]),
            ("gone\n", "", [1], [])
        ]

        for sample in samples {
            let result = calculate(sample.original, sample.modified, options: unpaired)
            XCTAssertFalse(result.didFallBack)
            let ours = removedAndAddedLineNumbers(result)
            XCTAssertEqual(ours.removed, sample.removed, "删除行号：\(sample.original.debugDescription) → \(sample.modified.debugDescription)")
            XCTAssertEqual(ours.added, sample.added, "新增行号：\(sample.original.debugDescription) → \(sample.modified.debugDescription)")
            assertConsistent(result, original: sample.original, modified: sample.modified)

            let git = try gitLineNumbers(original: sample.original, modified: sample.modified)
            XCTAssertEqual(git.removed, sample.removed, "git 的删除行号：\(sample.original.debugDescription)")
            XCTAssertEqual(git.added, sample.added, "git 的新增行号：\(sample.original.debugDescription)")
        }
    }

    func testRandomSamplesAgreeWithGitOnChangeCounts() throws {
        // 随机输入可能有多种最优对齐，但删除数、新增数在所有最优解里都相同。
        var generator = SeededGenerator(seed: 4_321)
        let fragments = ["x", "y", "z", "", "中", "😀"]
        for _ in 0..<60 {
            let original = (0..<Int.random(in: 0...16, using: &generator)).map { _ in fragments.randomElement(using: &generator)! }.joined(separator: "\n") + "\n"
            let modified = (0..<Int.random(in: 0...16, using: &generator)).map { _ in fragments.randomElement(using: &generator)! }.joined(separator: "\n") + "\n"
            let ours = removedAndAddedLineNumbers(calculate(original, modified, options: unpaired))
            let git = try gitLineNumbers(original: original, modified: modified)
            XCTAssertEqual(ours.removed.count, git.removed.count, "删除行数：\(original.debugDescription) → \(modified.debugDescription)")
            XCTAssertEqual(ours.added.count, git.added.count, "新增行数：\(original.debugDescription) → \(modified.debugDescription)")
        }
    }

    // MARK: - 性能量测

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func timed(_ label: String, original: String, modified: String, options: Options = Options()) -> (result: TextDiffCalculator.Result, elapsed: Double) {
        let clock = ContinuousClock()
        let start = clock.now
        let result = calculate(original, modified, options: options)
        let elapsed = seconds(clock.now - start)
        print("性能量测｜\(label)｜行数 \(result.rows.count)｜耗时 \(String(format: "%.3f", elapsed)) 秒｜降级 \(result.didFallBack)")
        return (result, elapsed)
    }

    func testLargeInputsFinishQuickly() {
        let large = (0..<100_000).map { "第 \($0) 行 内容 \($0 * 31 % 997)" }
        var few = large
        for index in stride(from: 500, to: large.count, by: 9_997) {
            few[index] = "改动过的第 \(index) 行"
        }
        few.insert("插入的新行", at: 40_000)
        let fewResult = timed("10 万行、少量改动", original: large.joined(separator: "\n") + "\n", modified: few.joined(separator: "\n") + "\n")
        XCTAssertEqual(fewResult.result.rows.filter { $0.kind == .context }.count, large.count - 10, "10 行被改写，另插入 1 行")
        // 10 行被改写（各自与改写后的行配成一处改动），另插入 1 行。
        XCTAssertEqual(fewResult.result.rows.filter { $0.kind == .modified }.count, 10)
        XCTAssertEqual(fewResult.result.rows.filter { $0.kind == .removed }.count, 0)
        XCTAssertEqual(fewResult.result.rows.filter { $0.kind == .added }.count, 1)
        XCTAssertFalse(fewResult.result.didFallBack)

        // 1 万行、约 3 千行集中改动：两块各 1,500 行被整块换掉。
        let medium = Array(large.prefix(10_000))
        var concentrated = medium
        concentrated.replaceSubrange(3_000..<4_500, with: (0..<1_500).map { "全新行 \($0) 文本 \($0 * 7 % 13)" })
        concentrated.replaceSubrange(6_000..<7_500, with: (0..<1_500).map { "另一批新行 \($0) 文本 \($0 * 5 % 17)" })
        let concentratedResult = timed(
            "1 万行、约 3 千行集中改动",
            original: medium.joined(separator: "\n") + "\n",
            modified: concentrated.joined(separator: "\n") + "\n"
        )
        XCTAssertEqual(concentratedResult.result.rows.filter { $0.kind == .context }.count, 7_000)
        XCTAssertFalse(concentratedResult.result.didFallBack, "这个量级应在预算内求出最优结果")
        // 调试构建下只给很宽松的上限，确保不会卡死；真实数字见上方输出。
        XCTAssertLessThan(concentratedResult.elapsed, 5, "调试构建下也应远快于此")

        // 最坏情况：整份文件完全不同，必须在预算耗尽后降级返回。
        let unrelated = timed(
            "1 万行完全不同",
            original: (0..<10_000).map { "旧内容 \($0)" }.joined(separator: "\n") + "\n",
            modified: (0..<10_000).map { "新内容 \($0)" }.joined(separator: "\n") + "\n"
        )
        XCTAssertTrue(unrelated.result.didFallBack)
        XCTAssertLessThan(unrelated.elapsed, 5)

        XCTAssertLessThan(fewResult.elapsed, 5)
    }


    private struct SeededGenerator: RandomNumberGenerator, Sendable {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    /// 随机文本：不同长度，含空行、重复行、中文与 emoji。
    private static func randomText(maximumLines: Int, using generator: inout SeededGenerator) -> String {
        let fragments = ["", "a", "b", "ab", "中", "文", "😀", "é", " ", "x y", "ab", "中"]
        let count = Int.random(in: 0...maximumLines, using: &generator)
        return (0..<count)
            .map { _ in (0..<Int.random(in: 0...3, using: &generator)).map { _ in fragments.randomElement(using: &generator)! }.joined() }
            .joined(separator: "\n") + (Bool.random(using: &generator) ? "\n" : "")
    }

    private static func randomText(maximumLines: Int) -> String {
        var generator = SeededGenerator(seed: UInt64.random(in: 1...UInt64.max))
        return randomText(maximumLines: maximumLines, using: &generator)
    }
}
