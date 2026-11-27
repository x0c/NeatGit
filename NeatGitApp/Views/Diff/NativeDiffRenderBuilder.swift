import AppKit
import Foundation

/// 原生差异视图的布局方式。
enum NativeDiffLayout: String, CaseIterable, Identifiable, Sendable {
    /// 左右各一栏：左原文、右改后，逐行对齐、滚动联动。
    case sideBySide
    /// 前后内容合在一栏：删除行在上、新增行在下。
    case unified

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sideBySide: return "并排"
        case .unified: return "单栏"
        }
    }
}

/// 一侧面板里显示的一行。
struct NativeDiffLine: Sendable {
    enum Style: Sendable {
        /// 未变更。
        case context
        /// 整行底色按删除着色（并排的原文一侧，「改动」行也按删除着色）。
        case removed
        /// 整行底色按新增着色。
        case added
        /// 并排时另一侧没有对应内容。
        case filler
        /// 折叠起来的未变更内容，点击可展开。
        case expander
    }

    var style: Style
    /// 真实行号；填充行与展开行为 nil。
    var number: Int?
    /// 行内文本，不含换行符与行尾回车符；单栏时已含增删前缀。
    var text: String
    /// 行内变化区间（UTF-16 偏移，相对 `text`）。
    var changedRanges: [Range<Int>]
    /// 展开行对应的折叠键；其余行为 nil。
    var expanderKey: Int?
}

/// 一侧面板的完整内容：显示行、富文本以及文本视图需要的几何信息。
struct NativeDiffPaneContent: @unchecked Sendable {
    /// 同一份内容只应用到文本视图一次。
    let id: Int
    let lines: [NativeDiffLine]
    let attributed: NSAttributedString
    /// 每个段落（行）在富文本中的起始偏移。
    let paragraphStarts: [Int]
    /// 以下数组也在后台一次算好，主线程应用内容时只赋值，不再逐行映射。
    let lineStyles: [NativeDiffLine.Style]
    let numberTexts: [String]
    let expanderKeys: [Int]
    /// 内容需要的宽度（不含行号栏）。
    let contentWidth: CGFloat
    let rowHeight: CGFloat
    let characterAdvance: CGFloat

    /// 文档总高度：行数乘固定行高，加上下留白。
    var documentHeight: CGFloat { CGFloat(lines.count) * rowHeight + 16 }

    /// 没有可显示内容时用的空内容。
    static func empty(id: Int) -> NativeDiffPaneContent {
        let style = NativeDiffStyle.make()
        return NativeDiffPaneContent(
            id: id,
            lines: [],
            attributed: NSAttributedString(string: ""),
            paragraphStarts: [],
            lineStyles: [],
            numberTexts: [],
            expanderKeys: [],
            contentWidth: 0,
            rowHeight: style.rowHeight,
            characterAdvance: style.advance
        )
    }
}

/// 一次渲染的输出：并排 2 份、单栏 1 份。
struct NativeDiffRenderResult: @unchecked Sendable {
    var panes: [NativeDiffPaneContent]
}

/// 把逐行对照结果变成各面板可直接显示的内容。
///
/// 纯计算，不碰界面，也不做差异计算（差异由加载差异时的后台任务算好）；在后台线程调用。
enum NativeDiffRenderBuilder {
    /// 「只看变更」时，每处改动前后各保留的未变更行数。
    static let contextLines = 3

    /// 单栏时删除行、新增行的行首标记。
    private static let removedMarker = "- "
    private static let addedMarker = "+ "
    private static let contextMarker = "  "

    nonisolated static func render(
        document: RepositoryDiffDocument,
        layout: NativeDiffLayout,
        showChangesOnly: Bool,
        expanded: Set<Int>,
        id: Int
    ) throws -> NativeDiffRenderResult {
        try Task.checkCancellation()
        let display = displayRows(document.rows, onlyChanges: showChangesOnly, expanded: expanded)
        try Task.checkCancellation()
        let style = NativeDiffStyle.make()
        let panes: [NativeDiffPaneContent]
        switch layout {
        case .sideBySide:
            panes = [
                try makeSide(display, side: .original, style: style, id: id),
                try makeSide(display, side: .modified, style: style, id: id),
            ]
        case .unified:
            panes = [try makeUnified(display, style: style, id: id)]
        }
        try Task.checkCancellation()
        return NativeDiffRenderResult(panes: panes)
    }

    // MARK: - 折叠未变更内容

    /// 显示行：要么是差异行，要么是一个展开行。
    enum DisplayRow {
        case diff(RepositoryDiffRow)
        /// `key` 是被折叠的第一行在完整差异行里的下标，展开状态按它记录，不会因为别处展开而错位。
        case expander(key: Int, count: Int, original: ClosedRange<Int>, modified: ClosedRange<Int>)
    }

    /// 「只看变更」：长段未变更内容只留前后各 3 行，中间折叠成展开行。行号始终是文件里的真实行号。
    nonisolated static func displayRows(
        _ rows: [RepositoryDiffRow],
        onlyChanges: Bool,
        expanded: Set<Int>
    ) -> [DisplayRow] {
        let complete = rows.map { DisplayRow.diff($0) }
        guard onlyChanges, rows.contains(where: { $0.kind != .context }) else {
            return complete
        }

        var result: [DisplayRow] = []
        result.reserveCapacity(rows.count)
        var index = 0
        while index < rows.count {
            guard rows[index].kind == .context else {
                result.append(.diff(rows[index]))
                index += 1
                continue
            }

            var end = index
            while end < rows.count, rows[end].kind == .context { end += 1 }
            // 文档开头只留末尾几行，结尾只留开头几行，中间的留两头。
            let head = index == 0 ? 0 : contextLines
            let tail = end == rows.count ? 0 : contextLines
            let firstOmitted = index + head
            let lastKept = end - tail
            let key = firstOmitted
            if lastKept > firstOmitted, !expanded.contains(key),
               let originalFirst = rows[firstOmitted].original, let originalLast = rows[lastKept - 1].original,
               let modifiedFirst = rows[firstOmitted].modified, let modifiedLast = rows[lastKept - 1].modified
            {
                result.append(contentsOf: complete[index..<firstOmitted])
                result.append(.expander(
                    key: key,
                    count: lastKept - firstOmitted,
                    original: originalFirst.lineNumber...originalLast.lineNumber,
                    modified: modifiedFirst.lineNumber...modifiedLast.lineNumber
                ))
                // 折叠块只替换中间省略部分，靠近下一处改动的上下文必须保留。
                result.append(contentsOf: complete[lastKept..<end])
            } else {
                result.append(contentsOf: complete[index..<end])
            }
            index = end
        }
        return result
    }

    nonisolated static func expanderText(count: Int, original: ClosedRange<Int>, modified: ClosedRange<Int>) -> String {
        "⋯⋯ 中间省略 \(count.formatted()) 行未变更内容（原文第 \(original.lowerBound.formatted())–\(original.upperBound.formatted()) 行，改后第 \(modified.lowerBound.formatted())–\(modified.upperBound.formatted()) 行），点击展开 ⋯⋯"
    }

    // MARK: - 组装面板内容

    private enum PaneSide {
        case original
        case modified
    }

    nonisolated private static func filler() -> NativeDiffLine {
        NativeDiffLine(style: .filler, number: nil, text: "", changedRanges: [], expanderKey: nil)
    }

    /// 并排：一个差异行占左右各一行。只有一侧有内容时，另一侧放填充行，保证两栏行数相同、逐行对齐。
    nonisolated private static func makeSide(
        _ rows: [DisplayRow],
        side: PaneSide,
        style: NativeDiffStyle,
        id: Int
    ) throws -> NativeDiffPaneContent {
        var lines: [NativeDiffLine] = []
        lines.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            if index % 256 == 0 { try Task.checkCancellation() }
            switch row {
            case let .expander(key, count, original, modified):
                lines.append(NativeDiffLine(
                    style: .expander,
                    number: nil,
                    text: expanderText(count: count, original: original, modified: modified),
                    changedRanges: [],
                    expanderKey: key
                ))
            case let .diff(diff):
                let line = side == .original ? diff.original : diff.modified
                let ranges = side == .original ? diff.originalChangedRanges : diff.modifiedChangedRanges
                // 「改动」行在原文一侧按删除着色，在改后一侧按新增着色。
                let rowStyle: NativeDiffLine.Style = diff.kind == .context ? .context : (side == .original ? .removed : .added)
                if let line {
                    lines.append(NativeDiffLine(style: rowStyle, number: line.lineNumber, text: displayText(line.text), changedRanges: ranges, expanderKey: nil))
                } else {
                    lines.append(filler())
                }
            }
        }
        return try makeContent(lines, style: style, id: id)
    }

    /// 单栏：删除行与新增行各占一行，前后排列。
    nonisolated private static func makeUnified(_ rows: [DisplayRow], style: NativeDiffStyle, id: Int) throws -> NativeDiffPaneContent {
        var lines: [NativeDiffLine] = []
        lines.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            if index % 256 == 0 { try Task.checkCancellation() }
            switch row {
            case let .expander(key, count, original, modified):
                lines.append(NativeDiffLine(
                    style: .expander,
                    number: nil,
                    text: expanderText(count: count, original: original, modified: modified),
                    changedRanges: [],
                    expanderKey: key
                ))
            case let .diff(diff):
                func append(_ line: RepositoryDiffLine?, marker: String, style rowStyle: NativeDiffLine.Style, ranges: [Range<Int>]) {
                    guard let line else { return }
                    lines.append(NativeDiffLine(
                        style: rowStyle,
                        number: line.lineNumber,
                        text: marker + displayText(line.text),
                        changedRanges: ranges.map { ($0.lowerBound + marker.utf16.count)..<($0.upperBound + marker.utf16.count) },
                        expanderKey: nil
                    ))
                }
                switch diff.kind {
                case .context:
                    append(diff.modified, marker: contextMarker, style: .context, ranges: [])
                case .removed:
                    append(diff.original, marker: removedMarker, style: .removed, ranges: [])
                case .added:
                    append(diff.modified, marker: addedMarker, style: .added, ranges: [])
                case .modified:
                    append(diff.original, marker: removedMarker, style: .removed, ranges: diff.originalChangedRanges)
                    append(diff.modified, marker: addedMarker, style: .added, ranges: diff.modifiedChangedRanges)
                }
            }
        }
        return try makeContent(lines, style: style, id: id)
    }

    /// 显示用文本：去掉行尾回车符（"\r\n" 换行的文件），否则回车符可能被画成占位方框。
    /// 行内变化区间从行首起算，去掉行尾不影响区间位置。
    nonisolated private static func displayText(_ text: String) -> String {
        var text = text
        if text.hasSuffix("\r") {
            text.removeLast()
        }
        return text
    }

    /// 构建富文本：一行一个段落，统一字体与固定行高，行内变化区间加底色。
    nonisolated private static func makeContent(_ lines: [NativeDiffLine], style: NativeDiffStyle, id: Int) throws -> NativeDiffPaneContent {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = style.rowHeight
        paragraph.maximumLineHeight = style.rowHeight
        paragraph.lineSpacing = 0
        paragraph.paragraphSpacing = 0
        paragraph.paragraphSpacingBefore = 0
        let base: [NSAttributedString.Key: Any] = [
            .font: style.font,
            .paragraphStyle: paragraph,
            .foregroundColor: NativeDiffColors.text,
        ]

        let text = NSMutableAttributedString()
        var starts: [Int] = []
        var lineStyles: [NativeDiffLine.Style] = []
        var numberTexts: [String] = []
        var expanderKeys: [Int] = []
        starts.reserveCapacity(lines.count)
        lineStyles.reserveCapacity(lines.count)
        numberTexts.reserveCapacity(lines.count)
        expanderKeys.reserveCapacity(lines.count)
        var widest: Double = 0

        for (index, line) in lines.enumerated() {
            if index % 256 == 0 { try Task.checkCancellation() }
            lineStyles.append(line.style)
            numberTexts.append(line.number.map { String($0) } ?? "")
            expanderKeys.append(line.expanderKey ?? -1)
            let start = text.length
            starts.append(start)
            let length = line.text.utf16.count
            text.append(NSAttributedString(string: line.text + "\n", attributes: base))

            if line.style == .expander {
                text.addAttribute(.foregroundColor, value: NativeDiffColors.expanderText, range: NSRange(location: start, length: length))
            } else {
                let inlineColor = line.style == .added ? NativeDiffColors.addedInline : NativeDiffColors.removedInline
                // 区间来自差异计算，正常总在行内；这里仍然夹紧一次，越界会让文本存储直接抛异常。
                for range in line.changedRanges {
                    let lower = min(max(range.lowerBound, 0), length)
                    let upper = min(max(range.upperBound, lower), length)
                    guard upper > lower else { continue }
                    text.addAttribute(
                        .backgroundColor,
                        value: inlineColor,
                        range: NSRange(location: start + lower, length: upper - lower)
                    )
                }
            }

            widest = max(widest, estimatedUnits(line.text))
        }

        return NativeDiffPaneContent(
            id: id,
            lines: lines,
            attributed: NSAttributedString(attributedString: text),
            paragraphStarts: starts,
            lineStyles: lineStyles,
            numberTexts: numberTexts,
            expanderKeys: expanderKeys,
            // 估算宽度之外留一点余量：容器一旦比某一行窄，这一行就会折行，后面的行全部错位。
            contentWidth: CGFloat(widest) * style.advance * 1.02 + 32,
            rowHeight: style.rowHeight,
            characterAdvance: style.advance
        )
    }

    /// 估算一行占多少个等宽字符位：西文 1 位，中文等宽字符约 2 位，制表符按 4 位。
    nonisolated private static func estimatedUnits(_ text: String) -> Double {
        var units = 0.0
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\t":
                units += 4
            case "\r", "\n":
                continue
            case _ where scalar.value < 0x80:
                units += 1
            default:
                units += 2
            }
        }
        return units
    }
}
