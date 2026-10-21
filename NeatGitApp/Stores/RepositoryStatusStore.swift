import Observation

@MainActor
@Observable
final class RepositoryStatusStore {
    /// 跨仓库快照缓存上限：覆盖用户近期来回切换的仓库，超出后淘汰最久未使用的。
    private static let maxCachedSnapshots = 10

    private(set) var snapshot: RepositoryFileSnapshot?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var snapshotRevision = 0

    @ObservationIgnored
    private let loader = GitRepositoryStatusLoader()
    @ObservationIgnored
    private var currentRepository: GitRepository?
    @ObservationIgnored
    private var loadTask: Task<Void, Never>?
    /// 跨仓库快照缓存（stale-while-revalidate 的 stale 部分）。
    @ObservationIgnored
    private var snapshotCache: [GitRepository.ID: RepositoryFileSnapshot] = [:]
    @ObservationIgnored
    private var snapshotCacheOrder: [GitRepository.ID] = []
    /// 进行中的预取任务：选中仓库时可直接复用，避免同一仓库跑两遍 git status。
    @ObservationIgnored
    private var prefetchTasks: [GitRepository.ID: Task<RepositoryFileSnapshot, Error>] = [:]

    func load(for repository: GitRepository?) {
        loadTask?.cancel()
        loadTask = nil
        currentRepository = repository

        guard let repository else {
            resetState()
            return
        }

        let isSwitchingRepository = snapshot?.repositoryPath != repository.path

        // 缓存命中：立即显示旧快照（零等待），后台静默刷新；无变化时不递增版本号，
        // 右侧 diff 缓存得以保留，整条切换链路都不会闪烁。
        if isSwitchingRepository, let cachedSnapshot = snapshotCache[repository.id] {
            snapshot = cachedSnapshot
            errorMessage = nil
            isLoading = true

            loadTask = Task {
                do {
                    let freshSnapshot = try await fetchSnapshot(for: repository)
                    guard shouldApplyResult(for: repository) else { return }
                    applySnapshot(freshSnapshot)
                } catch {
                    guard shouldApplyResult(for: repository) else { return }
                    applyFailure(error)
                }
            }
            return
        }

        if isSwitchingRepository {
            snapshot = nil
        }

        isLoading = true
        errorMessage = nil

        loadTask = Task {
            do {
                let freshSnapshot = try await fetchSnapshot(for: repository)
                guard shouldApplyResult(for: repository) else { return }
                applySnapshot(freshSnapshot)
            } catch {
                guard shouldApplyResult(for: repository) else { return }
                applyFailure(error)
            }
        }
    }

    func refreshCurrentRepository() {
        load(for: currentRepository)
    }

    /// 预取仓库状态：只填充缓存、不动界面状态。
    /// 侧栏悬停时调用，用户点击前数据已经就绪，首次选中也能零等待。
    func prefetch(for repository: GitRepository) {
        guard
            snapshotCache[repository.id] == nil,
            prefetchTasks[repository.id] == nil,
            currentRepository?.id != repository.id
        else { return }

        let task = Task<RepositoryFileSnapshot, Error> { [loader] in
            try await loader.loadSnapshot(for: repository)
        }
        prefetchTasks[repository.id] = task

        Task { [weak self] in
            let result = await task.result

            guard let self else { return }
            prefetchTasks.removeValue(forKey: repository.id)

            // 用户尚未选中该仓库时只写缓存；若已选中，load 路径会复用同一个任务并自行落盘。
            if case let .success(snapshot) = result, currentRepository?.id != repository.id {
                storeSnapshotInCache(snapshot, for: repository)
            }
        }
    }

    private func fetchSnapshot(for repository: GitRepository) async throws -> RepositoryFileSnapshot {
        // 复用进行中的预取任务，避免选中仓库时重复执行 git status。
        if let prefetchTask = prefetchTasks[repository.id] {
            let snapshot = try await prefetchTask.value
            storeSnapshotInCache(snapshot, for: repository)
            return snapshot
        }

        let snapshot = try await loader.loadSnapshot(for: repository)
        storeSnapshotInCache(snapshot, for: repository)
        return snapshot
    }

    private func storeSnapshotInCache(_ snapshot: RepositoryFileSnapshot, for repository: GitRepository) {
        let repositoryID = repository.id
        snapshotCache[repositoryID] = snapshot
        snapshotCacheOrder.removeAll { $0 == repositoryID }
        snapshotCacheOrder.append(repositoryID)

        while snapshotCacheOrder.count > Self.maxCachedSnapshots {
            let evictedID = snapshotCacheOrder.removeFirst()
            snapshotCache.removeValue(forKey: evictedID)
        }
    }

    private func resetState() {
        snapshot = nil
        isLoading = false
        errorMessage = nil
        snapshotRevision += 1
    }

    private func applySnapshot(_ snapshot: RepositoryFileSnapshot) {
        let isUnchanged = self.snapshot == snapshot

        self.snapshot = snapshot
        isLoading = false
        errorMessage = nil

        // 数据没有变化时保持版本号不变：右侧 diff 缓存与选中态都不受影响。
        if !isUnchanged {
            snapshotRevision += 1
        }
    }

    private func applyFailure(_ error: Error) {
        isLoading = false

        // 已有内容时刷新失败：保留旧内容，顶部展示错误提示，不清空列表。
        if let snapshot, let currentRepository, snapshot.repositoryPath == currentRepository.path {
            errorMessage = GitCommandError.describe(error)
            return
        }

        snapshot = nil
        errorMessage = GitCommandError.describe(error)
        snapshotRevision += 1
    }

    private func shouldApplyResult(for repository: GitRepository) -> Bool {
        !Task.isCancelled && currentRepository?.id == repository.id
    }
}
