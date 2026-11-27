import Foundation
import Observation

@MainActor
@Observable
final class RepositoryStore {
    private enum StorageKey {
        static let starredRepositoryPaths = "starredRepositoryPaths"
    }

    private(set) var repositories: [GitRepository] = []
    /// 与 repositories / 收藏状态对应的派生分组，只在输入变化时后台重算。
    /// 视图刷新、提交说明输入和文件选择不再重复执行路径分组与排序。
    private(set) var groups: [RepositoryGroup] = []
    private(set) var isScanning = false
    private(set) var didFinishInitialScan = false
    private(set) var starredRepositoryPaths: Set<GitRepository.ID>

    @ObservationIgnored
    private let scanner = GitRepositoryScanner()
    @ObservationIgnored
    private let defaults: UserDefaults
    @ObservationIgnored
    private var refreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var groupTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, initialRepositories: [GitRepository] = []) {
        self.defaults = defaults
        self.starredRepositoryPaths = Set(defaults.stringArray(forKey: StorageKey.starredRepositoryPaths) ?? [])
        if !initialRepositories.isEmpty {
            self.repositories = initialRepositories
            self.groups = RepositoryGroup.makeGroups(from: initialRepositories, starredRepositoryPaths: starredRepositoryPaths)
            self.didFinishInitialScan = true
        }
    }

    func refresh() {
        InteractionProfiler.measure("重新扫描项目.点击处理") {
            guard refreshTask == nil else { return }

            isScanning = true

            refreshTask = Task { [scanner] in
                defer {
                    refreshTask = nil
                    isScanning = false
                }

                let scanInterval = InteractionProfiler.begin("项目扫描.后台读取")
                let scannedRepositories = await scanner.scan()
                scanInterval.end()
                let scannedGroups = await Self.makeGroups(
                    from: scannedRepositories,
                    starredRepositoryPaths: starredRepositoryPaths
                )
                guard !Task.isCancelled else { return }
                // 收藏触发的旧分组任务不能在新扫描结果之后回写。
                groupTask?.cancel()
                // 先更新派生分组，再发布仓库数组，保证选择态校正看到同一代数据。
                groups = scannedGroups
                repositories = scannedRepositories
                didFinishInitialScan = true
            }
        }
    }

    func toggleStar(for repository: GitRepository) {
        InteractionProfiler.measure("收藏项目.点击处理") {
            if starredRepositoryPaths.contains(repository.id) {
                starredRepositoryPaths.remove(repository.id)
            } else {
                starredRepositoryPaths.insert(repository.id)
            }

            defaults.set(Array(starredRepositoryPaths).sorted(), forKey: StorageKey.starredRepositoryPaths)
            rebuildGroups()
        }
    }

    /// 收藏只改变少量状态，但标题与排序涉及全部项目；后台重算并只采用最新一代结果。
    private func rebuildGroups() {
        groupTask?.cancel()
        let repositories = repositories
        let starredRepositoryPaths = starredRepositoryPaths
        groupTask = Task {
            let newGroups = await Self.makeGroups(
                from: repositories,
                starredRepositoryPaths: starredRepositoryPaths
            )
            guard !Task.isCancelled else { return }
            groups = newGroups
        }
    }

    private static func makeGroups(
        from repositories: [GitRepository],
        starredRepositoryPaths: Set<GitRepository.ID>
    ) async -> [RepositoryGroup] {
        await Task.detached(priority: .userInitiated) {
            InteractionProfiler.measure("项目分组.后台计算", detail: "项目数：\(repositories.count)") {
                RepositoryGroup.makeGroups(
                    from: repositories,
                    starredRepositoryPaths: starredRepositoryPaths
                )
            }
        }.value
    }
}
