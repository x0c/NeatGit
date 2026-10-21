import Foundation
import Observation
import XCTest
@testable import NeatGit

@MainActor
final class RepositoryStatusStoreTests: XCTestCase {
    func testSwitchingBackToVisitedRepositoryShowsCachedSnapshotImmediately() async throws {
        let fixtureA = try makeFixture(name: "仓库甲")
        let fixtureB = try makeFixture(name: "仓库乙")
        defer {
            try? FileManager.default.removeItem(at: fixtureA.directory)
            try? FileManager.default.removeItem(at: fixtureB.directory)
        }

        let store = RepositoryStatusStore()
        store.load(for: fixtureA.repository)
        try await waitUntilLoaded(store)
        store.load(for: fixtureB.repository)
        try await waitUntilLoaded(store)

        store.load(for: fixtureA.repository)

        // 核心断言：命中缓存时同步立即可见旧快照，不等 git status 返回。
        XCTAssertEqual(store.snapshot?.repositoryPath, fixtureA.repository.path)
        XCTAssertTrue(store.isLoading, "缓存命中后仍应在后台静默刷新")
    }

    func testRefreshWithoutChangesKeepsSnapshotRevisionStable() async throws {
        let fixture = try makeFixture(name: "无变化仓库")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let store = RepositoryStatusStore()
        store.load(for: fixture.repository)
        try await waitUntilLoaded(store)
        let revisionAfterFirstLoad = store.snapshotRevision

        store.refreshCurrentRepository()
        try await waitUntilLoaded(store)

        XCTAssertEqual(store.snapshotRevision, revisionAfterFirstLoad, "数据无变化时不应递增版本号，避免右侧 diff 缓存被误清。")
    }

    func testRefreshWithChangesBumpsSnapshotRevision() async throws {
        let fixture = try makeFixture(name: "有变化仓库")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let store = RepositoryStatusStore()
        store.load(for: fixture.repository)
        try await waitUntilLoaded(store)
        XCTAssertEqual(store.snapshot?.changedFiles.map(\.path), ["示例.swift"])

        try "新内容\n".write(to: fixture.directory.appendingPathComponent("新文件.md"), atomically: true, encoding: .utf8)

        store.refreshCurrentRepository()
        try await waitUntilLoaded(store)

        XCTAssertEqual(store.snapshot?.changedFiles.map(\.path).sorted(), ["新文件.md", "示例.swift"].sorted())
        XCTAssertGreaterThan(store.snapshotRevision, 1, "数据变化后必须递增版本号通知 diff 层失效。")
    }

    func testFailedRefreshKeepsDisplayedContent() async throws {
        let fixture = try makeFixture(name: "断网仓库")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let store = RepositoryStatusStore()
        store.load(for: fixture.repository)
        try await waitUntilLoaded(store)

        // 删掉仓库目录再切换走又切回来：缓存命中显示旧内容，后台刷新失败不应清空列表。
        try FileManager.default.removeItem(at: fixture.directory)
        let other = try makeFixture(name: "备用仓库")
        defer { try? FileManager.default.removeItem(at: other.directory) }

        store.load(for: other.repository)
        try await waitUntilLoaded(store)
        store.load(for: fixture.repository)
        try await waitUntilLoaded(store)

        XCTAssertEqual(store.snapshot?.repositoryPath, fixture.repository.path, "刷新失败时应保留已显示的缓存内容。")
        XCTAssertNotNil(store.errorMessage, "刷新失败时顶部应有错误提示。")
    }

    func testPrefetchFillsCacheForInstantSelection() async throws {
        let fixture = try makeFixture(name: "预取仓库")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let store = RepositoryStatusStore()
        store.prefetch(for: fixture.repository)

        // 等预取任务完成写缓存（真实 git 命令，留足余量）。
        try await Task.sleep(for: .milliseconds(800))

        store.load(for: fixture.repository)
        XCTAssertEqual(store.snapshot?.repositoryPath, fixture.repository.path, "预取命中后选中仓库应立即可见，无需等待加载。")
    }

    private func makeFixture(name: String) throws -> (directory: URL, repository: GitRepository) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NeatGit-状态验证-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try runGit(["init", "--quiet"], at: directory)
            let file = directory.appendingPathComponent("示例.swift")
            try "工作区内容\n".write(to: file, atomically: true, encoding: .utf8)
            try runGit(["add", "--", file.lastPathComponent], at: directory)
            return (directory, GitRepository(path: directory.path))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let result = try GitCommandRunner.run(in: directory.path, arguments: arguments)
        _ = try GitCommandRunner.requireSuccess(result, defaultMessage: "创建隔离的 Git 验证数据失败。")
    }

    private func waitUntilLoaded(_ store: RepositoryStatusStore) async throws {
        for _ in 0..<200 {
            if !store.isLoading { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("仓库状态读取超过 5 秒仍未结束。")
    }
}
