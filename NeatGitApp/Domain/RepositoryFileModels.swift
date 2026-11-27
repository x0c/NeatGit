import Foundation

enum RepositoryFileSection: String, CaseIterable, Hashable, Identifiable, Sendable {
    case changed
    case skipped
    case ignored

    var id: String { rawValue }

    var title: String {
        switch self {
        case .changed:
            return "待提交的文件更改"
        case .skipped:
            return "不提交的文件"
        case .ignored:
            return "忽略版本管理的文件"
        }
    }

    var iconName: String {
        switch self {
        case .changed:
            return "square.and.pencil"
        case .skipped:
            return "eye.slash"
        case .ignored:
            return "minus.circle"
        }
    }

    var emptyDescription: String {
        switch self {
        case .changed:
            return "当前没有 tracked 变更。"
        case .skipped:
            return "当前仓库没有 skip-worktree 文件。"
        case .ignored:
            return "当前没有匹配忽略规则的文件。"
        }
    }
}

struct RepositoryFileItem: Identifiable, Hashable, Sendable {
    let section: RepositoryFileSection
    let path: String
    let kind: RepositoryFileKind
    let state: RepositoryFileState
    let gitStatusCode: String?
    let previousPath: String?
    /// 高频展示与查找字段在后台创建状态时只计算一次。
    let id: String
    let displayName: String
    let relativePath: String
    let parentPath: String?
    let parentPathComponents: [String]

    init(
        section: RepositoryFileSection,
        path: String,
        kind: RepositoryFileKind,
        state: RepositoryFileState,
        gitStatusCode: String?,
        previousPath: String?
    ) {
        self.section = section
        self.path = path
        self.kind = kind
        self.state = state
        self.gitStatusCode = gitStatusCode
        self.previousPath = previousPath
        id = "\(section.rawValue):\(path)"

        let normalizedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
        relativePath = normalizedPath
        displayName = (normalizedPath as NSString).lastPathComponent
        let parent = (normalizedPath as NSString).deletingLastPathComponent
        parentPath = parent.isEmpty || parent == "." ? nil : parent
        parentPathComponents = parentPath?.split(separator: "/").map(String.init) ?? []
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.section == rhs.section
            && lhs.path == rhs.path
            && lhs.kind == rhs.kind
            && lhs.state == rhs.state
            && lhs.gitStatusCode == rhs.gitStatusCode
            && lhs.previousPath == rhs.previousPath
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(section)
        hasher.combine(path)
        hasher.combine(kind)
        hasher.combine(state)
        hasher.combine(gitStatusCode)
        hasher.combine(previousPath)
    }

    var statusSummary: String? {
        state.statusSummary
    }

    var isDeleted: Bool {
        [indexStatusCode, workTreeStatusCode].contains("D")
    }

    var isUntracked: Bool {
        state == .untracked
    }

    var indexStatusCode: Character? {
        gitStatusCode?.first
    }

    var workTreeStatusCode: Character? {
        guard let gitStatusCode else { return nil }
        return gitStatusCode.dropFirst().first
    }

    /// porcelain v2 / 短格式里全部七种「未合并状态」的状态码，与 `man git-status` 的对照表一致。
    ///
    /// 其中 `AA`（双方新增）与 `DD`（双方删除）不含字母 U，只认 U 会把它们漏成普通新增 / 删除。
    static let unmergedStatusCodes: Set<String> = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]

    /// 给定的两字符状态码是否表示未合并（冲突）。状态加载器与文件模型共用这一份判断。
    static func isUnmergedStatus(_ statusCode: String) -> Bool {
        unmergedStatusCodes.contains(statusCode)
    }

    var hasConflict: Bool {
        guard let gitStatusCode else { return false }
        return Self.isUnmergedStatus(gitStatusCode)
    }

    var isCheckableForCommit: Bool {
        section == .changed && !hasConflict
    }

    /// 默认提交会包含这个文件吗：可勾选且未被硬排除规则命中。
    ///
    /// 判定原先在提交服务与状态栏文案处各写一遍，两处一旦漂移，
    /// 就会出现「文案说提交 3 个、实际提交 2 个」的错位。
    var isCommittableByDefault: Bool {
        isCheckableForCommit && !CommitExclusion.shouldExcludeFromDefaultCommit(self)
    }

    var isStaged: Bool {
        guard section == .changed else { return false }
        guard let indexStatusCode else { return false }
        return indexStatusCode != "." && indexStatusCode != "?" && indexStatusCode != " "
    }

    var isTracked: Bool {
        !isUntracked
    }

    var hasUnstagedChanges: Bool {
        guard section == .changed else { return false }
        guard let workTreeStatusCode else { return false }
        return workTreeStatusCode != "."
    }

    var canMarkAsSkipped: Bool {
        guard section == .changed else { return false }
        return isTracked
    }

    var canRemoveFromSkipped: Bool {
        section == .skipped
    }

    var indexSyncPaths: [String] {
        var paths: [String] = []

        if let previousPath, previousPath != path {
            paths.append(previousPath)
        }

        paths.append(path)

        return paths
    }

    var supportsWorkingTreeDiff: Bool {
        guard section == .changed, !hasConflict else { return false }

        if isUntracked {
            return true
        }

        guard let workTreeStatusCode else { return false }
        return workTreeStatusCode != "."
    }

    var supportsStagedDiff: Bool {
        guard section == .changed, !hasConflict, !isUntracked else { return false }
        guard let indexStatusCode else { return false }
        return indexStatusCode != "."
    }

    var availableDiffModes: [RepositoryDiffMode] {
        var modes: [RepositoryDiffMode] = []

        if supportsWorkingTreeDiff {
            modes.append(.workingTree)
        }

        if supportsStagedDiff {
            modes.append(.staged)
        }

        return modes
    }

    var directoryIgnoreOptions: [RepositoryIgnoreDirectoryOption] {
        guard let parentPath else {
            return []
        }

        let components = parentPath.split(separator: "/").map(String.init)
        var currentComponents: [String] = []

        return components.map { component in
            currentComponents.append(component)
            return RepositoryIgnoreDirectoryOption(relativePath: currentComponents.joined(separator: "/"))
        }
    }

    func subgroupPath(depth: Int) -> String {
        let components = parentPathComponents
        guard !components.isEmpty else { return "" }
        return components.prefix(min(depth, components.count)).joined(separator: "/")
    }

    func parentPathDisplay(relativeTo subgroupPath: String?) -> String? {
        guard let parentPath else { return nil }
        guard let subgroupPath, !subgroupPath.isEmpty else { return parentPath }

        if parentPath == subgroupPath {
            return nil
        }

        let prefix = "\(subgroupPath)/"
        guard parentPath.hasPrefix(prefix) else {
            return parentPath
        }

        let remainder = String(parentPath.dropFirst(prefix.count))
        return remainder.isEmpty ? nil : remainder
    }
}

enum RepositoryFileKind: Hashable, Sendable {
    case file
    case directory

    var iconName: String {
        switch self {
        case .file:
            return "doc"
        case .directory:
            return "folder"
        }
    }
}

enum RepositoryFileState: Hashable, Sendable {
    case changed(String)
    case untracked
    case skipped
    case ignored

    var statusSummary: String? {
        switch self {
        case let .changed(summary):
            return summary
        case .untracked:
            return "未跟踪"
        case .skipped, .ignored:
            return nil
        }
    }
}

struct RepositoryIgnoreDirectoryOption: Identifiable, Hashable, Sendable {
    let relativePath: String

    var id: String { relativePath }
}

struct RepositoryFileSubgroup: Identifiable, Hashable, Sendable {
    private static let miscellaneousGroupPath = "__neatgit_misc__"
    private static let miscellaneousGroupTitle = "其他路径"

    let directoryPath: String
    let title: String
    let items: [RepositoryFileItem]

    var id: String {
        directoryPath.isEmpty ? "__root__" : directoryPath
    }

    static func makeSmartGroups(from items: [RepositoryFileItem]) -> [RepositoryFileSubgroup]? {
        guard items.count >= 6 else { return nil }

        let maxDepth = items.map { $0.parentPathComponents.count }.max() ?? 0
        guard maxDepth > 0 else { return nil }

        let candidates = (1...maxDepth).compactMap { depth in
            makeCandidate(depth: depth, items: items)
        }

        guard
            let bestCandidate = candidates.max(by: { $0.score < $1.score }),
            bestCandidate.isMeaningful
        else {
            return nil
        }

        return bestCandidate.groups
    }

    private static func makeCandidate(depth: Int, items: [RepositoryFileItem]) -> RepositoryFileGroupingCandidate? {
        let groupedItems = Dictionary(grouping: items) { $0.subgroupPath(depth: depth) }
        guard groupedItems.count > 1 else { return nil }

        let groupPaths = Array(groupedItems.keys)
        let titlesByPath = compactTitles(for: groupPaths)
        let originalIndexes = originalIndexesByFileID(for: items)

        let groups = groupPaths.compactMap { groupPath -> RepositoryFileSubgroup? in
            guard let groupItems = groupedItems[groupPath], !groupItems.isEmpty else { return nil }
            return RepositoryFileSubgroup(
                directoryPath: groupPath,
                title: titlesByPath[groupPath] ?? groupPath,
                items: groupItems.sorted { lhs, rhs in
                    (originalIndexes[lhs.id] ?? 0) < (originalIndexes[rhs.id] ?? 0)
                }
            )
        }
        .sorted { lhs, rhs in
            groupStartIndex(for: lhs, originalIndexes: originalIndexes)
                < groupStartIndex(for: rhs, originalIndexes: originalIndexes)
        }

        var candidates = [
            evaluateCandidate(depth: depth, groups: groups, fileCount: items.count)
        ]

        if let mergedGroups = mergedSingletonGroups(from: groups, originalIndexes: originalIndexes) {
            candidates.append(
                evaluateCandidate(depth: depth, groups: mergedGroups, fileCount: items.count)
            )
        }

        return candidates.max(by: { $0.score < $1.score })
    }

    private static func mergedSingletonGroups(
        from groups: [RepositoryFileSubgroup],
        originalIndexes: [RepositoryFileItem.ID: Int]
    ) -> [RepositoryFileSubgroup]? {
        let singletonGroups = groups.filter { $0.items.count == 1 }
        let groupedGroups = groups.filter { $0.items.count > 1 }

        guard singletonGroups.count >= 2, groupedGroups.count >= 2 else {
            return nil
        }

        let mergedItems = singletonGroups
            .flatMap(\.items)
            .sorted { lhs, rhs in
                (originalIndexes[lhs.id] ?? 0) < (originalIndexes[rhs.id] ?? 0)
            }

        let mergedGroup = RepositoryFileSubgroup(
            directoryPath: miscellaneousGroupPath,
            title: miscellaneousGroupTitle,
            items: mergedItems
        )

        return (groupedGroups + [mergedGroup]).sorted { lhs, rhs in
            groupStartIndex(for: lhs, originalIndexes: originalIndexes)
                < groupStartIndex(for: rhs, originalIndexes: originalIndexes)
        }
    }

    private static func groupStartIndex(
        for group: RepositoryFileSubgroup,
        originalIndexes: [RepositoryFileItem.ID: Int]
    ) -> Int {
        group.items.compactMap { originalIndexes[$0.id] }.min() ?? 0
    }

    private static func originalIndexesByFileID(for items: [RepositoryFileItem]) -> [RepositoryFileItem.ID: Int] {
        var indexes: [RepositoryFileItem.ID: Int] = [:]

        for (index, item) in items.enumerated() {
            if indexes[item.id] == nil {
                indexes[item.id] = index
            }
        }

        return indexes
    }

    private static func evaluateCandidate(
        depth: Int,
        groups: [RepositoryFileSubgroup],
        fileCount: Int
    ) -> RepositoryFileGroupingCandidate {
        let sizes = groups.map { $0.items.count }
        let groupCount = groups.count
        let idealGroupCount = min(max(Int(Double(fileCount).squareRoot().rounded()), 2), 6)
        let singletonCount = sizes.filter { $0 == 1 }.count
        let maxGroupSize = sizes.max() ?? 0
        let maxGroupRatio = Double(maxGroupSize) / Double(fileCount)
        let singletonRatio = Double(singletonCount) / Double(groupCount)
        let averageGroupSize = Double(fileCount) / Double(groupCount)
        let idealAverageGroupSize = Double(fileCount) / Double(idealGroupCount)
        let rootGroupRatio = Double(groups.first(where: { $0.directoryPath.isEmpty })?.items.count ?? 0) / Double(fileCount)

        var score = 100.0
        score -= Double(abs(groupCount - idealGroupCount)) * 12
        score -= abs(averageGroupSize - idealAverageGroupSize) * 6
        score -= singletonRatio * 28
        score -= max(0, maxGroupRatio - 0.55) * 120
        score -= max(0, rootGroupRatio - 0.35) * 35

        if groupCount >= fileCount {
            score -= 80
        }

        if groupCount == 2, maxGroupRatio > 0.72 {
            score -= 28
        }

        let isMeaningful =
            score >= 52 &&
            groupCount >= 2 &&
            singletonRatio <= 0.55 &&
            maxGroupRatio <= 0.78

        return RepositoryFileGroupingCandidate(
            depth: depth,
            groups: groups,
            score: score,
            isMeaningful: isMeaningful
        )
    }

    private static func compactTitles(for groupPaths: [String]) -> [String: String] {
        let normalizedPaths = groupPaths.filter { !$0.isEmpty }
        let pathComponents = Dictionary(uniqueKeysWithValues: normalizedPaths.map { path in
            (path, path.split(separator: "/").map(String.init))
        })

        var titles: [String: String] = [:]

        for path in groupPaths {
            guard !path.isEmpty else {
                titles[path] = "仓库根目录"
                continue
            }

            let components = pathComponents[path] ?? []
            guard !components.isEmpty else {
                titles[path] = path
                continue
            }

            for suffixLength in 1...components.count {
                let suffix = components.suffix(suffixLength).joined(separator: "/")
                let isUnique = normalizedPaths.allSatisfy { otherPath in
                    guard otherPath != path else { return true }
                    let otherComponents = pathComponents[otherPath] ?? []
                    return otherComponents.suffix(suffixLength).joined(separator: "/") != suffix
                }

                if isUnique || suffixLength == components.count {
                    titles[path] = suffix
                    break
                }
            }
        }

        return titles
    }
}

private struct RepositoryFileGroupingCandidate {
    let depth: Int
    let groups: [RepositoryFileSubgroup]
    let score: Double
    let isMeaningful: Bool
}

struct RepositoryFileSnapshot: Sendable, Equatable {
    let repositoryPath: String
    let changedFiles: [RepositoryFileItem]
    let skippedFiles: [RepositoryFileItem]
    let ignoredFiles: [RepositoryFileItem]
    /// 以下派生数据在后台构建快照时只算一次，供每次界面刷新、文件选择与提交摘要复用。
    let allFiles: [RepositoryFileItem]
    let committableCount: Int
    let excludedFromCommitCount: Int
    private let filesByID: [RepositoryFileItem.ID: RepositoryFileItem]
    private let smartGroups: [RepositoryFileSection: [RepositoryFileSubgroup]]

    init(
        repositoryPath: String,
        changedFiles: [RepositoryFileItem],
        skippedFiles: [RepositoryFileItem],
        ignoredFiles: [RepositoryFileItem]
    ) {
        self.repositoryPath = repositoryPath
        self.changedFiles = changedFiles
        self.skippedFiles = skippedFiles
        self.ignoredFiles = ignoredFiles
        allFiles = changedFiles + skippedFiles + ignoredFiles
        committableCount = changedFiles.reduce(into: 0) { count, item in
            if item.isCommittableByDefault { count += 1 }
        }
        excludedFromCommitCount = changedFiles.reduce(into: 0) { count, item in
            if CommitExclusion.shouldExcludeFromDefaultCommit(item) { count += 1 }
        }
        filesByID = Dictionary(allFiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var groups: [RepositoryFileSection: [RepositoryFileSubgroup]] = [:]
        for section in RepositoryFileSection.allCases {
            let items: [RepositoryFileItem]
            switch section {
            case .changed: items = changedFiles
            case .skipped: items = skippedFiles
            case .ignored: items = ignoredFiles
            }
            if let sectionGroups = RepositoryFileSubgroup.makeSmartGroups(from: items) {
                groups[section] = sectionGroups
            }
        }
        smartGroups = groups
    }

    var isEmpty: Bool {
        allFiles.isEmpty
    }

    func files(in section: RepositoryFileSection) -> [RepositoryFileItem] {
        switch section {
        case .changed:
            return changedFiles
        case .skipped:
            return skippedFiles
        case .ignored:
            return ignoredFiles
        }
    }

    func file(withID id: RepositoryFileItem.ID) -> RepositoryFileItem? {
        filesByID[id]
    }

    func smartGroups(in section: RepositoryFileSection) -> [RepositoryFileSubgroup]? {
        smartGroups[section]
    }

    /// 派生索引与分组完全由三个文件数组决定，不参与重复比较，避免刷新时做两份全量比较。
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.repositoryPath == rhs.repositoryPath
            && lhs.changedFiles == rhs.changedFiles
            && lhs.skippedFiles == rhs.skippedFiles
            && lhs.ignoredFiles == rhs.ignoredFiles
    }
}
