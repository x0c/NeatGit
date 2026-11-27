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
            didFinishInitialScan: true,
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

    func testRepositorySearchFiltersByNameAndPathWithoutChangingSelection() async throws {
        let state = SelectionState()
        let alpha = GitRepository(path: "/测试项目/Alpha")
        let beta = GitRepository(path: "/Other/Beta")
        state.repositoryID = alpha.id
        let view = RepositorySidebar(
            groups: RepositoryGroup.makeGroups(from: [alpha, beta]),
            didFinishInitialScan: true,
            starredRepositoryPaths: [],
            searchQuery: "  other  ",
            selectionPath: Binding(get: { state.repositoryID }, set: { state.repositoryID = $0 }),
            expandedGroupID: Binding(get: { state.groupID }, set: { state.groupID = $0 }),
            onToggleGroup: { _ in },
            onToggleRepositoryStar: { _ in },
            onPrefetchRepository: { _ in }
        )
        let window = host(view, size: NSSize(width: 280, height: 420))
        defer { window.close() }
        try await settle()
        let list = try XCTUnwrap(descendants(of: try XCTUnwrap(window.contentView), type: NSOutlineView.self).first)
        XCTAssertEqual(list.numberOfRows, 1)
        XCTAssertEqual(state.repositoryID, alpha.id, "Filtering must not silently change the repository.")
        list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try await settle()
        XCTAssertEqual(state.repositoryID, beta.id)
    }

    func testFileListSupportsNativeMultipleSelection() async throws {
        let state = SelectionState()
        let items = ["Alpha.swift", "Beta.swift", "Sources/LongFileNameInsideAFolder.swift"].map {
            RepositoryFileItem(section: .changed, path: $0, kind: .file, state: .untracked, gitStatusCode: "??", previousPath: nil)
        }
        let snapshot = RepositoryFileSnapshot(repositoryPath: "/测试项目/Alpha", changedFiles: items, skippedFiles: [], ignoredFiles: [])
        let view = RepositoryFilePanel(
            repository: GitRepository(path: snapshot.repositoryPath),
            snapshot: snapshot,
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
        XCTAssertGreaterThanOrEqual(list.numberOfRows, 6)
        let heights = (1...3).map { list.rect(ofRow: $0).height }
        XCTAssertEqual(Set(heights).count, 1, "Paths must not change native file row heights: \(heights)")
        list.selectRowIndexes(IndexSet([1, 2, 3]), byExtendingSelection: false)
        try await settle()
        XCTAssertEqual(state.fileIDs, Set(items.map(\.id)), "系统多选应同步回文件选择状态。")
        try attach(window, name: "原生文件多选列表")
    }

    func testCommitEditorKeepsMultilineInputAndUndo() async throws {
        let state = SelectionState()
        let view = CommitComposerBar(
            commitMessage: Binding(get: { state.message }, set: { state.message = $0 }),
            isRunningCommitAction: false,
            isGeneratingMessage: false,
            canCommit: true,
            statusMessage: "将提交 2 个文件",
            onGenerateMessage: {}, onCommitAndPush: {}, onCommitOnly: {}
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

    func testWorkspaceRendersSelectedDiffInLightAndDarkAppearance() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = directory.appendingPathComponent("SampleProject")
        let sources = project.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try GitCommandRunner.run(in: project.path, arguments: ["init", "--quiet"])
        XCTAssertEqual(result.terminationStatus, 0)
        try "let message = \"Hello, NeatGit\"\n".write(to: project.appendingPathComponent("Readme.swift"), atomically: true, encoding: .utf8)
        try "let enabled = true\n".write(to: sources.appendingPathComponent("Options.swift"), atomically: true, encoding: .utf8)
        try "Workspace changes\n".write(to: project.appendingPathComponent("Notes.md"), atomically: true, encoding: .utf8)
        let repository = GitRepository(path: project.path)
        let repositories = [repository, GitRepository(path: directory.appendingPathComponent("Example").path)]
        let suite = "NeatGit-Workspace-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        for (scheme, size) in [(ColorScheme.light, NSSize(width: 1240, height: 780)), (.dark, NSSize(width: 960, height: 600))] {
            let selection = WorkspaceSelectionStore()
            selection.selectRepository(repository.id, in: repositories)
            selection.selectedFileIDs = ["changed:Readme.swift"]
            let view = ContentView(
                llmSettingsStore: LLMSettingsStore(defaults: defaults),
                aiCommitDebugStore: AICommitDebugStore(),
                repositoryStore: RepositoryStore(defaults: defaults, initialRepositories: repositories),
                selection: selection
            ).environment(\.colorScheme, scheme)
            let window = host(view, size: size)
            defer { window.close() }
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let root = try XCTUnwrap(window.contentView)
            for _ in 0..<15 {
                if descendants(of: root, type: NativeDiffTextView.self).contains(where: { $0.string.contains("Hello, NeatGit") }) { break }
                try await settle()
            }
            XCTAssertEqual(descendants(of: root, type: NativeDiffTextView.self).count, 2)
            XCTAssertTrue(descendants(of: root, type: NativeDiffTextView.self).contains { $0.string.contains("Hello, NeatGit") })
            try attach(window, name: scheme == .dark ? "Workspace-selected-dark" : "Workspace-selected-light")
        }
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
        window.title = "NeatGit"
        window.toolbarStyle = .unifiedCompact
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: size)
        window.contentView = hostingView
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
