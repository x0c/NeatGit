import Foundation
import XCTest
@testable import NeatGit

/// 覆盖重构后新建的状态容器：选择态一致性与提交工作流文案。
///
/// 这些规则原先散在 ContentView 的 onChange 回调里，无法单独验证；
/// 收进 store 之后用例可以直接驱动状态迁移。
@MainActor
final class WorkspaceStoresTests: XCTestCase {
    private let repositories = [
        GitRepository(path: "/测试项目/Alpha"),
        GitRepository(path: "/测试项目/Beta")
    ]

    func testSwitchingRepositoryClearsFileSelectionAndHover() {
        let selection = WorkspaceSelectionStore()
        let item = makeItem(path: "A.swift")

        selection.selectRepository(repositories[0].id, in: repositories)
        selection.selectFile(item)
        selection.updateHover(item, isHovering: true)
        XCTAssertEqual(selection.selectedFileIDs, [item.id])

        selection.selectRepository(repositories[1].id, in: repositories)

        XCTAssertTrue(selection.selectedFileIDs.isEmpty, "换仓库后不应带着上一个仓库的文件选中态。")
        XCTAssertNil(selection.hoveredFile(in: nil))
        XCTAssertEqual(selection.expandedGroupID, repositories[1].parentPath, "选中仓库后应展开它所在分组。")
    }

    func testVanishedRepositoryIsDeselectedAfterRescan() {
        let selection = WorkspaceSelectionStore()
        selection.selectRepository(repositories[1].id, in: repositories)

        let remaining = [repositories[0]]
        selection.reconcile(with: remaining, groups: RepositoryGroup.makeGroups(from: remaining))

        XCTAssertNil(selection.repository(in: remaining), "重新扫描后消失的仓库必须被取消选中。")
        XCTAssertNotNil(selection.expandedGroupID, "校正后仍应有一个展开的分组。")
    }

    func testStaleFileSelectionIsDroppedAfterRefresh() {
        let selection = WorkspaceSelectionStore()
        let kept = makeItem(path: "保留.swift")
        let removed = makeItem(path: "已删除.swift")

        selection.selectRepository(repositories[0].id, in: repositories)
        selection.selectedFileIDs = [kept.id, removed.id]
        selection.updateHover(removed, isHovering: true)

        selection.reconcileFiles(with: [kept.id])

        XCTAssertEqual(selection.selectedFileIDs, [kept.id], "刷新后已消失的文件应被移出选中集合。")
        let snapshot = RepositoryFileSnapshot(
            repositoryPath: repositories[0].path,
            changedFiles: [kept],
            skippedFiles: [],
            ignoredFiles: []
        )
        XCTAssertNil(selection.hoveredFile(in: snapshot), "刷新后已消失的文件不应继续作为预览目标。")
    }

    func testHoverLeavingAnotherRowKeepsCurrentTarget() {
        let selection = WorkspaceSelectionStore()
        let first = makeItem(path: "A.swift")
        let second = makeItem(path: "B.swift")
        let snapshot = RepositoryFileSnapshot(
            repositoryPath: repositories[0].path,
            changedFiles: [first, second],
            skippedFiles: [],
            ignoredFiles: []
        )

        selection.selectRepository(repositories[0].id, in: repositories)
        selection.updateHover(second, isHovering: true)
        // 移出上一行的回调可能晚于移入新行，这时不能把新目标清掉。
        selection.updateHover(first, isHovering: false)

        XCTAssertEqual(selection.hoveredFile(in: snapshot)?.id, second.id)
    }

    func testToggleGroupIsExclusive() {
        let selection = WorkspaceSelectionStore()

        selection.toggleGroup("/测试项目")
        XCTAssertEqual(selection.expandedGroupID, "/测试项目")

        selection.toggleGroup("/测试项目")
        XCTAssertNil(selection.expandedGroupID, "再次点击同一分组应折叠。")
    }

    func testCommitStatusMessageCountsOnlyCommittableFiles() {
        let store = makeCommitStore()
        let snapshot = RepositoryFileSnapshot(
            repositoryPath: repositories[0].path,
            changedFiles: [
                makeItem(path: "A.swift"),
                makeItem(path: ".gitignore"),
                makeItem(path: "冲突.swift", statusCode: "UU")
            ],
            skippedFiles: [],
            ignoredFiles: []
        )

        let message = store.statusMessage(repository: repositories[0], snapshot: snapshot)

        // 3 个变更里只有 A.swift 可提交：.gitignore 被硬排除，冲突文件不可勾选。
        XCTAssertTrue(message.contains("1 个更改"), "状态文案应只统计真正会提交的文件，实际为：\(message)")
        XCTAssertTrue(message.contains("1 个 .gitignore"), "被排除的文件数应如实告知，实际为：\(message)")
    }

    func testCommitStatusMessageReflectsMissingRepositoryAndSnapshot() {
        let store = makeCommitStore()

        XCTAssertTrue(store.statusMessage(repository: nil, snapshot: nil).contains("选择仓库"))
        XCTAssertTrue(store.statusMessage(repository: repositories[0], snapshot: nil).contains("正在读取"))
    }

    func testCommittableByDefaultMatchesCommitServiceRule() {
        XCTAssertTrue(makeItem(path: "A.swift").isCommittableByDefault)
        XCTAssertFalse(makeItem(path: ".gitignore").isCommittableByDefault, ".gitignore 默认不参与提交。")
        XCTAssertFalse(makeItem(path: "冲突.swift", statusCode: "UU").isCommittableByDefault, "冲突文件不可提交。")
        XCTAssertFalse(
            makeItem(path: "跳过.swift", section: .skipped).isCommittableByDefault,
            "skip-worktree 文件不参与提交。"
        )
    }

    private func makeCommitStore() -> CommitWorkflowStore {
        let suiteName = "NeatGit-提交文案-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let settings = LLMSettingsStore(defaults: defaults)

        return CommitWorkflowStore(
            llmSettingsStore: settings,
            generationService: CommitMessageGenerationService(debugStore: AICommitDebugStore())
        )
    }

    private func makeItem(
        path: String,
        section: RepositoryFileSection = .changed,
        statusCode: String = "??"
    ) -> RepositoryFileItem {
        RepositoryFileItem(
            section: section,
            path: path,
            kind: .file,
            state: section == .changed ? .untracked : .skipped,
            gitStatusCode: section == .changed ? statusCode : nil,
            previousPath: nil
        )
    }
}
