import AppKit
import SwiftUI

/// 一侧面板：滚动视图 + 只读文本视图。负责装配 TextKit 2、应用内容、定尺寸和滚动联动。
@MainActor
final class NativeDiffPaneController {
    let scrollView = NativeDiffScrollView()
    let textView: NativeDiffTextView
    private let textContainer: NSTextContainer
    private(set) var content: NativeDiffPaneContent?
    private var isSyncing = false

    /// 用户滚动这一栏时回调，参数是滚动位置；用于并排时联动另一栏。
    var onScroll: ((NSPoint) -> Void)?

    /// `identifier` 是文本视图的辅助功能标识：并排时左栏 file-diff-original、右栏 file-diff-modified，单栏 file-diff-unified。
    init(accessibilityIdentifier identifier: String) {
        // TextKit 2：内容存储 → 布局管理器 → 文本容器 → 文本视图。
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        // 容器高度一律用有限值，由 fitWidth() 按内容行数精确设定。
        textContainer = NSTextContainer(size: NSSize(width: 4_000, height: 1))
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        layoutManager.textContainer = textContainer

        textView = NativeDiffTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        // 行号栏的宽度就是左侧内边距：正文从行号栏右边开始，行号画在这块留白里。
        textView.textContainerInset = NSSize(width: NativeDiffStyle.make().gutterWidth, height: 8)
        // 尺寸由本类按行数精确设定，不让文本视图自己伸缩。
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.usesFontPanel = false
        textView.allowsUndo = false
        textView.setAccessibilityIdentifier(identifier)

        // 必须先换成能感知滚动的裁剪视图，再挂文档视图。
        // 反过来的话，文档视图会留在被换掉的旧裁剪视图里，从此不在窗口层级内：
        // 真实窗口里表现为内容区整片空白、排版高度恒为 0、文本视图没有图层。
        let clipView = NativeDiffClipView()
        scrollView.contentView = clipView
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        // 视图在标题栏和头部栏下方，系统不需要再替它留出标题栏的留白。
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.onLayout = { [weak self] in self?.fitWidth() }

        // 并排联动统一走系统位置变化通知；不再同时叠加 setBoundsOrigin 回调，
        // 避免同一次滚动把另一侧同步两遍、在滚动帧里放大主线程工作。
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        guard !isSyncing else { return }
        onScroll?(scrollView.contentView.bounds.origin)
    }

    /// 滚动位置的锚点：视口顶部落在哪一行、偏移多少。
    struct ScrollAnchor: Equatable {
        let row: Int
        let offset: CGFloat
    }

    /// 应用新内容。同一批内容只应用一次。
    ///
    /// 换内容后行数会变（展开折叠行、开关「只看变更」），按 `anchor` 恢复滚动位置，不跳回顶部。
    func apply(_ newContent: NativeDiffPaneContent, restoring anchor: ScrollAnchor? = nil) {
        if let content, content.id == newContent.id {
            return
        }
        content = newContent
        textView.lineStyles = newContent.lineStyles
        textView.paragraphStarts = newContent.paragraphStarts
        textView.numberTexts = newContent.numberTexts
        textView.expanderKeys = newContent.expanderKeys
        textView.rowHeight = newContent.rowHeight
        textView.characterAdvance = newContent.characterAdvance
        InteractionProfiler.measure("原生差异.文本存储更新", detail: "显示行数：\(newContent.lines.count)") {
            textView.textStorage?.setAttributedString(newContent.attributed)
        }
        InteractionProfiler.measure("原生差异.几何更新") {
            fitWidth()
        }
        guard let anchor, anchor.row < newContent.lines.count else {
            scrollToTop()
            return
        }
        scroll(to: NSPoint(x: 0, y: CGFloat(anchor.row) * newContent.rowHeight + anchor.offset), notify: false)
    }

    /// 视口顶部往上最近的一行改动：它所在行的下标，以及视口顶部相对它的偏移。
    ///
    /// 只在「视口已经滚过一部分、上方有过改动行」时才有锚点；改动行在展开折叠行前后都存在，行下标只在它前面增减。
    func visibleAnchor() -> ScrollAnchor? {
        guard let content else { return nil }
        let top = scrollView.contentView.bounds.minY
        var row = Int(top / content.rowHeight)
        guard row >= 0, row < content.lines.count else { return nil }
        while row >= 0 {
            if content.lines[row].number != nil, content.lines[row].style != .context {
                return ScrollAnchor(row: row, offset: top - CGFloat(row) * content.rowHeight)
            }
            row -= 1
        }
        return nil
    }

    /// 按内容与可视宽度定尺寸：宽度取「内容需要的宽度」与「可视宽度」里较大的那个，高度按行数精确计算。
    ///
    /// 文本容器的高度必须是有限值，等于按行数算出的文档高度。不能把它设成「无限高」：
    /// 那样在有内容之后再改容器尺寸（窗口变宽、切换文件都会走到这里），系统会在内部
    /// 通知旧版排版器容器几何变化时直接崩溃。容器高度比全部行略高一点，行又都是固定行高，
    /// 所以内容不会被截断。
    func fitWidth() {
        guard let content else { return }
        let gutter = textView.textContainerInset.width
        let visibleWidth = scrollView.contentSize.width
        let width = max(content.contentWidth, visibleWidth - gutter)
        let inset = textView.textContainerInset.height
        let containerHeight = content.documentHeight
        let height = containerHeight + inset * 2

        if abs(textContainer.size.width - width) > 0.5 || textContainer.size.height != containerHeight {
            textContainer.size = NSSize(width: width, height: containerHeight)
        }
        var frame = textView.frame
        if abs(frame.width - (width + gutter)) > 0.5 || abs(frame.height - height) > 0.5 {
            frame.size = NSSize(width: width + gutter, height: height)
            textView.frame = frame
        }
    }

    func scrollToTop() {
        scroll(to: .zero, notify: false)
    }

    /// 滚动到文档末尾。
    func scrollToEnd() {
        guard let content else { return }
        scroll(to: NSPoint(x: 0, y: max(content.documentHeight - scrollView.contentSize.height, 0)), notify: false)
    }

    /// 滚动到指定位置。`notify` 为真时当作用户滚动，通知并排的另一栏跟随。
    func scroll(to origin: NSPoint, notify: Bool) {
        isSyncing = true
        let clipView = scrollView.contentView
        let current = clipView.bounds.origin
        if abs(current.x - origin.x) > 0.5 || abs(current.y - origin.y) > 0.5 {
            clipView.scroll(to: NSPoint(x: origin.x, y: origin.y))
            scrollView.reflectScrolledClipView(clipView)
        }
        let landed = clipView.bounds.origin
        isSyncing = false
        if notify {
            onScroll?(landed)
        }
    }

    /// 跟随另一栏滚动到同一位置。两栏行数相同、行高相同，位置可以直接照搬。
    func scroll(to origin: NSPoint) {
        guard !isSyncing else { return }
        scroll(to: origin, notify: false)
    }
}

/// 滚动视图：布局完成后回调一次，让面板按新的可视宽度重新定宽。
@MainActor
final class NativeDiffScrollView: NSScrollView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// 裁剪视图：滚动位置统一通过系统 bounds 通知上报，避免双通道重复联动。
@MainActor
final class NativeDiffClipView: NSClipView {}

/// 差异视图的容器：并排时左右两栏等分宽度、中间一条分隔线，单栏时占满；内容还在后台准备时显示提示。
@MainActor
final class NativeDiffContainerView: NSView {
    private let divider = NSBox()
    private let spinner = NSProgressIndicator()
    private let preparationLabel = NSTextField(labelWithString: "正在准备差异…")
    private var panes: [NativeDiffPaneController] = []
    private var showsPreparation = false

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        divider.boxType = .custom
        divider.fillColor = .separatorColor
        divider.borderWidth = 0
        divider.cornerRadius = 0
        divider.isHidden = true
        addSubview(divider)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        addSubview(spinner)

        preparationLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        preparationLabel.textColor = .secondaryLabelColor
        preparationLabel.alignment = .center
        preparationLabel.sizeToFit()
        preparationLabel.isHidden = true
        addSubview(preparationLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("不支持从界面文件加载")
    }

    func install(_ newPanes: [NativeDiffPaneController]) {
        let unchanged = panes.count == newPanes.count && zip(panes, newPanes).allSatisfy { $0 === $1 }
        guard !unchanged else { return }
        panes.forEach { $0.scrollView.removeFromSuperview() }
        panes = newPanes
        for pane in newPanes {
            addSubview(pane.scrollView, positioned: .below, relativeTo: nil)
        }
        divider.isHidden = newPanes.count < 2
        // 分隔线、准备提示依次放回最上层，都排在滚动视图之上。
        for overlay in [divider, spinner, preparationLabel] {
            overlay.removeFromSuperview()
            addSubview(overlay)
        }
        needsLayout = true
    }

    func setExpansionHandler(_ handler: @escaping (Int) -> Void) {
        for pane in panes {
            pane.textView.onExpand = handler
        }
    }

    /// 是否显示「正在准备差异」。
    func setPreparing(_ preparing: Bool) {
        guard preparing != showsPreparation else { return }
        showsPreparation = preparing
        spinner.isHidden = !preparing
        preparationLabel.isHidden = !preparing
        if preparing {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard !panes.isEmpty else { return }
        if panes.count == 2 {
            let paneWidth = floor((bounds.width - 1) / 2)
            let left = panes[0]
            let right = panes[1]
            left.scrollView.frame = NSRect(x: 0, y: 0, width: paneWidth, height: bounds.height)
            right.scrollView.frame = NSRect(x: paneWidth + 1, y: 0, width: bounds.width - paneWidth - 1, height: bounds.height)
            divider.frame = NSRect(x: paneWidth, y: 0, width: 1, height: bounds.height)
            left.onScroll = { [weak right] origin in right?.scroll(to: origin) }
            right.onScroll = { [weak left] origin in left?.scroll(to: origin) }
        } else {
            panes[0].scrollView.frame = bounds
            panes[0].onScroll = nil
        }
        for pane in panes {
            pane.fitWidth()
        }

        let spacing: CGFloat = 8
        let totalWidth = spinner.frame.width + spacing + preparationLabel.frame.width
        let originX = floor((bounds.width - totalWidth) / 2)
        let originY = floor(bounds.height / 2) - 10
        spinner.frame.origin = NSPoint(x: originX, y: originY)
        preparationLabel.frame.origin = NSPoint(x: originX + spinner.frame.width + spacing, y: originY - 1)
    }
}

/// 把原生差异视图装进 SwiftUI。
///
/// 输入是加载好的差异文档（逐行对照结果已由加载时的后台任务算好）。把对照结果变成富文本是后台做的，
/// 期间又换了文档、布局或开关的话，旧批次的结果直接丢弃。
struct NativeDiffView: NSViewRepresentable {
    let document: RepositoryDiffDocument?
    let layout: NativeDiffLayout
    let showChangesOnly: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NativeDiffContainerView {
        let view = NativeDiffContainerView()
        context.coordinator.render(into: view, document: document, layout: layout, showChangesOnly: showChangesOnly)
        return view
    }

    func updateNSView(_ view: NativeDiffContainerView, context: Context) {
        context.coordinator.render(into: view, document: document, layout: layout, showChangesOnly: showChangesOnly)
    }

    static func dismantleNSView(_ view: NativeDiffContainerView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        private static let maxCachedRenders = 4
        /// 小文档的异步调度成本高于准备本身；严格限量后才允许走主线程快速路径。
        private static let fastRenderMaxRows = 256
        private static let fastRenderMaxTextBytes = 64_000

        /// 一次渲染的输入。文档只比较加载版本，不比较两份全文。
        private struct Request: Equatable {
            let document: RepositoryDiffDocument?
            let layout: NativeDiffLayout
            let showChangesOnly: Bool
            var expanded: Set<Int>

            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.document?.renderingID == rhs.document?.renderingID
                    && lhs.layout == rhs.layout
                    && lhs.showChangesOnly == rhs.showChangesOnly
                    && lhs.expanded == rhs.expanded
            }
        }

        private struct RenderCacheKey: Hashable {
            let renderingID: UUID
            let layout: NativeDiffLayout
            let showChangesOnly: Bool
            let expanded: Set<Int>
        }

        /// 按布局缓存面板：并排 2 个、单栏 1 个，切换布局时换一套。
        private var sideBySide: [NativeDiffPaneController]?
        private var unified: [NativeDiffPaneController]?
        private var current: Request?
        /// 面板里现有内容对应的文档版本（没有内容时为 nil）。
        private var renderedDocument: RepositoryDiffDocument?
        /// 批次号与任务取消双重保护：旧结果既尽快停止，也不能迟到上屏。
        private var generation = 0
        private var renderTask: Task<Void, Never>?
        /// 小型 LRU：保留最近几种布局/折叠组合，避免来回切换重复构建富文本。
        private var renderCache: [RenderCacheKey: NativeDiffRenderResult] = [:]
        private var renderCacheOrder: [RenderCacheKey] = []

        func render(into view: NativeDiffContainerView, document: RepositoryDiffDocument?, layout: NativeDiffLayout, showChangesOnly: Bool) {
            // 换了文档，上一份文档里展开过的折叠行不再有意义。
            var expanded = current?.expanded ?? []
            if document?.renderingID != current?.document?.renderingID { expanded = [] }
            let request = Request(document: document, layout: layout, showChangesOnly: showChangesOnly, expanded: expanded)
            guard request != current else { return }
            current = request
            begin(into: view)
        }

        /// 展开一处被折叠的未变更内容。折叠键是它在完整差异行里的下标。
        func expand(_ key: Int, in view: NativeDiffContainerView) {
            InteractionProfiler.measure("展开未变更内容.点击处理") {
                guard var request = current, request.document != nil else { return }
                guard !request.expanded.contains(key) else { return }
                request.expanded.insert(key)
                current = request
                begin(into: view)
            }
        }

        func stop() {
            generation += 1
            renderTask?.cancel()
            renderTask = nil
            current = nil
            renderedDocument = nil
            renderCache.removeAll()
            renderCacheOrder.removeAll()
        }

        private func begin(into view: NativeDiffContainerView) {
            guard let request = current else { return }
            renderTask?.cancel()
            generation += 1
            let id = generation

            if request.layout == .sideBySide, sideBySide == nil {
                sideBySide = [NativeDiffPaneController(accessibilityIdentifier: "file-diff-original"), NativeDiffPaneController(accessibilityIdentifier: "file-diff-modified")]
            }
            if request.layout == .unified, unified == nil {
                unified = [NativeDiffPaneController(accessibilityIdentifier: "file-diff-unified")]
            }
            let panes = request.layout == .sideBySide ? (sideBySide ?? []) : (unified ?? [])
            view.install(panes)
            view.setExpansionHandler { [weak self, weak view] key in
                guard let view else { return }
                self?.expand(key, in: view)
            }

            // 换了文档：面板里如果还是别的文档的内容（切回来布局时会遇到），先清空，
            // 避免新结果到达前闪现旧文件；没装在界面上的那一套面板也一起清，大文件的内容不继续占着内存。
            if request.document?.renderingID != renderedDocument?.renderingID {
                renderedDocument = request.document
                for pane in (sideBySide ?? []) + (unified ?? []) where pane.content?.id != 0 {
                    pane.apply(.empty(id: 0))
                }
            }

            guard let document = request.document else {
                view.setPreparing(false)
                return
            }

            let cacheKey = RenderCacheKey(
                renderingID: document.renderingID,
                layout: request.layout,
                showChangesOnly: request.showChangesOnly,
                expanded: request.expanded
            )
            if let cached = renderCache[cacheKey] {
                InteractionProfiler.event("原生差异.渲染缓存命中")
                apply(cached, to: panes, in: view, document: document)
                return
            }

            let visibleInterval = InteractionProfiler.begin("原生差异.可见更新")
            let textBytes = document.originalText.utf8.count + document.modifiedText.utf8.count
            if document.rows.count <= Self.fastRenderMaxRows, textBytes <= Self.fastRenderMaxTextBytes {
                do {
                    let result = try InteractionProfiler.measure("原生差异.小文档快速准备", detail: "对照行数：\(document.rows.count)") {
                        try NativeDiffRenderBuilder.render(
                            document: document,
                            layout: request.layout,
                            showChangesOnly: request.showChangesOnly,
                            expanded: request.expanded,
                            id: id
                        )
                    }
                    cache(result, for: cacheKey)
                    apply(result, to: panes, in: view, document: document)
                    visibleInterval.end("小文档快速路径完成")
                } catch {
                    view.setPreparing(false)
                    visibleInterval.end("快速准备失败")
                    InteractionProfiler.event("原生差异.准备失败", detail: error.localizedDescription)
                }
                return
            }

            view.setPreparing(true)
            renderTask = Task {
                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                        try InteractionProfiler.measure("原生差异.后台准备", detail: "对照行数：\(document.rows.count)") {
                            try NativeDiffRenderBuilder.render(
                                document: document,
                                layout: request.layout,
                                showChangesOnly: request.showChangesOnly,
                                expanded: request.expanded,
                                id: id
                            )
                        }
                    }.value
                    try Task.checkCancellation()
                    guard id == generation else {
                        visibleInterval.end("丢弃过期结果")
                        return
                    }
                    cache(result, for: cacheKey)
                    apply(result, to: panes, in: view, document: document)
                    visibleInterval.end("后台准备并应用完成")
                } catch is CancellationError {
                    visibleInterval.end("已被更新点击取消")
                    InteractionProfiler.event("原生差异.取消过期渲染")
                } catch {
                    visibleInterval.end("准备失败")
                    view.setPreparing(false)
                    InteractionProfiler.event("原生差异.准备失败", detail: error.localizedDescription)
                }
            }
        }

        private func apply(
            _ result: NativeDiffRenderResult,
            to panes: [NativeDiffPaneController],
            in view: NativeDiffContainerView,
            document: RepositoryDiffDocument
        ) {
            InteractionProfiler.measure("原生差异.主线程应用", detail: "面板数：\(result.panes.count)") {
                renderedDocument = document
                view.setPreparing(false)
                // 并排时两栏逐行对应，必须按同一个行下标恢复，不能各找各的。
                let anchors = panes.map { $0.visibleAnchor() }
                let anchor = anchors.allSatisfy { $0 != nil } ? anchors[0] : nil
                for (pane, content) in zip(panes, result.panes) {
                    pane.apply(content, restoring: anchor)
                }
            }
        }

        private func cache(_ result: NativeDiffRenderResult, for key: RenderCacheKey) {
            renderCache[key] = result
            renderCacheOrder.removeAll { $0 == key }
            renderCacheOrder.append(key)
            while renderCacheOrder.count > Self.maxCachedRenders {
                renderCache.removeValue(forKey: renderCacheOrder.removeFirst())
            }
        }
    }
}
