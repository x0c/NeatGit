import AppKit
import Observation
import SwiftUI
import WebKit
import XCTest
@testable import NeatGit

@MainActor
final class MonacoWebViewTests: XCTestCase {
    func testNativeWebViewLoadsBundleRendersLatestPayloadAndTracksAppearance() async throws {
        let state = PreviewState()
        state.payload = payload(path: "初始化.swift", text: "let message = \"准备\"\n")
        let host = NSHostingController(rootView: PreviewHarness(state: state))
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 720, height: 460))
        window.orderFront(nil)
        defer { window.close() }

        let webView = try await waitForWebView(in: host.view)
        try await recordInjectedPayloads(in: webView)
        state.payload = payload(path: "原生验证.swift", text: "let message = \"第一个版本\"\n")
        try await waitForJavaScript(webView, expression: "window.__neatGitTestPayloads?.at(-1)?.modifiedText.includes('第一个版本') === true")
        XCTAssertFalse(webView.configuration.websiteDataStore.isPersistent)
        let originalURL = webView.url
        XCTAssertEqual(originalURL?.host, "127.0.0.1")

        for index in 0..<20 {
            state.payload = payload(path: "切换\(index).swift", text: "let message = \"最后版本\(index)\"\n")
        }
        try await waitForJavaScript(webView, expression: "window.__neatGitTestPayloads?.at(-1)?.modifiedText.includes('最后版本19') === true")
        XCTAssertEqual(webView.url, originalURL, "连续切换内容不能重新加载网页。")

        state.colorScheme = .dark
        try await waitForJavaScript(webView, expression: "document.documentElement.dataset.appearance === 'dark'")
        try await waitForJavaScript(webView, expression: "document.querySelector('.monaco-editor.vs-dark') !== null")
        _ = try await webView.evaluateJavaScript("window.neatGit.setAppearance('dark', true)")
        try await waitForJavaScript(webView, expression: "document.querySelector('.monaco-editor.hc-black') !== null")

        state.colorScheme = .light
        try await waitForJavaScript(webView, expression: "document.querySelector('.monaco-editor.vs') !== null")
        let screenshot = try await webView.takeSnapshot(configuration: nil)
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "macOS 26 原生 WebView 差异预览"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testJavaScriptFailureShowsNativeErrorAndRetryRecovers() async throws {
        let state = PreviewState()
        state.payload = payload(path: "失败恢复.swift", text: "let state = \"初始\"\n")
        let host = NSHostingController(rootView: PreviewHarness(state: state))
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 720, height: 460))
        window.orderFront(nil)
        defer { window.close() }

        let webView = try await waitForWebView(in: host.view)
        try await waitForJavaScript(webView, expression: "typeof window.neatGit?.setDiff === 'function'")
        _ = try await webView.evaluateJavaScript("window.neatGit.setDiff = () => { throw new Error('预埋注入失败'); }; true;")
        state.payload = payload(path: "恢复后.swift", text: "let state = \"恢复成功\"\n")

        for _ in 0..<100 {
            if state.controller.errorMessage != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(state.controller.errorMessage, "无法更新代码预览，请重试。", "失败要进入中文错误状态，不能静默白屏。")
        state.controller.retry()
        let recoveredWebView = try await waitForWebView(in: host.view, differentFrom: webView)
        try await recordInjectedPayloads(in: recoveredWebView)
        state.payload = payload(path: "恢复后再次切换.swift", text: "let state = \"恢复成功\"\n")
        try await waitForJavaScript(recoveredWebView, expression: "window.__neatGitTestPayloads?.at(-1)?.modifiedText.includes('恢复成功') === true")
        XCTAssertNil(state.controller.errorMessage)
    }

    func testChangesOnlyFoldsUnchangedRegionsWithContextWithoutResendingContent() async throws {
        let state = PreviewState()
        // 前后各一大段未变更内容，中间改一行，用于验证折叠与上下文行。
        let prefix = (1...40).map { "let value\($0) = \($0)\n" }.joined()
        let suffix = (41...80).map { "let value\($0) = \($0)\n" }.joined()
        let original = MonacoDiffPayload(
            filePath: "只看变更.swift",
            modeTitle: "未暂存",
            originalLabel: "暂存区",
            modifiedLabel: "工作区",
            originalText: prefix + "let target = \"原值\"\n" + suffix,
            modifiedText: prefix + "let target = \"新值\"\n" + suffix,
            languageHint: "swift"
        )
        state.payload = original
        let host = NSHostingController(rootView: PreviewHarness(state: state))
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1200, height: 600))
        window.orderFront(nil)
        defer { window.close() }

        let webView = try await waitForWebView(in: host.view)
        try await recordInjectedPayloads(in: webView)
        try await waitForJavaScript(webView, expression: "document.querySelectorAll('.diff-hidden-lines').length === 0")
        // 包装安装时初始内容可能已注入过，这里取基线再比较增量。
        let baseline = try await webView.evaluateJavaScript("window.__neatGitTestPayloads.length") as? Int ?? 0

        state.showChangesOnly = true
        // 折叠块出现，且变更行前后的上下文行仍然可见，行号保持真实值。
        try await waitForJavaScript(webView, expression: """
            (() => {
                if (document.querySelectorAll('.diff-hidden-lines').length === 0) { return false; }
                // Monaco 用不换行空格渲染缩进，比较前先归一。
                const lines = [...document.querySelectorAll('.editor.modified .view-line')]
                    .map(n => n.textContent.replace(/\\u00a0/g, ' '));
                const numbers = [...document.querySelectorAll('.editor.modified .line-numbers')]
                    .map(n => n.textContent);
                return lines.some(l => l.includes('let target = "新值"'))
                    && lines.some(l => l.includes('let value40 ='))
                    && lines.some(l => l.includes('let value41 ='))
                    && !lines.some(l => l.includes('let value1 ='))
                    && numbers.includes('41');
            })()
            """)
        // 切换开关不得重传文件内容。
        let injectedAfterToggle = try await webView.evaluateJavaScript("window.__neatGitTestPayloads.length") as? Int
        XCTAssertEqual(injectedAfterToggle, baseline, "切换只看变更应走独立通道，不重传整份文件。")

        state.showChangesOnly = false
        try await waitForJavaScript(webView, expression: "document.querySelectorAll('.diff-hidden-lines').length === 0")
        let injectedAfterRestore = try await webView.evaluateJavaScript("window.__neatGitTestPayloads.length") as? Int
        XCTAssertEqual(injectedAfterRestore, baseline, "关闭只看变更同样不应重传内容。")
    }

    private func recordInjectedPayloads(in webView: WKWebView) async throws {
        try await waitForJavaScript(webView, expression: "typeof window.neatGit?.setDiff === 'function'")
        // 锁屏下 WebKit 暂停可视文本绘制；记录真实桥接成功调用，不把它当作视觉验收。
        _ = try await webView.evaluateJavaScript("""
            (() => {
                window.__neatGitTestPayloads = [];
                const setDiff = window.neatGit.setDiff;
                window.neatGit.setDiff = payload => {
                    setDiff(payload);
                    window.__neatGitTestPayloads.push(payload);
                };
                return true;
            })();
            """)
    }

    private func payload(path: String, text: String) -> MonacoDiffPayload {
        MonacoDiffPayload(filePath: path, modeTitle: "未暂存", originalLabel: "暂存区", modifiedLabel: "工作区", originalText: "let message = \"原始\"\n", modifiedText: text, languageHint: "swift")
    }

    private func waitForWebView(in view: NSView, differentFrom previous: WKWebView? = nil) async throws -> WKWebView {
        for _ in 0..<100 {
            if let webView = descendants(of: view, type: WKWebView.self).first, webView !== previous {
                return webView
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "NeatGitTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "未创建可验证的原生 WebView 宿主。"])
    }

    private func waitForJavaScript(_ webView: WKWebView, expression: String) async throws {
        for _ in 0..<300 {
            if (try? await webView.evaluateJavaScript(expression)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "NeatGitTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "网页状态未在 15 秒内满足：\(expression)"])
    }

    private func descendants<T: NSView>(of view: NSView, type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(of: $0, type: type) }
    }
}

@MainActor
@Observable
private final class PreviewState {
    var payload: MonacoDiffPayload?
    var colorScheme = ColorScheme.light
    var showChangesOnly = false
    let controller = MonacoDiffController()
}

private struct PreviewHarness: View {
    let state: PreviewState

    var body: some View {
        MonacoDiffView(
            payload: state.payload,
            showChangesOnly: state.showChangesOnly,
            controller: state.controller
        )
        .environment(\.colorScheme, state.colorScheme)
    }
}
