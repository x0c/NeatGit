import Foundation
import Observation

@MainActor
@Observable
final class RepositoryDiffStore {
    private static let hoverPrefetchDelayNanoseconds: UInt64 = 60_000_000
    private static let maxCachedDocuments = 24

    private(set) var document: RepositoryDiffDocument?
    private(set) var displayedDocument: RepositoryDiffDocument?
    private(set) var isLoading = false
    private(set) var showChangesOnly = false
    private(set) var headerTitle = "文件对比"
    private(set) var headerSubtitle = "选择一个文件"
    private(set) var messageTitle = "选择一个文件"
    private(set) var messageBody = "从左侧选择单个更改文件后，这里会展示单文件 diff 预览。"

    @ObservationIgnored
    private let loader = GitRepositoryDiffLoader()
    private var currentRepository: GitRepository?
    private var currentItem: RepositoryFileItem?
    @ObservationIgnored
    private var loadTask: Task<Void, Never>?
    @ObservationIgnored
    private var hoverPrefetchTask: Task<Void, Never>?
    @ObservationIgnored
    private var cachedDocuments: [CacheKey: RepositoryDiffDocument] = [:]
    @ObservationIgnored
    private var cacheOrder: [CacheKey] = []
    @ObservationIgnored
    private var inflightLoads: [CacheKey: Task<RepositoryDiffDocument, Error>] = [:]
    @ObservationIgnored
    private var inflightLoadIDs: [CacheKey: UUID] = [:]
    @ObservationIgnored
    private var cacheRevisions: [String: Int] = [:]
    private(set) var activeMode: RepositoryDiffMode = .staged

    func select(
        repository: GitRepository?,
        selectedFiles: [RepositoryFileItem],
        cacheRevision: Int
    ) {
        let retainedMode = currentRepository?.id == repository?.id
            && selectedFiles.count == 1
            && currentItem?.id == selectedFiles.first?.id ? activeMode : nil

        loadTask?.cancel()
        loadTask = nil
        hoverPrefetchTask?.cancel()
        hoverPrefetchTask = nil
        currentRepository = repository
        currentItem = nil
        document = nil
        isLoading = false

        guard let repository else {
            showPlaceholder(
                title: "先选择一个仓库",
                body: "选中左侧仓库后，再从文件列表里选择一个文件。"
            )
            displayedDocument = nil
            return
        }

        updateCacheRevisionIfNeeded(for: repository, cacheRevision: cacheRevision)

        guard !selectedFiles.isEmpty else {
            showPlaceholder(
                title: "选择一个文件",
                body: "当前仓库：\(repository.path)\n从左侧选择单个更改文件后，这里会展示单文件 diff 预览。"
            )
            return
        }

        guard selectedFiles.count == 1, let item = selectedFiles.first else {
            showPlaceholder(
                title: "暂不支持多文件对照",
                body: "当前已选中 \(selectedFiles.count) 个文件。第一版先聚焦单文件 diff。"
            )
            return
        }

        guard let mode = displayableMode(for: item, preferred: retainedMode) else {
            showPlaceholder(
                title: unsupportedTitle(for: item),
                body: unsupportedMessage(for: item)
            )
            return
        }

        currentItem = item
        activeMode = mode
        headerTitle = item.path
        headerSubtitle = mode.title

        if let cachedDocument = cachedDocument(for: repository, item: item, mode: mode) {
            applyDocument(cachedDocument, for: item)
            return
        }

        loadCurrentSelection()
    }

    func scheduleHoverPrefetch(
        repository: GitRepository?,
        hoveredFile: RepositoryFileItem?,
        cacheRevision: Int
    ) {
        hoverPrefetchTask?.cancel()
        hoverPrefetchTask = nil

        guard let repository, let hoveredFile else { return }

        updateCacheRevisionIfNeeded(for: repository, cacheRevision: cacheRevision)

        guard let mode = displayableMode(for: hoveredFile) else { return }
        guard currentItem?.id != hoveredFile.id else { return }
        guard cachedDocument(for: repository, item: hoveredFile, mode: mode) == nil else { return }

        hoverPrefetchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.hoverPrefetchDelayNanoseconds)
                guard !Task.isCancelled else { return }
                try await self?.prefetchDocument(for: repository, item: hoveredFile, mode: mode)
            } catch {
                return
            }
        }
    }

    var availableModes: [RepositoryDiffMode] {
        currentItem?.availableDiffModes ?? []
    }

    func selectMode(_ mode: RepositoryDiffMode) {
        guard mode != activeMode, availableModes.contains(mode) else { return }
        activeMode = mode

        if let repository = currentRepository, let item = currentItem,
           let cached = cachedDocument(for: repository, item: item, mode: mode) {
            loadTask?.cancel()
            applyDocument(cached, for: item)
            return
        }

        loadCurrentSelection()
    }

    func toggleShowChangesOnly() {
        showChangesOnly.toggle()
    }

    var payloadForDisplay: MonacoDiffPayload? {
        displayedDocument?.monacoPayload
    }

    var showsPlaceholder: Bool {
        document == nil && !isLoading
    }

    var showsVisibilityToggle: Bool {
        document != nil
    }

    var visibilityToggleTitle: String {
        showChangesOnly ? "展开全文" : "只看变更"
    }

    var visibilityToggleSystemImage: String {
        showChangesOnly ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left"
    }

    private func preferredMode(for item: RepositoryFileItem) -> RepositoryDiffMode {
        if item.supportsStagedDiff {
            return .staged
        }

        return .workingTree
    }

    private func displayableMode(
        for item: RepositoryFileItem,
        preferred retainedMode: RepositoryDiffMode? = nil
    ) -> RepositoryDiffMode? {
        guard item.section == .changed else { return nil }
        if let retainedMode, item.availableDiffModes.contains(retainedMode) {
            return retainedMode
        }

        let mode = preferredMode(for: item)
        guard item.availableDiffModes.contains(mode) else {
            return nil
        }

        return mode
    }

    private func loadCurrentSelection() {
        loadTask?.cancel()
        document = nil

        guard let repository = currentRepository, let item = currentItem else {
            isLoading = false
            return
        }

        isLoading = true
        messageTitle = item.path
        messageBody = "读取 \(item.path) 的 \(activeMode.title) 内容中..."
        headerTitle = item.path
        headerSubtitle = activeMode.title

        loadTask = Task {
            do {
                let document = try await loadDocument(for: repository, item: item, mode: activeMode)
                guard shouldApplyResult(for: repository, item: item) else { return }
                applyDocument(document, for: item)
            } catch {
                guard shouldApplyResult(for: repository, item: item) else { return }
                applyFailure(error)
            }
        }
    }

    private func showPlaceholder(title: String, body: String) {
        headerTitle = title
        headerSubtitle = "文件对比"
        messageTitle = title
        messageBody = body
    }

    private func applyDocument(_ document: RepositoryDiffDocument, for item: RepositoryFileItem) {
        self.document = document
        displayedDocument = document
        isLoading = false
        headerTitle = item.path
        headerSubtitle = document.mode.title
        messageTitle = item.path
        messageBody = "\(document.mode.title) diff 已准备好。"
        cache(document, for: CacheKey(repositoryID: document.repositoryPath, itemID: item.id, mode: document.mode))
    }

    private func applyFailure(_ error: Error) {
        document = nil
        isLoading = false
        headerTitle = currentItem?.path ?? "文件对比"
        headerSubtitle = "无法展示 diff"
        messageTitle = "无法展示 diff"
        messageBody = GitCommandError.describe(error)
    }

    private func shouldApplyResult(for repository: GitRepository, item: RepositoryFileItem) -> Bool {
        !Task.isCancelled &&
        currentRepository?.id == repository.id &&
        currentItem?.id == item.id
    }

    private func cachedDocument(
        for repository: GitRepository,
        item: RepositoryFileItem,
        mode: RepositoryDiffMode
    ) -> RepositoryDiffDocument? {
        let key = CacheKey(repositoryID: repository.path, itemID: item.id, mode: mode)
        return cachedDocuments[key]
    }

    private func cache(_ document: RepositoryDiffDocument, for key: CacheKey) {
        cachedDocuments[key] = document
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)

        while cacheOrder.count > Self.maxCachedDocuments {
            let evictedKey = cacheOrder.removeFirst()
            cachedDocuments.removeValue(forKey: evictedKey)
        }
    }

    private func loadDocument(
        for repository: GitRepository,
        item: RepositoryFileItem,
        mode: RepositoryDiffMode
    ) async throws -> RepositoryDiffDocument {
        let key = CacheKey(repositoryID: repository.path, itemID: item.id, mode: mode)

        if let cachedDocument = cachedDocuments[key] {
            return cachedDocument
        }

        if let inflightTask = inflightLoads[key] {
            return try await inflightTask.value
        }

        let task = Task<RepositoryDiffDocument, Error> {
            try await loader.loadDiff(for: item, in: repository, mode: mode)
        }
        let taskID = UUID()
        inflightLoads[key] = task
        inflightLoadIDs[key] = taskID

        defer {
            if inflightLoadIDs[key] == taskID {
                inflightLoads.removeValue(forKey: key)
                inflightLoadIDs.removeValue(forKey: key)
            }
        }

        let document = try await task.value
        cache(document, for: key)
        return document
    }

    private func prefetchDocument(
        for repository: GitRepository,
        item: RepositoryFileItem,
        mode: RepositoryDiffMode
    ) async throws {
        _ = try await loadDocument(for: repository, item: item, mode: mode)
    }

    private func updateCacheRevisionIfNeeded(for repository: GitRepository, cacheRevision: Int) {
        let repositoryID = repository.path

        guard cacheRevisions[repositoryID] != cacheRevision else { return }
        cacheRevisions[repositoryID] = cacheRevision

        cachedDocuments = cachedDocuments.filter { $0.key.repositoryID != repositoryID }
        cacheOrder.removeAll { $0.repositoryID == repositoryID }

        let inflightKeys = inflightLoads.keys.filter { $0.repositoryID == repositoryID }
        for key in inflightKeys {
            inflightLoads[key]?.cancel()
            inflightLoads.removeValue(forKey: key)
            inflightLoadIDs.removeValue(forKey: key)
        }

        if document?.repositoryPath == repositoryID {
            document = nil
            displayedDocument = nil
        }
    }

    private func unsupportedTitle(for item: RepositoryFileItem) -> String {
        if item.section != .changed {
            return "这个文件暂不支持 diff"
        }

        return "这个文件当前没有可展示的 diff"
    }

    private func unsupportedMessage(for item: RepositoryFileItem) -> String {
        if item.section != .changed {
            return "skip-worktree 和 ignored 文件先保留列表能力，后面再补右侧预览。"
        }

        return "如果它是冲突文件、目录占位或特殊 Git 状态，第一版会先给出说明。"
    }
}

private struct CacheKey: Hashable {
    let repositoryID: String
    let itemID: RepositoryFileItem.ID
    let mode: RepositoryDiffMode
}
