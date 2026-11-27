import Foundation
import Observation
import XCTest
@testable import NeatGit

@MainActor
final class RepositoryDiffStoreTests: XCTestCase {
    func testDiffStoreParticipatesInObservation() {
        let store = RepositoryDiffStore()
        let changed = expectation(description: "差异可见范围变化应通知界面")
        withObservationTracking {
            _ = store.showChangesOnly
        } onChange: {
            changed.fulfill()
        }

        store.toggleShowChangesOnly()
        XCTAssertTrue(store.showChangesOnly)
        wait(for: [changed], timeout: 1)
    }

    func testSwitchingStagedAndWorkingTreePreservesTheCorrectContent() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = RepositoryDiffStore()

        store.select(repository: fixture.repository, selectedFiles: [fixture.item], cacheRevision: 1)
        try await waitUntilLoaded(store)
        XCTAssertEqual(store.availableModes, [.workingTree, .staged])
        XCTAssertEqual(store.activeMode, .staged)
        XCTAssertEqual(store.document?.originalText, "")
        XCTAssertEqual(store.document?.modifiedText, "暂存版本\n")

        store.selectMode(.workingTree)
        try await waitUntilLoaded(store)
        XCTAssertEqual(store.document?.originalText, "暂存版本\n")
        XCTAssertEqual(store.document?.modifiedText, "工作区版本\n")
        XCTAssertEqual(store.headerSubtitle, "未暂存")

        store.selectMode(.staged)
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.document?.modifiedText, "暂存版本\n")
        XCTAssertEqual(store.displayedDocument?.mode.title, "已暂存")
    }

    func testFastModeSwitchCannotApplyOldContent() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = RepositoryDiffStore()

        store.select(repository: fixture.repository, selectedFiles: [fixture.item], cacheRevision: 1)
        store.selectMode(.workingTree)
        store.selectMode(.staged)
        store.selectMode(.workingTree)
        try await waitUntilLoaded(store)

        XCTAssertEqual(store.activeMode, .workingTree)
        XCTAssertEqual(store.document?.mode, .workingTree)
        XCTAssertEqual(store.document?.modifiedText, "工作区版本\n")
    }

    func testRefreshInvalidatesCachedDiffAndSelectionShowsPlaceholder() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = RepositoryDiffStore()
        store.select(repository: fixture.repository, selectedFiles: [fixture.item], cacheRevision: 1)
        store.selectMode(.workingTree)
        try await waitUntilLoaded(store)

        try "刷新后的工作区\n".write(to: fixture.directory.appendingPathComponent("示例.swift"), atomically: true, encoding: .utf8)
        store.select(repository: fixture.repository, selectedFiles: [fixture.item], cacheRevision: 2)
        try await waitUntilLoaded(store)
        XCTAssertEqual(store.activeMode, .workingTree, "刷新同一文件应保留用户选择的对比模式。")
        XCTAssertEqual(store.document?.modifiedText, "刷新后的工作区\n")

        store.select(repository: fixture.repository, selectedFiles: [], cacheRevision: 2)
        XCTAssertTrue(store.showsPlaceholder)
        XCTAssertFalse(store.showsVisibilityToggle)
        XCTAssertTrue(store.availableModes.isEmpty)

        store.select(repository: nil, selectedFiles: [], cacheRevision: 2)
        XCTAssertNil(store.displayedDocument)
        XCTAssertEqual(store.messageTitle, "先选择一个仓库")
    }

    func testMultiSelectionAndUnsupportedFilesKeepTheirMessages() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = RepositoryDiffStore()
        let other = RepositoryFileItem(section: .changed, path: "其他.swift", kind: .file, state: .untracked, gitStatusCode: "??", previousPath: nil)
        store.select(repository: fixture.repository, selectedFiles: [fixture.item, other], cacheRevision: 1)
        XCTAssertEqual(store.messageTitle, "暂不支持多文件对照")
        XCTAssertTrue(store.showsPlaceholder)

        let ignored = RepositoryFileItem(section: .ignored, path: "缓存", kind: .directory, state: .ignored, gitStatusCode: nil, previousPath: nil)
        store.select(repository: fixture.repository, selectedFiles: [ignored], cacheRevision: 1)
        XCTAssertTrue(store.availableModes.isEmpty)
        XCTAssertTrue(store.showsPlaceholder)
        XCTAssertFalse(store.showsVisibilityToggle)
    }

    func testOnlyAvailableModesCanBeSelected() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let newFile = fixture.directory.appendingPathComponent("新文件.txt")
        try "新文件内容\n".write(to: newFile, atomically: true, encoding: .utf8)
        let item = RepositoryFileItem(section: .changed, path: newFile.lastPathComponent, kind: .file, state: .untracked, gitStatusCode: "??", previousPath: nil)
        let store = RepositoryDiffStore()
        store.select(repository: fixture.repository, selectedFiles: [item], cacheRevision: 1)
        try await waitUntilLoaded(store)
        store.selectMode(.staged)

        XCTAssertEqual(store.availableModes, [.workingTree])
        XCTAssertEqual(store.activeMode, .workingTree)
        XCTAssertEqual(store.document?.modifiedText, "新文件内容\n")
    }

    /// 加载恰好计算一次逐行对照结果，且计算全部发生在主线程之外。
    ///
    /// 原生差异视图直接使用加载完成的文档，不再有「按需补算」入口。用计算器的调用计数证明，
    /// 不用耗时阈值：换机器、调试构建、并行负载都不会让结论漂移。
    func testLoadingCalculatesDiffRowsExactlyOnceOffTheMainThread() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = RepositoryDiffStore()
        TextDiffCalculator.resetRecordedCalculationCount()
        store.select(repository: fixture.repository, selectedFiles: [fixture.item], cacheRevision: 1)
        try await waitUntilLoaded(store)
        XCTAssertEqual(store.activeMode, .staged)

        let staged = try XCTUnwrap(store.document)
        XCTAssertEqual(staged.originalText, "")
        XCTAssertEqual(staged.modifiedText, "暂存版本\n")
        XCTAssertEqual(staged.rows.map(\.kind), [.added], "加载完成的文档应直接带逐行对照结果")
        XCTAssertEqual(staged.rows.first?.modified?.lineNumber, 1)
        XCTAssertEqual(staged.rows.first?.modified?.text, "暂存版本")
        XCTAssertEqual(staged.originalLines, 0)
        XCTAssertEqual(staged.modifiedLines, 1)
        XCTAssertFalse(staged.originalEndsWithoutNewline)
        XCTAssertFalse(staged.modifiedEndsWithoutNewline)
        XCTAssertEqual(TextDiffCalculator.recordedCalculationCount, 1, "一次加载恰好计算一次")
        XCTAssertEqual(TextDiffCalculator.recordedMainThreadCalculationCount, 0, "差异计算不能落在主线程")

        store.selectMode(.workingTree)
        try await waitUntilLoaded(store)
        let workingTree = try XCTUnwrap(store.document)
        // 「暂存版本」与「工作区版本」只有两个字符重合，相似度不到配对阈值，按删除加新增输出。
        XCTAssertEqual(workingTree.rows.map(\.kind), [.removed, .added])
        XCTAssertEqual(workingTree.rows.first?.original?.lineNumber, 1)
        XCTAssertEqual(workingTree.rows.first?.original?.text, "暂存版本")
        XCTAssertEqual(workingTree.rows.last?.modified?.lineNumber, 1)
        XCTAssertEqual(workingTree.rows.last?.modified?.text, "工作区版本")
        XCTAssertEqual(workingTree.originalLines, 1)
        XCTAssertEqual(workingTree.modifiedLines, 1)
        XCTAssertEqual(TextDiffCalculator.recordedCalculationCount, 2, "两种对比模式各计算一次")
        XCTAssertEqual(TextDiffCalculator.recordedMainThreadCalculationCount, 0)

        // 切回已加载过的模式走缓存：立即得到带逐行对照结果的文档，不再计算。
        TextDiffCalculator.resetRecordedCalculationCount()
        store.selectMode(.staged)
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.document?.rows.map(\.kind), [.added])
        XCTAssertEqual(store.document?.modifiedText, "暂存版本\n")
        XCTAssertEqual(store.displayedDocument?.mode.title, "已暂存")
        XCTAssertEqual(TextDiffCalculator.recordedCalculationCount, 0, "从缓存取回不应重新计算")
    }

    /// 性能守卫：加载较大的文本差异时同样只计算一次，且不在主线程计算。
    ///
    ///
    /// 用计算器的调用计数证明，而不是耗时阈值：换机器、调试构建、并行负载都不会让结论漂移。
    func testLoadingLargeTextCalculatesDiffRowsOnceOffTheMainThread() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        // 10 万行（约 2.7 MB，在 5 MB 上限内）：改动 10 行、插入 1 行，与性能量测用例同形。
        // 原文放进暂存区、修改留在工作区，这样未暂存差异的两侧都有内容，是真正需要计算的情形。
        let large = (0..<100_000).map { "第 \($0) 行 内容 \($0 * 31 % 997)" }
        var few = large
        for index in stride(from: 500, to: large.count, by: 9_997) {
            few[index] = "改动过的第 \(index) 行"
        }
        few.insert("插入的新行", at: 40_000)
        let originalText = large.joined(separator: "\n") + "\n"
        let modifiedText = few.joined(separator: "\n") + "\n"
        let name = "大文件.txt"
        let file = fixture.directory.appendingPathComponent(name)
        try originalText.write(to: file, atomically: true, encoding: .utf8)
        try runGit(["add", "--", name], at: fixture.directory)
        try modifiedText.write(to: file, atomically: true, encoding: .utf8)
        // 只有未暂存改动：加载时直接走未暂存对比，不会先加载暂存对比再切换，计算次数才能恰好是 1。
        let item = RepositoryFileItem(section: .changed, path: name, kind: .file, state: .changed("未暂存"), gitStatusCode: ".M", previousPath: nil)

        let store = RepositoryDiffStore()
        TextDiffCalculator.resetRecordedCalculationCount()
        store.select(repository: fixture.repository, selectedFiles: [item], cacheRevision: 1)
        try await waitUntilLoaded(store)
        XCTAssertEqual(store.activeMode, .workingTree)
        XCTAssertEqual(store.availableModes, [.workingTree])

        let loaded = try XCTUnwrap(store.document)
        XCTAssertEqual(loaded.originalText, originalText)
        XCTAssertEqual(loaded.modifiedText, modifiedText)
        XCTAssertEqual(TextDiffCalculator.recordedCalculationCount, 1, "加载路径应恰好计算一次差异")
        XCTAssertEqual(TextDiffCalculator.recordedMainThreadCalculationCount, 0, "差异计算不能落在主线程")

        // 计数是 1 而不是 0 的对照：加载完成的文档直接带着可用的逐行对照结果。
        XCTAssertEqual(loaded.rows.filter { $0.kind == .context }.count, large.count - 10)
        XCTAssertEqual(loaded.rows.filter { $0.kind == .modified }.count, 10)
        XCTAssertEqual(loaded.rows.filter { $0.kind == .added }.count, 1)
        XCTAssertEqual(loaded.originalLines, large.count)
        XCTAssertEqual(loaded.modifiedLines, large.count + 1)
    }

    private func makeFixture() throws -> (directory: URL, repository: GitRepository, item: RepositoryFileItem) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NeatGit-差异验证-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try runGit(["init", "--quiet"], at: directory)
            let file = directory.appendingPathComponent("示例.swift")
            try "暂存版本\n".write(to: file, atomically: true, encoding: .utf8)
            try runGit(["add", "--", file.lastPathComponent], at: directory)
            try "工作区版本\n".write(to: file, atomically: true, encoding: .utf8)
            return (
                directory,
                GitRepository(path: directory.path),
                RepositoryFileItem(section: .changed, path: file.lastPathComponent, kind: .file, state: .changed("已暂存 + 未暂存"), gitStatusCode: "AM", previousPath: nil)
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let result = try GitCommandRunner.run(in: directory.path, arguments: arguments)
        _ = try GitCommandRunner.requireSuccess(result, defaultMessage: "创建隔离的 Git 验证数据失败。")
    }

    private func waitUntilLoaded(_ store: RepositoryDiffStore) async throws {
        for _ in 0..<200 {
            if !store.isLoading { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("差异读取超过 5 秒仍未结束。")
    }
}
