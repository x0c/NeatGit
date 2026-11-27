import AppKit

// 方案甲：NSTextView（TextKit 2），一行一个段落；增删行整行底色与行号栏都由子类在绘制阶段补画

final class DiffTextView: NSTextView {
    /// 每个段落（即每个差异行）的状态
    var kinds: [LineKind] = []
    /// 每个段落在文档中的起始字符偏移，用于把布局片段映射回行号
    var paragraphStarts: [Int] = []
    /// 行号栏文本
    var numberTexts: [String] = []
    var gutterWidth: CGFloat = 56

    private let addedColor = NSColor.systemRed.withAlphaComponent(0.16)
    private let removedColor = NSColor.systemGreen.withAlphaComponent(0.16)
    private let numberAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]

    /// 整行底色与行号都画在背景阶段：实测 super.draw(_:) 返回后行号栏区域已被裁掉，画不进 gutter，
    /// 所以行号不放在 draw(_:) 里，而是与底色一起在背景阶段绘制
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        let origin = textContainerOrigin
        enumerateVisible(dirtyRect) { _, frame, kind in
            switch kind {
            case .added: self.addedColor.setFill()
            case .removed: self.removedColor.setFill()
            case .context: return
            }
            frame.fill()
        }
        let lineHeight = self.lineHeight
        guard lineHeight > 0 else { return }
        enumerateVisible(dirtyRect) { index, frame, _ in
            let rect = NSRect(x: 0, y: origin.y + frame.minY, width: self.gutterWidth - 8, height: lineHeight)
            (self.numberTexts[index] as NSString).draw(in: rect, withAttributes: self.numberAttributes)
        }
    }

    /// 首行行高（布局完成后有效）
    var lineHeight: CGFloat {
        guard let lm = textLayoutManager, let f = lm.textLayoutFragment(for: .zero) else { return 0 }
        return f.textLineFragments.first?.typographicBounds.height ?? f.layoutFragmentFrame.height
    }

    /// 枚举与 dirtyRect 相交的布局片段，回调给出：行下标、片段矩形（视图坐标系，整行宽）、行状态
    private func enumerateVisible(_ dirtyRect: NSRect, _ body: (Int, NSRect, LineKind) -> Void) {
        guard let lm = textLayoutManager, let cm = lm.textContentManager, !kinds.isEmpty else { return }
        let origin = textContainerOrigin
        var start = lm.documentRange.location
        if let top = lm.textLayoutFragment(for: NSPoint(x: origin.x, y: dirtyRect.minY - origin.y)),
           let element = top.textElement, let range = element.elementRange {
            start = range.location
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: dirtyRect).addClip()
        lm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let f = fragment.layoutFragmentFrame
            let inView = NSRect(x: 0, y: origin.y + f.minY, width: self.bounds.width, height: f.height)
            if inView.minY >= dirtyRect.maxY { return false }
            if let element = fragment.textElement, let range = element.elementRange {
                let offset = cm.offset(from: lm.documentRange.location, to: range.location)
                if let index = self.paragraphIndex(forOffset: offset), index < self.kinds.count {
                    body(index, inView, self.kinds[index])
                }
            }
            return true
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    func paragraphIndex(forOffset offset: Int) -> Int? {
        var lo = 0, hi = paragraphStarts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if paragraphStarts[mid] <= offset { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 ? lo - 1 : nil
    }
}

@MainActor
enum DiffTextViewScheme {
    /// 构建富文本（字体 + 段落样式），同时记录每段起始偏移
    static func buildAttributed(_ lines: [DiffLine]) -> (NSAttributedString, [Int]) {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = 0
        let base: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style,
                                                   .foregroundColor: NSColor.textColor]
        let text = NSMutableAttributedString()
        var starts: [Int] = []
        starts.reserveCapacity(lines.count)
        for line in lines {
            starts.append(text.length)
            text.append(NSAttributedString(string: line.marker + " " + line.text + "\n", attributes: base))
        }
        return (text, starts)
    }

    static func run(lineCount: Int) -> [String: Any] {
        var out: [String: Any] = [:]
        let lines = DiffData.make(count: lineCount)
        out["changed_ratio"] = Double(lines.filter { $0.kind != .context }.count) / Double(lineCount)
        let mem0 = footprintMB()
        let t0 = MonotonicClock.now

        // 1. 构建富文本
        let tBuild = MonotonicClock.now
        let (attributed, starts) = buildAttributed(lines)
        out["build_ms"] = MonotonicClock.ms(tBuild)
        out["text_bytes"] = attributed.length

        // 2. 组装 TextKit 2 文本网络
        let tSetup = MonotonicClock.now
        let size = NSSize(width: 1100, height: 700)
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: size.width - 56, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        let textView = DiffTextView(frame: NSRect(origin: .zero, size: size), textContainer: container)
        textView.isEditable = false
        textView.isRichText = false
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 56, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: size.width, height: .greatestFiniteMagnitude)
        textView.minSize = size
        textView.kinds = lines.map(\.kind)
        textView.paragraphStarts = starts
        textView.numberTexts = lines.map(\.numberText)
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        let tSet = MonotonicClock.now
        textView.textStorage?.setAttributedString(attributed)
        out["setup_ms"] = MonotonicClock.ms(tSetup)
        out["set_text_ms"] = MonotonicClock.ms(tSet)
        out["uses_textkit2"] = textView.textLayoutManager != nil

        // 3. 上屏 + 首屏
        let win = Bench.makeWindow(content: scroll, size: size)
        out.merge(Bench.lastWindowTiming) { _, b in b }
        out["first_settle_ms"] = Bench.settle(scroll)
        let first = Bench.renderOffscreen(scroll, rect: scroll.bounds, savesTo: "textview_\(lineCount)_first")
        out["first_render_ms"] = first.ms
        // 首屏自身耗时：从开始构建到首屏画完，扣除建窗的固定开销
        out["first_own_ms"] = MonotonicClock.ms(t0) - (Bench.lastWindowTiming["window_init_ms"] ?? 0) - (Bench.lastWindowTiming["window_wait_visible_ms"] ?? 0)
        let mem1 = footprintMB()

        // 4. 跳到末尾 / 中间 / 回顶部（每步 = 同步调用 + 等主线程空闲 + 离屏画一屏）
        func jump(_ offset: Int, _ key: String, png: Bool = false) {
            let t = MonotonicClock.now
            textView.scrollRangeToVisible(NSRange(location: min(offset, attributed.length - 1), length: 0))
            let call = MonotonicClock.ms(t)
            let settle = Bench.settle(scroll)
            let r = Bench.renderOffscreen(scroll, rect: scroll.bounds, savesTo: png ? "textview_\(lineCount)_\(key)" : nil)
            out["\(key)_call_ms"] = call
            out["\(key)_settle_ms"] = settle
            out["\(key)_render_ms"] = r.ms
            out["\(key)_work_ms"] = call + settle + r.ms
        }
        jump(attributed.length - 1, "jump_end", png: true)
        jump(starts[lineCount / 2], "jump_mid", png: true)
        jump(0, "jump_top")
        let mem2 = footprintMB()

        // 5. 尚未整篇排版时的预热连续滚动（LazyVStack / List 的同等状态）
        if let sv = textView.enclosingScrollView {
            for (k, v) in Bench.scrollSteps(clip: sv.contentView, docHeight: textView.frame.height, view: scroll) { out[k] = v }
        }
        let mem3 = footprintMB()

        // 6. 整篇布局（看前面的跳转和滚动是否已经把全文排完）
        if let lm = textView.textLayoutManager {
            let t = MonotonicClock.now
            lm.ensureLayout(for: lm.documentRange)
            out["full_layout_remaining_ms"] = MonotonicClock.ms(t)
        }
        out["laid_out_height_pt"] = Double(textView.frame.height)
        out["line_height_pt"] = Double(textView.lineHeight)
        out["mem_full_layout_extra_mb"] = footprintMB() - mem3

        out["mem_delta_first_mb"] = mem1 - mem0
        out["mem_delta_jumps_mb"] = mem2 - mem0
        out["mem_delta_steps_mb"] = mem3 - mem0
        win.orderOut(nil)
        return out
    }
}
