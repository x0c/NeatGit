import Observation

/// 侧栏仓库行的悬停事件。
///
/// 侧栏只负责原样上报「进入 / 离开哪一行」；停留判定、在途数量上限与取消
/// 都收在 `RepositoryStatusStore` 里统一处理，避免每碰一行就起一轮 git 进程。
enum RepositoryHoverEvent {
    case entered(GitRepository)
    case exited(GitRepository)
}

@MainActor
@Observable
final class RepositoryStatusStore {
    /// 跨仓库快照缓存上限：覆盖用户近期来回切换的仓库，超出后淘汰最久未使用的。
    private static let maxCachedSnapshots = 10
    /// 悬停停留多久才开始预取；鼠标快速划过不触发。
    static let defaultHoverPrefetchDelay = Duration.milliseconds(200)

    private(set) var snapshot: RepositoryFileSnapshot?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var snapshotRevision = 0

    @ObservationIgnored
    private let loadSnapshot: (GitRepository) async throws -> RepositoryFileSnapshot
    @ObservationIgnored
    private let hoverPrefetchDelay: Duration
    @ObservationIgnored
    private var currentRepository: GitRepository?
    @ObservationIgnored
    private var loadTask: Task<Void, Never>?
    /// 跨仓库快照缓存（stale-while-revalidate 的 stale 部分）。
    @ObservationIgnored
    private var snapshotCache: [GitRepository.ID: RepositoryFileSnapshot] = [:]
    @ObservationIgnored
    private var snapshotCacheOrder: [GitRepository.ID] = []
    /// 当前悬停目标：最近进入且尚未离开的仓库行。
    @ObservationIgnored
    private var hoveredRepository: GitRepository?
    /// 悬停停留计时；换行或离开时作废。
    @ObservationIgnored
    private var hoverDelayTask: Task<Void, Never>?
    /// 唯一在途的预取任务：选中同仓库时直接复用，避免同一仓库跑两遍 git status。
    @ObservationIgnored
    private var inFlightPrefetch: InFlightPrefetch?
    /// 在途期间新确认的悬停目标，只保留最新一个，等在途结束后再决定是否执行。
    @ObservationIgnored
    private var queuedPrefetch: GitRepository?

    private struct InFlightPrefetch {
        let repository: GitRepository
        let task: Task<RepositoryFileSnapshot, Error>
    }

    init(
        hoverPrefetchDelay: Duration = RepositoryStatusStore.defaultHoverPrefetchDelay,
        loadSnapshot: @escaping (GitRepository) async throws -> RepositoryFileSnapshot = GitRepositoryStatusLoader().loadSnapshot(for:)
    ) {
        self.hoverPrefetchDelay = hoverPrefetchDelay
        self.loadSnapshot = loadSnapshot
    }

    /// 是否有预取在途（测试与排查时的观察口径，不属于界面状态）。
    var isPrefetchInFlight: Bool {
        inFlightPrefetch != nil
    }

    /// 悬停停留是否仍在计时。
    var isWaitingForHoverDelay: Bool {
        hoverDelayTask != nil
    }

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
                    let interval = InteractionProfiler.begin("仓库状态.缓存命中后刷新")
                    let freshSnapshot = try await fetchSnapshot(for: repository)
                    interval.end()
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
                let interval = InteractionProfiler.begin("仓库状态.完整读取")
                let freshSnapshot = try await fetchSnapshot(for: repository)
                interval.end()
                guard shouldApplyResult(for: repository) else { return }
                applySnapshot(freshSnapshot)
            } catch {
                guard shouldApplyResult(for: repository) else { return }
                applyFailure(error)
            }
        }
    }

    func refreshCurrentRepository() {
        InteractionProfiler.measure("刷新文件.点击处理") {
            load(for: currentRepository)
        }
    }

    /// 处理侧栏仓库行的悬停事件，按需预取仓库状态。
    ///
    /// 预取只填充缓存、不动界面状态；用户点击前数据已经就绪，首次选中也能零等待。
    /// 约束：停留满 `hoverPrefetchDelay` 才开始；同时最多一个在途；在途期间只记住
    /// 最新的悬停目标；离开全部行时尚未开始的一律作废。
    func prefetch(for event: RepositoryHoverEvent) {
        switch event {
        case .entered(let repository):
            setHoveredRepository(repository)
        case .exited(let repository):
            // 行间移动时上一行的离开回调可能晚于新行的进入，只认「离开的是当前目标」。
            guard hoveredRepository?.id == repository.id else { return }
            setHoveredRepository(nil)
        }
    }

    private func setHoveredRepository(_ repository: GitRepository?) {
        guard repository?.id != hoveredRepository?.id else { return }
        hoveredRepository = repository
        hoverDelayTask?.cancel()
        hoverDelayTask = nil
        // 排队的目标只跟随当前悬停行；换了目标就等新目标自己的停留计时。
        queuedPrefetch = nil

        // 无需预取的行（已有缓存或正是当前仓库）不计时。
        guard let repository, needsPrefetch(repository) else { return }

        hoverDelayTask = Task { [weak self, hoverPrefetchDelay] in
            try? await Task.sleep(for: hoverPrefetchDelay)
            guard !Task.isCancelled, let self else { return }
            self.hoverDelayTask = nil
            self.requestPrefetch(for: repository)
        }
    }

    /// 停留时间已到：没有在途预取就开始，否则只记下这一个。
    private func requestPrefetch(for repository: GitRepository) {
        guard
            hoveredRepository?.id == repository.id,
            needsPrefetch(repository)
        else { return }

        guard let inFlightPrefetch else {
            startPrefetch(for: repository)
            return
        }

        // 同一仓库已在途：等它完成即可，不必排队。
        if inFlightPrefetch.repository.id != repository.id {
            queuedPrefetch = repository
        }
    }

    private func needsPrefetch(_ repository: GitRepository) -> Bool {
        snapshotCache[repository.id] == nil && currentRepository?.id != repository.id
    }

    private func startPrefetch(for repository: GitRepository) {
        let task = Task<RepositoryFileSnapshot, Error> { [loadSnapshot] in
            let interval = InteractionProfiler.begin("仓库状态.悬停预取")
            defer { interval.end() }
            return try await loadSnapshot(repository)
        }
        inFlightPrefetch = InFlightPrefetch(repository: repository, task: task)

        Task { [weak self] in
            let result = await task.result

            guard let self else { return }
            self.finishPrefetch(for: repository, result: result)
        }
    }

    private func finishPrefetch(for repository: GitRepository, result: Result<RepositoryFileSnapshot, Error>) {
        inFlightPrefetch = nil

        // 用户尚未选中该仓库时只写缓存；若已选中，load 路径会复用同一个任务并自行落盘。
        if case let .success(snapshot) = result, currentRepository?.id != repository.id {
            storeSnapshotInCache(snapshot, for: repository)
        }

        // 在途结束后再处理排队的最新目标：期间已离开或已不需要的不执行。
        guard let queuedRepository = queuedPrefetch else { return }
        queuedPrefetch = nil
        requestPrefetch(for: queuedRepository)
    }

    private func fetchSnapshot(for repository: GitRepository) async throws -> RepositoryFileSnapshot {
        // 复用进行中的预取任务，避免选中仓库时重复执行 git status。
        if let inFlightPrefetch, inFlightPrefetch.repository.id == repository.id {
            let snapshot = try await inFlightPrefetch.task.value
            storeSnapshotInCache(snapshot, for: repository)
            return snapshot
        }

        let snapshot = try await loadSnapshot(repository)
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
        InteractionProfiler.measure("仓库状态.主线程应用", detail: "文件数：\(snapshot.allFiles.count)") {
            let isUnchanged = self.snapshot == snapshot

            self.snapshot = snapshot
            isLoading = false
            errorMessage = nil

            // 数据没有变化时保持版本号不变：右侧 diff 缓存与选中态都不受影响。
            if !isUnchanged {
                snapshotRevision += 1
            }
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
