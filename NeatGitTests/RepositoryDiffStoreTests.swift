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
        XCTAssertEqual(store.payloadForDisplay?.modeTitle, "已暂存")
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
        XCTAssertNil(store.payloadForDisplay)
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
