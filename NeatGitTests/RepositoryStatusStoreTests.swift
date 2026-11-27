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
        store.prefetch(for: .entered(fixture.repository))

        // 等预取真正结束：真实 git 命令耗时不确定，按状态轮询而非固定睡眠。
        try await waitUntilPrefetchIdle(store)
        store.prefetch(for: .exited(fixture.repository))

        store.load(for: fixture.repository)
        XCTAssertEqual(store.snapshot?.repositoryPath, fixture.repository.path, "预取命中后选中仓库应立即可见，无需等待加载。")
        try await waitUntilLoaded(store)
        XCTAssertNil(store.errorMessage)
    }

    // MARK: - 悬停预取节流

    func testHoverPrefetchWaitsForDwellAndIgnoresQuickSweep() async throws {
        let recorder = RecordingStatusLoader()
        // 放大停留时长，让「未到时间不该开始」的断言有足够余量，不依赖机器快慢。
        let store = RepositoryStatusStore(hoverPrefetchDelay: .seconds(1), loadSnapshot: recorder.loadSnapshot(for:))
        XCTAssertEqual(RepositoryStatusStore.defaultHoverPrefetchDelay, .milliseconds(200), "正式环境的停留时长应约为 200 毫秒。")

        let first = GitRepository(path: "/测试项目/甲")
        let second = GitRepository(path: "/测试项目/乙")

        // 快速划过两行：每行停留远小于停留时长。
        store.prefetch(for: .entered(first))
        try await Task.sleep(for: .milliseconds(50))
        store.prefetch(for: .exited(first))
        store.prefetch(for: .entered(second))
        try await Task.sleep(for: .milliseconds(50))
        store.prefetch(for: .exited(second))

        XCTAssertFalse(store.isWaitingForHoverDelay, "离开全部行后停留计时应立即作废。")
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertTrue(recorder.startedPaths.isEmpty, "快速划过不应为任何一行起 git 进程。")

        // 停留：未满停留时长不开始，满后才开始，且只开始一次。
        store.prefetch(for: .entered(second))
        XCTAssertTrue(store.isWaitingForHoverDelay)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(recorder.startedPaths.isEmpty, "停留未满不应开始预取。")

        try await waitUntil("停留满后应开始预取。") { recorder.startedPaths == [second.path] }
        try await waitUntilPrefetchIdle(store)
        XCTAssertEqual(recorder.startedPaths, [second.path], "同一行停留只应预取一次。")

        // 能力不变：预取完成后选中仓库仍然零等待。
        store.prefetch(for: .exited(second))
        store.load(for: second)
        XCTAssertEqual(store.snapshot?.repositoryPath, second.path, "预取命中后选中仓库应立即可见。")
        try await waitUntilLoaded(store)
    }

    func testLateExitOfPreviousRowKeepsNewHoverTarget() async throws {
        let recorder = RecordingStatusLoader()
        let store = RepositoryStatusStore(loadSnapshot: recorder.loadSnapshot(for:))
        let first = GitRepository(path: "/测试项目/甲")
        let second = GitRepository(path: "/测试项目/乙")

        // 行间移动时，上一行的离开回调可能晚于新行的进入。
        store.prefetch(for: .entered(first))
        store.prefetch(for: .entered(second))
        store.prefetch(for: .exited(first))

        try await waitUntil("晚到的上一行离开不应取消新行的预取。") { recorder.startedPaths == [second.path] }
        store.prefetch(for: .exited(second))
        try await waitUntilPrefetchIdle(store)
        XCTAssertEqual(recorder.startedPaths, [second.path])
    }

    func testOnlyOnePrefetchInFlightAndOnlyLatestHoverQueued() async throws {
        let recorder = RecordingStatusLoader()
        recorder.isHolding = true
        let store = RepositoryStatusStore(loadSnapshot: recorder.loadSnapshot(for:))
        let first = GitRepository(path: "/测试项目/甲")
        let second = GitRepository(path: "/测试项目/乙")
        let third = GitRepository(path: "/测试项目/丙")

        store.prefetch(for: .entered(first))
        try await waitUntil("停留后应开始第一个预取。") { store.isPrefetchInFlight }

        // 第一个预取还卡在半路时又依次停留了乙、丙两行。
        store.prefetch(for: .entered(second))
        try await waitUntil("乙行停留计时应结束。") { !store.isWaitingForHoverDelay }
        store.prefetch(for: .entered(third))
        try await waitUntil("丙行停留计时应结束。") { !store.isWaitingForHoverDelay }

        XCTAssertTrue(store.isPrefetchInFlight)
        XCTAssertEqual(recorder.startedPaths, [first.path], "同时最多一个预取在途。")

        recorder.resumeHeld()
        try await waitUntil("在途结束后只应执行最新的悬停目标。") { recorder.startedPaths == [first.path, third.path] }
        try await waitUntilPrefetchIdle(store)
        XCTAssertEqual(recorder.startedPaths, [first.path, third.path], "被更新目标取代的乙行不应再预取。")
    }

    func testLeavingAllRowsDropsQueuedPrefetch() async throws {
        let recorder = RecordingStatusLoader()
        recorder.isHolding = true
        let store = RepositoryStatusStore(loadSnapshot: recorder.loadSnapshot(for:))
        let first = GitRepository(path: "/测试项目/甲")
        let second = GitRepository(path: "/测试项目/乙")

        store.prefetch(for: .entered(first))
        try await waitUntil("停留后应开始第一个预取。") { store.isPrefetchInFlight }
        store.prefetch(for: .entered(second))
        try await waitUntil("乙行停留计时应结束。") { !store.isWaitingForHoverDelay }

        // 鼠标离开全部行：排队中的乙行作废，在途的甲行照常跑完。
        store.prefetch(for: .exited(second))
        XCTAssertFalse(store.isWaitingForHoverDelay)

        recorder.resumeHeld()
        try await waitUntilPrefetchIdle(store)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(recorder.startedPaths, [first.path], "离开全部行后不应再执行尚未开始的预取。")
    }

    func testSelectingRepositoryReusesInFlightPrefetch() async throws {
        let recorder = RecordingStatusLoader()
        recorder.isHolding = true
        let store = RepositoryStatusStore(loadSnapshot: recorder.loadSnapshot(for:))
        let repository = GitRepository(path: "/测试项目/甲")

        store.prefetch(for: .entered(repository))
        try await waitUntil("停留后应开始预取。") { store.isPrefetchInFlight }

        // 正好选中了预取在途的仓库：复用同一个任务，不重复起进程。
        store.load(for: repository)
        XCTAssertTrue(store.isLoading)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(recorder.startedPaths, [repository.path], "选中仓库时不应为同一仓库再起一轮读取。")

        recorder.resumeHeld()
        try await waitUntilLoaded(store)
        XCTAssertEqual(store.snapshot?.repositoryPath, repository.path)
        XCTAssertNil(store.errorMessage)
        try await waitUntilPrefetchIdle(store)
    }

    func testSelectingRepositoryIsNotThrottledByPrefetch() async throws {
        let recorder = RecordingStatusLoader()
        recorder.isHolding = true
        let store = RepositoryStatusStore(loadSnapshot: recorder.loadSnapshot(for:))
        let first = GitRepository(path: "/测试项目/甲")
        let second = GitRepository(path: "/测试项目/乙")

        store.prefetch(for: .entered(first))
        try await waitUntil("停留后应开始预取。") { store.isPrefetchInFlight }
        store.prefetch(for: .entered(second))
        try await waitUntil("乙行停留计时应结束。") { !store.isWaitingForHoverDelay }

        // 乙行还在排队时选中它：正式加载立即开始，不等在途的预取。
        store.load(for: second)
        try await waitUntil("选中仓库的正式加载不应被预取节流。") { recorder.startedPaths == [first.path, second.path] }

        recorder.resumeHeld()
        try await waitUntilLoaded(store)
        try await waitUntilPrefetchIdle(store)
        XCTAssertEqual(recorder.startedPaths, [first.path, second.path], "排队中的预取在仓库被选中后不应再执行。")
        XCTAssertEqual(store.snapshot?.repositoryPath, second.path)
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
        try await waitUntil("仓库状态读取") { !store.isLoading }
    }

    /// 等悬停停留计时与在途预取都结束，取代固定时长的睡眠。
    private func waitUntilPrefetchIdle(_ store: RepositoryStatusStore) async throws {
        try await waitUntil("悬停预取") {
            !store.isWaitingForHoverDelay && !store.isPrefetchInFlight
        }
    }

    /// 带超时的条件轮询：条件满足立即返回，超过 5 秒判失败。
    private func waitUntil(_ what: String, condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("\(what)超过 5 秒仍未满足。")
    }
}

/// 可控的仓库状态读取器：记录每次读取（等价于「起了一轮 git 进程」），
/// 并能停在半路制造「在途」状态，让并发数量与时序可以确定性地验证。
@MainActor
private final class RecordingStatusLoader {
    private(set) var startedPaths: [String] = []
    /// 为 true 时读取停在半路，直到调用 `resumeHeld()`。
    var isHolding = false
    private var heldContinuations: [CheckedContinuation<Void, Never>] = []

    func loadSnapshot(for repository: GitRepository) async throws -> RepositoryFileSnapshot {
        startedPaths.append(repository.path)
        if isHolding {
            await withCheckedContinuation { heldContinuations.append($0) }
        }
        return RepositoryFileSnapshot(
            repositoryPath: repository.path,
            changedFiles: [],
            skippedFiles: [],
            ignoredFiles: []
        )
    }

    func resumeHeld() {
        isHolding = false
        let held = heldContinuations
        heldContinuations = []
        held.forEach { $0.resume() }
    }
}
