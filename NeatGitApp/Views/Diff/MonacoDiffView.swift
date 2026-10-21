import Observation
import SwiftUI
import WebKit

struct MonacoDiffView: View {
    let payload: MonacoDiffPayload?
    let showChangesOnly: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var controller: MonacoDiffController

    init(
        payload: MonacoDiffPayload?,
        showChangesOnly: Bool = false,
        controller: MonacoDiffController = MonacoDiffController()
    ) {
        self.payload = payload
        self.showChangesOnly = showChangesOnly
        _controller = State(initialValue: controller)
    }

    private var appearance: MonacoAppearance {
        MonacoAppearance(
            isDark: colorScheme == .dark,
            highContrast: colorSchemeContrast == .increased
        )
    }

    var body: some View {
        ZStack {
            WebView(controller.page)
                .opacity(controller.errorMessage == nil && payload != nil ? 1 : 0)
                .accessibilityHidden(controller.errorMessage != nil || payload == nil)
                .allowsHitTesting(controller.errorMessage == nil && payload != nil)

            if let errorMessage = controller.errorMessage {
                ContentUnavailableView {
                    Label("代码预览加载失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试") {
                        controller.retry()
                    }
                }
            } else if controller.isLoading {
                // 与面板层 loading 胶囊同一样式，保证在网页内容之上的对比度。
                ProgressView("正在加载代码预览…")
                    .padding()
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
            }
        }
        .onChange(of: payload, initial: true) { _, payload in
            controller.update(payload: payload)
        }
        .onChange(of: showChangesOnly, initial: true) { _, showChangesOnly in
            controller.update(showChangesOnly: showChangesOnly)
        }
        .onChange(of: appearance, initial: true) { _, appearance in
            controller.update(appearance: appearance)
        }
        .onAppear {
            controller.start()
        }
        .onDisappear {
            controller.stop()
        }
    }
}

struct MonacoAppearance: Equatable {
    var isDark = false
    var highContrast = false
}

@MainActor
@Observable
final class MonacoDiffController {
    private(set) var page = makePage()
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    @ObservationIgnored private var pendingPayload: MonacoDiffPayload?
    @ObservationIgnored private var lastRenderedPayload: MonacoDiffPayload?
    @ObservationIgnored private var pendingChangesOnly = false
    @ObservationIgnored private var lastRenderedChangesOnly: Bool?
    @ObservationIgnored private var pendingAppearance = MonacoAppearance()
    @ObservationIgnored private var lastRenderedAppearance: MonacoAppearance?
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var isReady = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?

    private static func makePage() -> WebPage {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WebPage(configuration: configuration)
        #if DEBUG
        page.isInspectable = true
        #endif
        return page
    }

    func update(payload: MonacoDiffPayload?) {
        pendingPayload = payload
        renderIfPossible()
    }

    func update(showChangesOnly: Bool) {
        pendingChangesOnly = showChangesOnly
        renderIfPossible()
    }

    func update(appearance: MonacoAppearance) {
        pendingAppearance = appearance
        renderIfPossible()
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        loadPage()
    }

    func stop() {
        isActive = false
        invalidateTasks()
    }

    func retry() {
        guard isActive else { return }
        loadPage()
    }

    private func invalidateTasks() {
        generation = UUID()
        loadTask?.cancel()
        renderTask?.cancel()
        timeoutTask?.cancel()
        loadTask = nil
        renderTask = nil
        timeoutTask = nil
        page.stopLoading()
        isReady = false
        isLoading = false
        lastRenderedPayload = nil
        lastRenderedAppearance = nil
        lastRenderedChangesOnly = nil
    }

    private func loadPage() {
        invalidateTasks()
        // 仅重试或视图重新出现时重建，隔离已取消页面中尚未返回的 JavaScript。
        page = Self.makePage()
        errorMessage = nil
        isLoading = true
        let generation = generation
        let page = page
        armTimeout(seconds: 15, message: "代码预览加载超时，请重试。", generation: generation)

        loadTask = Task { [weak self] in
            do {
                let url = try await MonacoResourceLoader.shared.pageURL()
                try Task.checkCancellation()
                var didFinish = false
                for try await event in page.load(URLRequest(url: url, timeoutInterval: 15)) {
                    try Task.checkCancellation()
                    if event == .finished {
                        didFinish = true
                        break
                    }
                }
                guard didFinish else { throw MonacoPreviewError.navigationIncomplete }
                let ready = try await page.callJavaScript("""
                    return typeof window.neatGit?.setDiff === 'function'
                        && typeof window.neatGit?.setAppearance === 'function'
                        && typeof window.neatGit?.setChangesOnly === 'function';
                    """)
                try Task.checkCancellation()
                guard ready as? Bool == true else { throw MonacoPreviewError.bridgeUnavailable }
                guard let self, self.generation == generation, self.isActive else { return }
                self.timeoutTask?.cancel()
                self.timeoutTask = nil
                self.loadTask = nil
                self.isReady = true
                self.isLoading = false
                self.renderIfPossible()
            } catch {
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                self.fail(message: (error as? MonacoPreviewError)?.errorDescription ?? "无法加载代码预览，请重试。")
            }
        }
    }

    private func renderIfPossible() {
        guard isActive, isReady, renderTask == nil, errorMessage == nil else { return }
        guard pendingAppearance != lastRenderedAppearance
            || pendingPayload != lastRenderedPayload
            || pendingChangesOnly != lastRenderedChangesOnly else { return }
        let generation = generation
        let page = page

        // 单一消费者串行提交；等待期间只替换待渲染值，不开启会相互覆盖的新任务。
        renderTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == generation {
                    self.renderTask = nil
                    self.timeoutTask?.cancel()
                    self.timeoutTask = nil
                }
            }
            do {
                while !Task.isCancelled, self.generation == generation, self.isReady {
                    let appearance = self.pendingAppearance
                    let payload = self.pendingPayload
                    let changesOnly = self.pendingChangesOnly
                    let appearanceChanged = appearance != self.lastRenderedAppearance
                    let payloadChanged = payload != nil && payload != self.lastRenderedPayload
                    let changesOnlyChanged = changesOnly != self.lastRenderedChangesOnly
                    guard appearanceChanged || payloadChanged || changesOnlyChanged else { return }
                    self.armTimeout(seconds: 10, message: "代码预览更新超时，请重试。", generation: generation)

                    if appearanceChanged {
                        try await page.callJavaScript("""
                            window.neatGit.setAppearance(appearance, highContrast);
                            """, arguments: [
                                "appearance": appearance.isDark ? "dark" : "light",
                                "highContrast": appearance.highContrast
                            ])
                        try Task.checkCancellation()
                        guard self.generation == generation else { return }
                        self.lastRenderedAppearance = appearance
                        // 外观调用期间内容可能已变；下一轮重新取最新值，避免注入旧快照。
                        continue
                    }

                    if payloadChanged, let payload {
                        let data = try JSONEncoder().encode(payload)
                        let json = String(decoding: data, as: UTF8.self)
                        try await page.callJavaScript("""
                            window.neatGit.setDiff(JSON.parse(payloadJSON));
                            """, arguments: ["payloadJSON": json])
                        try Task.checkCancellation()
                        guard self.generation == generation else { return }
                        self.lastRenderedPayload = payload
                        continue
                    }

                    // 只看变更是渲染开关，不走内容通道，切换时无需重新序列化整份文件。
                    if changesOnlyChanged {
                        try await page.callJavaScript("""
                            window.neatGit.setChangesOnly(showChangesOnly);
                            """, arguments: ["showChangesOnly": changesOnly])
                        try Task.checkCancellation()
                        guard self.generation == generation else { return }
                        self.lastRenderedChangesOnly = changesOnly
                    }
                }
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return }
                self.fail(message: "无法更新代码预览，请重试。")
            }
        }
    }

    private func armTimeout(seconds: Int, message: String, generation: UUID) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            self.fail(message: message)
        }
    }

    private func fail(message: String) {
        invalidateTasks()
        errorMessage = message
    }
}

// 静态服务同步启动会等待监听器；移出主线程，并在多个预览之间复用同一次启动。
private actor MonacoResourceLoader {
    static let shared = MonacoResourceLoader()
    private var startupTask: Task<URL, Error>?

    func pageURL() async throws -> URL {
        if let startupTask {
            return try await startupTask.value
        }
        let task = Task.detached {
            guard let resourceURL = Bundle.main.resourceURL else {
                throw MonacoPreviewError.resourcesUnavailable
            }
            let serverURL = try BundleStaticFileServer.shared.startIfNeeded(rootDirectoryURL: resourceURL)
            return serverURL.appendingPathComponent("index.html")
        }
        startupTask = task
        do {
            return try await task.value
        } catch {
            startupTask = nil
            throw error
        }
    }
}

private enum MonacoPreviewError: LocalizedError {
    case resourcesUnavailable
    case navigationIncomplete
    case bridgeUnavailable

    var errorDescription: String? {
        switch self {
        case .resourcesUnavailable:
            "找不到代码预览资源，请重新安装应用。"
        case .navigationIncomplete:
            "代码预览页面未完成加载，请重试。"
        case .bridgeUnavailable:
            "代码预览组件未能初始化，请重试。"
        }
    }
}
