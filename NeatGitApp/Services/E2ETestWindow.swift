import AppKit
import SwiftUI

/// `--e2e-testing` 模式下的窗口宿主。
///
/// 背景启动（`open -g`）时 SwiftUI 的 `WindowGroup` 不会创建 NSWindow：macOS 26 上
/// 窗口只在 App 被激活时才 ordering，验收又禁止抢前台，于是进程健康但没有任何窗口可截图。
/// 这条路径自己持有一个 AppKit 窗口，用 `orderBack(nil)` 排到其它窗口之后——仍在当前
/// Space 上、可被 `screencapture -l` 窗口级截图，但不激活 App、不移动光标。
///
/// 只有显式传入 `--e2e-testing` 才生效，生产路径（无参数启动）完全不变。
@MainActor
final class E2ETestWindowController {
    static let shared = E2ETestWindowController()

    private var window: NSWindow?

    func presentWindowIfNeeded() {
        guard LaunchOptions.isE2ETesting, window == nil else { return }

        let contentSize = LaunchOptions.e2eWindowSize
        // 屏幕放得下就整窗留出余量，否则收到可见高度。基准确定用主屏（菜单栏所在屏），
        // 不用 NSScreen.main：它跟着键盘焦点走，窗口尺寸会随启动时机在多个屏之间跳动。
        let visible = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let fitted = NSSize(
            width: min(contentSize.width, visible.width - 40),
            height: min(contentSize.height, visible.height - 80)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: fitted),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NeatGit"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 960, height: 600)
        window.contentView = NSHostingView(
            rootView: ContentView(
                llmSettingsStore: LLMSettingsStore(),
                aiCommitDebugStore: AICommitDebugStore()
            )
        )
        window.setContentSize(fitted)
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 20, y: visible.maxY - 20))
        window.orderBack(nil)
        window.contentView?.displayIfNeeded()
        self.window = window
    }
}

final class NeatGitApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        E2ETestWindowController.shared.presentWindowIfNeeded()
    }
}
