import AppKit

/// 承载一侧差异内容的只读文本视图（TextKit 2）。
///
/// 一行差异对应一个段落。行号、整行底色、展开行都在背景绘制阶段完成：
/// 实测 `draw(_:)` 返回后行号栏区域已被裁掉，画不进去，所以不放在 `draw(_:)` 里。
/// 文本只排视口附近的行，文档有几万行也只对看得见的行做布局。
@MainActor
final class NativeDiffTextView: NSTextView {
    var lineStyles: [NativeDiffLine.Style] = []
    /// 每个段落在文档中的起始字符偏移，用于把布局片段映射回行。
    var paragraphStarts: [Int] = []
    var numberTexts: [String] = []
    /// 展开行对应的折叠键；其余行为 -1。
    var expanderKeys: [Int] = []
    var rowHeight: CGFloat = 16
    var characterAdvance: CGFloat = 7.2
    var onExpand: ((Int) -> Void)?

    private var gutterWidth: CGFloat { textContainerInset.width }

    /// 行号所在矩形的右端与正文的间距。
    private let numberGap: CGFloat = 10

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        let profileInterval = InteractionProfiler.begin("原生差异.可视区绘制")
        defer { profileInterval.end("总行数：\(lineStyles.count)；重绘高度：\(Int(dirtyRect.height))") }
        guard !lineStyles.isEmpty else { return }

        let origin = textContainerOrigin
        let numberAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NativeDiffColors.lineNumber,
        ]
        let numberWidth = max(gutterWidth - numberGap, 0)
        let selection = selectedRange()

        enumerateVisible(dirtyRect) { index, frame, style in
            switch style {
            case .added: NativeDiffColors.addedRow.setFill()
            case .removed: NativeDiffColors.removedRow.setFill()
            case .filler: NativeDiffColors.fillerRow.setFill()
            case .expander: NativeDiffColors.expanderRow.setFill()
            case .context: break
            }
            if style != .context {
                frame.fill()
            }

            // 彩色行上系统画的选择高亮会被整行底色盖住，这里按等宽字符位置补画一遍。
            if style == .added || style == .removed || style == .expander, selection.length > 0,
               let rowStart = self.paragraphStarts[safe: index]
            {
                let rowEnd = self.paragraphStarts[safe: index + 1] ?? self.textStorage?.length ?? rowStart
                if selection.location < rowEnd, NSMaxRange(selection) > rowStart {
                    let from = max(selection.location, rowStart) - rowStart
                    let to = min(NSMaxRange(selection), rowEnd) - rowStart
                    let rect = NSRect(
                        x: origin.x + CGFloat(from) * self.characterAdvance,
                        y: frame.minY,
                        width: CGFloat(to - from) * self.characterAdvance,
                        height: frame.height
                    )
                    NativeDiffColors.selectionOnRow.setFill()
                    rect.fill()
                }
            }

            if let number = self.numberTexts[safe: index], !number.isEmpty {
                let rect = NSRect(x: 0, y: origin.y + frame.minY, width: numberWidth, height: self.rowHeight)
                (number as NSString).draw(in: rect, withAttributes: numberAttributes)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // 行高固定且不折行，行下标可以直接由纵坐标算出。
        let row = Int((point.y - textContainerInset.height) / rowHeight)
        if row >= 0, let key = expanderKeys[safe: row], key >= 0 {
            onExpand?(key)
            return
        }
        super.mouseDown(with: event)
    }

    /// 枚举与 `dirtyRect` 相交的布局片段，回调给出：行下标、行的矩形（视图坐标系，整行宽）、行的样式。
    private func enumerateVisible(_ dirtyRect: NSRect, _ body: (Int, NSRect, NativeDiffLine.Style) -> Void) {
        guard let layoutManager = textLayoutManager, let contentManager = layoutManager.textContentManager else { return }
        let origin = textContainerOrigin
        var start = layoutManager.documentRange.location
        if dirtyRect.minY > origin.y,
           let top = layoutManager.textLayoutFragment(for: NSPoint(x: 1, y: dirtyRect.minY - origin.y)),
           let element = top.textElement, let range = element.elementRange
        {
            start = range.location
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: dirtyRect).addClip()
        layoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            let inView = NSRect(x: 0, y: origin.y + frame.minY, width: self.bounds.width, height: frame.height)
            if inView.minY >= dirtyRect.maxY { return false }
            if let element = fragment.textElement, let range = element.elementRange {
                let offset = contentManager.offset(from: layoutManager.documentRange.location, to: range.location)
                if let index = self.paragraphIndex(forOffset: offset), let style = self.lineStyles[safe: index] {
                    body(index, inView, style)
                }
            }
            return true
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 二分查找：偏移落在哪个段落里。
    func paragraphIndex(forOffset offset: Int) -> Int? {
        var low = 0
        var high = paragraphStarts.count
        while low < high {
            let middle = (low + high) / 2
            if paragraphStarts[middle] <= offset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low > 0 ? low - 1 : nil
    }
}

private extension Array {
    /// 越界返回 nil，供绘制阶段读取兜底。
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
