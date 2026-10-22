import AppKit
import Observation
import SwiftUI
import XCTest
@testable import NeatGit

@MainActor
final class NativeControlsTests: XCTestCase {
    func testSidebarUsesNativeSelectionAndCollapsibleGroups() async throws {
        let state = SelectionState()
        let repositories = [GitRepository(path: "/测试项目/Alpha"), GitRepository(path: "/测试项目/Beta")]
        let view = RepositorySidebar(
            groups: RepositoryGroup.makeGroups(from: repositories),
            isScanning: false,
            starredRepositoryPaths: [],
            selectionPath: Binding(get: { state.repositoryID }, set: { state.repositoryID = $0 }),
            expandedGroupID: Binding(get: { state.groupID }, set: { state.groupID = $0 }),
            onToggleGroup: { state.groupID = state.groupID == $0 ? nil : $0 },
            onToggleRepositoryStar: { _ in },
            onPrefetchRepository: { _ in }
        )
        let window = host(view, size: NSSize(width: 280, height: 420))
        defer { window.close() }
        try await settle()
        let list = try XCTUnwrap(descendants(of: try XCTUnwrap(window.contentView), type: NSOutlineView.self).first, "侧栏应由系统大纲列表实现。")
        XCTAssertGreaterThanOrEqual(list.numberOfRows, 3)
        list.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try await settle()
        XCTAssertEqual(state.repositoryID, repositories[0].id, "系统选中行应同步回 SwiftUI 选择状态。")
        try attach(window, name: "原生仓库侧栏")
    }

    func testFileListSupportsNativeMultipleSelection() async throws {
        let state = SelectionState()
        let items = ["Alpha.swift", "Beta.swift"].map {
            RepositoryFileItem(section: .changed, path: $0, kind: .file, state: .untracked, gitStatusCode: "??", previousPath: nil)
        }
        let snapshot = RepositoryFileSnapshot(repositoryPath: "/测试项目/Alpha", changedFiles: items, skippedFiles: [], ignoredFiles: [])
        let view = RepositoryFilePanel(
            repository: GitRepository(path: snapshot.repositoryPath),
            snapshot: snapshot,
            isLoading: false,
            errorMessage: nil,
            selectedFileIDs: Binding(get: { state.fileIDs }, set: { state.fileIDs = $0 }),
            onRefresh: {},
            onHoverFile: { _, _ in },
            onIgnore: { _, _ in },
            onMarkAsSkipped: { _ in },
            onRemoveFromSkipped: { _ in }
        )
        let window = host(view, size: NSSize(width: 360, height: 500))
        defer { window.close() }
        try await settle()
        let list = try XCTUnwrap(descendants(of: try XCTUnwrap(window.contentView), type: NSOutlineView.self).first, "文件列表应使用系统大纲列表。")
        XCTAssertTrue(list.allowsMultipleSelection)
        XCTAssertGreaterThanOrEqual(list.numberOfRows, 5)
        list.selectRowIndexes(IndexSet([1, 2]), byExtendingSelection: false)
        try await settle()
        XCTAssertEqual(state.fileIDs, Set(items.map(\.id)), "系统多选应同步回文件选择状态。")
        try attach(window, name: "原生文件多选列表")
    }

    func testCommitEditorKeepsMultilineInputAndUndo() async throws {
        let state = SelectionState()
        let view = CommitComposerBar(
            repository: GitRepository(path: "/测试项目/Alpha"),
            commitMessage: Binding(get: { state.message }, set: { state.message = $0 }),
            isRunningCommitAction: false,
            isGeneratingMessage: false,
            statusMessage: "提交 2 个更改，自动排除不提交的文件。",
            onOpenDebugWindow: {}, onGenerateMessage: {}, onCommitAndPush: {}, onCommitOnly: {}
        )
        let window = host(view, size: NSSize(width: 340, height: 250))
        defer { window.close() }
        try await settle()
        let editor = try XCTUnwrap(descendants(of: try XCTUnwrap(window.contentView), type: NSTextView.self).first)
        window.makeFirstResponder(editor)
        editor.insertText("第一行\n\n第二行", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await settle()
        XCTAssertEqual(state.message, "第一行\n\n第二行")
        XCTAssertTrue(editor.allowsUndo)
        XCTAssertTrue(editor.undoManager?.canUndo == true)
        editor.breakUndoCoalescing()
        editor.undoManager?.undo()
        try await settle()
        XCTAssertEqual(editor.string, "", "系统文本控件应能撤销刚输入的多行文本。")
        // 完整窗口命令路由和绑定回写由 NativeWorkspaceTests 的 ⌘Z 用例验证。
        try attach(window, name: "原生多行提交输入")
    }

    func testSettingsRenderInLightAndDarkAppearance() async throws {
        let suiteName = "NeatGit-界面测试-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = LLMSettingsStore(defaults: defaults)
        for (scheme, name) in [(ColorScheme.light, "浅色"), (.dark, "深色")] {
            let window = host(LLMSettingsView(settingsStore: settings).environment(\.colorScheme, scheme), size: NSSize(width: 480, height: 450))
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            try await settle()
            let root = try XCTUnwrap(window.contentView)
            XCTAssertFalse(descendants(of: root, type: NSSecureTextField.self).isEmpty, "密钥应使用系统安全输入框。")
            try attach(window, name: "\(name)原生设置")
            window.close()
        }
    }

    private func host(_ view: some View, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func descendants<T: NSView>(of view: NSView, type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(of: $0, type: type) }
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(350))
    }

    private func attach(_ window: NSWindow, name: String) throws {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("NeatGit-界面验证", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("\(name).png"))
    }
}

@MainActor
@Observable
private final class SelectionState {
    var repositoryID: String?
    var groupID: String? = "/测试项目"
    var fileIDs: Set<String> = []
    var message = ""
}
