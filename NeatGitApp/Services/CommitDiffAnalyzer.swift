import Foundation

struct PromptBudget: Sendable {
    let summaryLimit: Int
    let detailedItemLimit: Int
    let patchDisplayLimit: Int
    let maxHunksPerPatch: Int
    let maxChangedLinesPerHunk: Int
    let maxSnippetCharacters: Int

    static func forFileCount(_ fileCount: Int) -> PromptBudget {
        let proportionalPatchLimit = Int((Double(fileCount) * 0.5).rounded(.up))
        let patchLimit = min(15, max(6, proportionalPatchLimit))

        let summaryLimit = min(48, max(18, patchLimit * 3))
        let isLargeChangeSet = fileCount >= 20
        let isVeryLargeChangeSet = fileCount >= 30

        return PromptBudget(
            summaryLimit: summaryLimit,
            detailedItemLimit: patchLimit,
            patchDisplayLimit: patchLimit,
            maxHunksPerPatch: isVeryLargeChangeSet ? 1 : 2,
            maxChangedLinesPerHunk: isLargeChangeSet ? 10 : 12,
            maxSnippetCharacters: isVeryLargeChangeSet ? 850 : (isLargeChangeSet ? 950 : 1_100)
        )
    }
}

struct FileAnalysis: Sendable {
    let item: RepositoryFileItem
    let changeKind: ChangeKind
    let moduleLabel: String
    let diffStat: DiffLineStat
    let snippet: String?
    let symbolHints: [String]
    let featureFlags: CommitGenerationFeatureFlags

    var score: Int {
        let symbolScore = symbolHints.count * 8
        let snippetScore = snippet == nil ? 0 : 24
        let statScore = min(diffStat.total, 180)
        let kindWeight = featureFlags.useChangeKindPriority ? changeKind.analysisWeight : 0
        let modWeight = featureFlags.useChangeKindPriority ? moduleWeight : 0
        return statScore + modWeight + statusWeight + symbolScore + snippetScore + kindWeight
    }

    var summaryLine: String {
        var parts = [
            "\(statusLabel) \(item.path)",
            "模块: \(moduleLabel)",
            "类型: \(changeKind.label)"
        ]

        if diffStat.total > 0 {
            parts.append("变更: +\(diffStat.added)/-\(diffStat.deleted)")
        }

        if !symbolHints.isEmpty {
            parts.append("关键点: \(symbolHints.joined(separator: ", "))")
        }

        return "- " + parts.joined(separator: " | ")
    }

    private var statusLabel: String {
        item.statusSummary ?? "未知状态"
    }

    private var moduleWeight: Int {
        switch moduleLabel {
        case "Services":
            return 42
        case "Stores":
            return 38
        case "Domain":
            return 34
        case "Views":
            return 28
        case "App":
            return 24
        case "Resources":
            return 8
        default:
            return 16
        }
    }

    private var statusWeight: Int {
        if item.hasConflict {
            return -40
        }

        if item.isDeleted {
            return 18
        }

        if item.previousPath != nil {
            return 16
        }

        if item.isUntracked {
            return 22
        }

        if item.isStaged && item.hasUnstagedChanges {
            return 20
        }

        if item.isStaged {
            return 14
        }

        return 10
    }
}

struct CommitAnalysisContext: Sendable {
    let repository: GitRepository
    let committableItems: [RepositoryFileItem]
    let excludedItemCount: Int
    let fileSummaries: [String]
    let patchSummaries: [String]
    let moduleSummary: String
    let changeOverview: String
    let focusGuidance: String
    let primarySignals: [String]
    let hasProductionCodeChanges: Bool
    let hasTestChanges: Bool
    let expectedKeywords: [String]
    let displayKeywords: [String]
    let totalDiffLines: Int
}

final class CommitDiffAnalyzer: @unchecked Sendable {
    func analyze(
        for repository: GitRepository,
        changedItems: [RepositoryFileItem],
        featureFlags: CommitGenerationFeatureFlags = .default
    ) throws -> CommitAnalysisContext {
        let committableItems = changedItems.filter { item in
            item.isCheckableForCommit && !CommitExclusion.shouldExcludeFromDefaultCommit(item)
        }

        guard !committableItems.isEmpty else {
            throw GitCommandError(message: "当前没有可供 AI 分析的可提交文件变更。")
        }

        let budget = PromptBudget.forFileCount(committableItems.count)

        let stagedStats = loadDiffStats(in: repository.path, items: committableItems, cached: true)
        let unstagedStats = loadDiffStats(in: repository.path, items: committableItems, cached: false)

        let detailedItemIDs: Set<RepositoryFileItem.ID>
        if featureFlags.useFileSelectionBudget {
            let topDetailedItems = selectDetailedItems(
                from: committableItems,
                stagedStats: stagedStats,
                unstagedStats: unstagedStats,
                limit: budget.detailedItemLimit,
                featureFlags: featureFlags
            )
            detailedItemIDs = Set(topDetailedItems.map(\.id))
        } else {
            detailedItemIDs = Set(committableItems.map(\.id))
        }

        let analyses = committableItems.map { item in
            var diffStat = self.diffStat(for: item, stagedStats: stagedStats, unstagedStats: unstagedStats)
            var snippet: String?
            var symbolHints: [String] = []
            let changeKind = ChangeKind.classify(for: item.path)

            if detailedItemIDs.contains(item.id) {
                snippet = loadCondensedSnippet(for: item, in: repository.path, budget: budget)
                symbolHints = snippet.map(extractSymbolHints(from:)) ?? []

                if diffStat.total == 0, let snippet {
                    diffStat = DiffLineStat.fromPatch(snippet)
                }
            }

            return FileAnalysis(
                item: item,
                changeKind: changeKind,
                moduleLabel: moduleLabel(for: item.path),
                diffStat: diffStat,
                snippet: snippet,
                symbolHints: symbolHints,
                featureFlags: featureFlags
            )
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.item.path.localizedCaseInsensitiveCompare(rhs.item.path) == .orderedAscending
            }

            return lhs.score > rhs.score
        }

        let patchSummaries = analyses.compactMap { analysis -> String? in
            guard let snippet = analysis.snippet, !snippet.isEmpty else { return nil }

            return """
            [\(analysis.item.path)]
            \(snippet)
            """
        }

        let totalDiffLines = analyses.reduce(0) { $0 + $1.diffStat.total }

        let focusGuidance: String
        if featureFlags.useChangeKindPriority {
            focusGuidance = CommitPromptBuilder.focusGuidance(from: analyses)
        } else {
            focusGuidance = "优先总结最影响行为和结构的改动。"
        }

        return CommitAnalysisContext(
            repository: repository,
            committableItems: committableItems,
            excludedItemCount: changedItems.count - committableItems.count,
            fileSummaries: analyses.map(\.summaryLine),
            patchSummaries: patchSummaries,
            moduleSummary: CommitPromptBuilder.moduleSummary(from: analyses),
            changeOverview: CommitPromptBuilder.changeOverview(from: analyses),
            focusGuidance: focusGuidance,
            primarySignals: CommitPromptBuilder.primarySignals(from: analyses),
            hasProductionCodeChanges: analyses.contains { $0.changeKind == .sourceCode },
            hasTestChanges: analyses.contains { $0.changeKind == .testCode },
            expectedKeywords: CommitPromptBuilder.expectedKeywords(from: analyses),
            displayKeywords: CommitPromptBuilder.displayKeywords(from: analyses),
            totalDiffLines: totalDiffLines
        )
    }

    func fileSummariesForMapReduce(
        for repository: GitRepository,
        changedItems: [RepositoryFileItem]
    ) throws -> [FileMapInput] {
        let committableItems = changedItems.filter { item in
            item.isCheckableForCommit && !CommitExclusion.shouldExcludeFromDefaultCommit(item)
        }

        guard !committableItems.isEmpty else {
            throw GitCommandError(message: "当前没有可供 AI 分析的可提交文件变更。")
        }

        let budget = PromptBudget.forFileCount(committableItems.count)

        return committableItems.map { item in
            let changeKind = ChangeKind.classify(for: item.path)
            let snippet = loadCondensedSnippet(for: item, in: repository.path, budget: budget)

            return FileMapInput(
                path: item.path,
                changeKind: changeKind,
                statusLabel: item.statusSummary ?? "未知状态",
                diffStat: snippet.map { DiffLineStat.fromPatch($0) }
                    ?? DiffLineStat(added: 0, deleted: 0),
                snippet: snippet
            )
        }
    }

    private func selectDetailedItems(
        from items: [RepositoryFileItem],
        stagedStats: [String: DiffLineStat],
        unstagedStats: [String: DiffLineStat],
        limit: Int,
        featureFlags: CommitGenerationFeatureFlags
    ) -> [RepositoryFileItem] {
        items.sorted { lhs, rhs in
            let lhsScore = rankingScore(for: lhs, stagedStats: stagedStats, unstagedStats: unstagedStats, featureFlags: featureFlags)
            let rhsScore = rankingScore(for: rhs, stagedStats: stagedStats, unstagedStats: unstagedStats, featureFlags: featureFlags)

            if lhsScore == rhsScore {
                return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
            }

            return lhsScore > rhsScore
        }
        .prefix(limit)
        .map { $0 }
    }

    private func rankingScore(
        for item: RepositoryFileItem,
        stagedStats: [String: DiffLineStat],
        unstagedStats: [String: DiffLineStat],
        featureFlags: CommitGenerationFeatureFlags
    ) -> Int {
        let stat = diffStat(for: item, stagedStats: stagedStats, unstagedStats: unstagedStats)
        var score = min(stat.total, 180)

        if item.isUntracked {
            score += 30
        }

        if item.previousPath != nil {
            score += 22
        }

        if item.isDeleted {
            score += 16
        }

        if featureFlags.useChangeKindPriority {
            score += ChangeKind.classify(for: item.path).detailWeight

            switch moduleLabel(for: item.path) {
            case "Services":
                score += 24
            case "Stores":
                score += 20
            case "Domain":
                score += 16
            case "Views":
                score += 12
            default:
                break
            }
        }

        return score
    }

    private func diffStat(
        for item: RepositoryFileItem,
        stagedStats: [String: DiffLineStat],
        unstagedStats: [String: DiffLineStat]
    ) -> DiffLineStat {
        var combined = DiffLineStat()

        for path in item.indexSyncPaths {
            if let stagedStat = stagedStats[path] {
                combined.merge(stagedStat)
            }

            if let unstagedStat = unstagedStats[path] {
                combined.merge(unstagedStat)
            }
        }

        return combined
    }

    private func loadDiffStats(
        in repositoryPath: String,
        items: [RepositoryFileItem],
        cached: Bool
    ) -> [String: DiffLineStat] {
        let uniquePaths = Array(Set(items.flatMap(\.indexSyncPaths))).sorted()
        guard !uniquePaths.isEmpty else { return [:] }

        var arguments = ["diff", "--numstat", "--no-ext-diff", "--no-color", "--no-renames"]
        if cached {
            arguments.append("--cached")
        }
        arguments.append("--")
        arguments.append(contentsOf: uniquePaths)

        guard let output = try? runGit(in: repositoryPath, arguments: arguments) else {
            return [:]
        }

        return DiffLineStat.parseNumstatOutput(output)
    }

    private func loadCondensedSnippet(
        for item: RepositoryFileItem,
        in repositoryPath: String,
        budget: PromptBudget
    ) -> String? {
        var parts: [String] = []

        if item.supportsStagedDiff,
           let stagedPatch = loadPatch(
               in: repositoryPath,
               arguments: ["diff", "--cached", "--no-ext-diff", "--no-color", "--unified=0", "--"] + item.indexSyncPaths
           ),
           let condensed = condensePatch(
               stagedPatch,
               maxHunks: budget.maxHunksPerPatch,
               maxChangedLinesPerHunk: budget.maxChangedLinesPerHunk,
               maxCharacters: budget.maxSnippetCharacters
           ) {
            parts.append("[已暂存]\n\(condensed)")
        }

        if item.isUntracked {
            if let untrackedPatch = loadUntrackedPatch(for: item, in: repositoryPath),
               let condensed = condensePatch(
                   untrackedPatch,
                   maxHunks: budget.maxHunksPerPatch,
                   maxChangedLinesPerHunk: budget.maxChangedLinesPerHunk,
                   maxCharacters: budget.maxSnippetCharacters
               ) {
                parts.append("[未暂存]\n\(condensed)")
            } else if let excerpt = readWorkingTreeExcerpt(for: item, in: repositoryPath) {
                parts.append("[未暂存]\n新增文件内容节选：\n\(excerpt)")
            }
        } else if item.supportsWorkingTreeDiff,
                  let workingTreePatch = loadPatch(
                      in: repositoryPath,
                      arguments: ["diff", "--no-ext-diff", "--no-color", "--unified=0", "--"] + item.indexSyncPaths
                  ),
                  let condensed = condensePatch(
                      workingTreePatch,
                      maxHunks: budget.maxHunksPerPatch,
                      maxChangedLinesPerHunk: budget.maxChangedLinesPerHunk,
                      maxCharacters: budget.maxSnippetCharacters
                  ) {
            parts.append("[未暂存]\n\(condensed)")
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n")
    }

    private func loadPatch(in repositoryPath: String, arguments: [String]) -> String? {
        guard let patch = try? runGit(in: repositoryPath, arguments: arguments) else {
            return nil
        }

        let trimmedPatch = patch.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPatch.isEmpty ? nil : trimmedPatch
    }

    private func loadUntrackedPatch(
        for item: RepositoryFileItem,
        in repositoryPath: String
    ) -> String? {
        let absolutePath = URL(fileURLWithPath: repositoryPath)
            .appendingPathComponent(item.path)
            .path

        return loadPatch(
            in: repositoryPath,
            arguments: [
                "diff",
                "--no-index",
                "--no-color",
                "--unified=0",
                "--",
                "/dev/null",
                absolutePath
            ]
        )
    }

    private func condensePatch(
        _ patch: String,
        maxHunks: Int = 2,
        maxChangedLinesPerHunk: Int = 16,
        maxCharacters: Int = 1_600
    ) -> String? {
        let lines = patch.components(separatedBy: .newlines)
        var keptLines: [String] = []
        var hunkCount = 0
        var changedLineCount = 0
        var currentHunkChangedLines = 0

        for line in lines {
            if line.hasPrefix("diff --git") || line.hasPrefix("rename from ") || line.hasPrefix("rename to ") {
                keptLines.append(line)
                continue
            }

            if line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode") || line.hasPrefix("Binary files") {
                keptLines.append(line)
                continue
            }

            if line.hasPrefix("@@") {
                guard hunkCount < maxHunks else { break }
                keptLines.append(line)
                hunkCount += 1
                currentHunkChangedLines = 0
                continue
            }

            if line.hasPrefix("+") || line.hasPrefix("-") {
                guard hunkCount > 0 else { continue }
                guard currentHunkChangedLines < maxChangedLinesPerHunk else { continue }

                keptLines.append(line)
                currentHunkChangedLines += 1
                changedLineCount += 1
            }
        }

        guard !keptLines.isEmpty else { return nil }

        var snippet = keptLines.joined(separator: "\n")
        if changedLineCount == 0 {
            snippet = keptLines.prefix(6).joined(separator: "\n")
        }

        if snippet.count > maxCharacters {
            let truncatedIndex = snippet.index(snippet.startIndex, offsetBy: maxCharacters)
            snippet = "\(snippet[..<truncatedIndex])\n...[片段已截断]"
        }

        return snippet
    }

    private func readWorkingTreeExcerpt(
        for item: RepositoryFileItem,
        in repositoryPath: String,
        maxLines: Int = 18,
        maxCharacters: Int = 700
    ) -> String? {
        guard item.kind == .file else { return nil }

        let fileURL = URL(fileURLWithPath: repositoryPath).appendingPathComponent(item.path)
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            return nil
        }

        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return nil
        }

        let excerpt = text
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(maxLines)
            .joined(separator: "\n")

        guard !excerpt.isEmpty else { return nil }

        if excerpt.count <= maxCharacters {
            return excerpt
        }

        let truncatedIndex = excerpt.index(excerpt.startIndex, offsetBy: maxCharacters)
        return "\(excerpt[..<truncatedIndex])\n...[内容已截断]"
    }

    private func extractSymbolHints(from snippet: String) -> [String] {
        var hints: [String] = []

        for rawLine in snippet.components(separatedBy: .newlines) {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmedLine.hasPrefix("@@"), let trailingContext = trimmedLine.split(separator: "@", maxSplits: 4, omittingEmptySubsequences: false).last {
                collectSymbolHints(from: String(trailingContext), into: &hints)
                continue
            }

            if trimmedLine.hasPrefix("+") || trimmedLine.hasPrefix("-") {
                collectSymbolHints(from: String(trimmedLine.dropFirst()), into: &hints)
                collectIdentifierHints(from: String(trimmedLine.dropFirst()), into: &hints)
            }
        }

        return Array(hints.prefix(5))
    }

    private func collectSymbolHints(from line: String, into hints: inout [String]) {
        let keywords = ["func ", "struct ", "class ", "enum ", "protocol ", "extension ", "var ", "let "]
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else { return }

        guard keywords.contains(where: trimmedLine.contains) else { return }

        let sanitized = trimmedLine
            .replacingOccurrences(of: "{", with: " ")
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ":", with: " ")
            .replacingOccurrences(of: "=", with: " ")

        let tokens = sanitized.split(separator: " ").map(String.init)
        guard let keywordIndex = tokens.firstIndex(where: { token in
            ["func", "struct", "class", "enum", "protocol", "extension", "var", "let"].contains(token)
        }), tokens.indices.contains(keywordIndex + 1) else {
            return
        }

        let symbol = tokens[keywordIndex + 1]
        guard symbol.count >= 2, !hints.contains(symbol) else { return }
        hints.append(symbol)
    }

    private func collectIdentifierHints(from line: String, into hints: inout [String]) {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else { return }

        let separators = CharacterSet.alphanumerics.inverted
        let tokens = trimmedLine
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }

        let stopWords: Set<String> = [
            "true", "false", "null", "self", "return", "guard", "else", "case",
            "func", "struct", "class", "enum", "protocol", "extension",
            "let", "var", "if", "for", "while", "switch", "break", "continue",
            "private", "fileprivate", "internal", "public", "open",
            "static", "final", "async", "await", "throws", "throw",
            "string", "int", "bool", "double", "float", "void", "nil",
            "test", "tests", "testing", "assert", "expect", "mock", "stub"
        ]

        for token in tokens {
            let lowercased = token.lowercased()
            guard token.count >= 4 else { continue }
            guard !stopWords.contains(lowercased) else { continue }
            guard token.first?.isLetter == true else { continue }
            guard token.contains(where: \.isUppercase) || token.contains("_") else { continue }
            guard !hints.contains(token) else { continue }

            hints.append(token)
            if hints.count >= 5 {
                return
            }
        }
    }

    private func moduleLabel(for path: String) -> String {
        let components = path.split(separator: "/").map(String.init)

        if components.contains("Services") {
            return "Services"
        }

        if components.contains("Stores") {
            return "Stores"
        }

        if components.contains("Domain") {
            return "Domain"
        }

        if components.contains("Views") {
            return "Views"
        }

        if components.contains("Resources") {
            return "Resources"
        }

        if components.contains("NeatGitApp") {
            return "App"
        }

        return "Workspace"
    }

    private func runGit(in repositoryPath: String, arguments: [String]) throws -> String {
        let result = try GitCommandRunner.run(in: repositoryPath, arguments: arguments)

        let allowedStatuses: Set<Int32> = [0]
        guard allowedStatuses.contains(result.terminationStatus) else {
            throw GitCommandError(
                message: GitCommandRunner.failureMessage(
                    from: result.outputData,
                    defaultMessage: "读取 Git diff 失败。"
                )
            )
        }

        return String(decoding: result.outputData, as: UTF8.self)
    }
}

struct FileMapInput: Sendable {
    let path: String
    let changeKind: ChangeKind
    let statusLabel: String
    let diffStat: DiffLineStat
    let snippet: String?
}
