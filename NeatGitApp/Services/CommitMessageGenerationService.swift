import Foundation

struct LLMProviderConfiguration: Sendable {
    let baseURL: URL
    let apiKey: String
    let model: String
}

final class CommitMessageGenerationService: @unchecked Sendable {
    private enum PromptMode: Sendable {
        case initial
        case retry(reason: String, previousResponse: String)
    }

    private enum ChangeKind: Sendable {
        case sourceCode
        case testCode
        case configuration
        case documentation
        case resource
        case other

        var label: String {
            switch self {
            case .sourceCode:
                return "代码"
            case .testCode:
                return "测试"
            case .configuration:
                return "配置"
            case .documentation:
                return "文档"
            case .resource:
                return "资源"
            case .other:
                return "其他"
            }
        }

        var analysisWeight: Int {
            switch self {
            case .sourceCode:
                return 48
            case .testCode:
                return -22
            case .configuration:
                return 18
            case .documentation:
                return -36
            case .resource:
                return -18
            case .other:
                return 0
            }
        }

        var detailWeight: Int {
            switch self {
            case .sourceCode:
                return 40
            case .testCode:
                return -18
            case .configuration:
                return 14
            case .documentation:
                return -32
            case .resource:
                return -14
            case .other:
                return 0
            }
        }
    }

    private struct CommitMessageAnalysisContext: Sendable {
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
    }

    private struct FileAnalysis: Sendable {
        let item: RepositoryFileItem
        let changeKind: ChangeKind
        let moduleLabel: String
        let diffStat: DiffLineStat
        let snippet: String?
        let symbolHints: [String]

        var score: Int {
            let symbolScore = symbolHints.count * 8
            let snippetScore = snippet == nil ? 0 : 24
            let statScore = min(diffStat.total, 180)
            return statScore + moduleWeight + statusWeight + symbolScore + snippetScore + changeKind.analysisWeight
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

    private struct DiffLineStat: Sendable {
        var added: Int = 0
        var deleted: Int = 0

        var total: Int {
            added + deleted
        }

        mutating func merge(_ other: DiffLineStat) {
            added += other.added
            deleted += other.deleted
        }
    }

    private struct PromptBudget: Sendable {
        let summaryLimit: Int
        let detailedItemLimit: Int
        let patchDisplayLimit: Int
        let maxHunksPerPatch: Int
        let maxChangedLinesPerHunk: Int
        let maxSnippetCharacters: Int
    }

    private struct GeneratedCommitCandidate: Decodable, Sendable {
        let subject: String
        let confidence: Double?
        let reasons: [String]?
    }

    private let llmService: OpenAICompatibleChatService
    private let debugStore: AICommitDebugStore?

    init(
        llmService: OpenAICompatibleChatService = OpenAICompatibleChatService(),
        debugStore: AICommitDebugStore? = nil
    ) {
        self.llmService = llmService
        self.debugStore = debugStore
    }

    func generateMessage(
        for repository: GitRepository,
        changedItems: [RepositoryFileItem],
        configuration: LLMProviderConfiguration,
        systemPrompt: String
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) { [self] in
            let sessionID = UUID()
            let context = try makeAnalysisContext(for: repository, changedItems: changedItems)

            await beginDebugSession(
                id: sessionID,
                repository: repository,
                changedItemCount: changedItems.count,
                context: context,
                configuration: configuration
            )

            do {
                let response = try await requestCandidate(
                    with: context,
                    configuration: configuration,
                    mode: .initial,
                    systemPrompt: systemPrompt,
                    sessionID: sessionID
                )

                let message: String
                if let candidate = decodeCandidate(from: response) {
                    message = normalizeGeneratedMessage(candidate.subject)
                } else {
                    message = normalizeGeneratedMessage(response)
                }

                await finishDebugSession(id: sessionID, finalMessage: message)
                return message
            } catch {
                await failDebugSession(id: sessionID, error: error)
                throw error
            }
        }.value
    }

    private func requestCandidate(
        with context: CommitMessageAnalysisContext,
        configuration: LLMProviderConfiguration,
        mode: PromptMode,
        systemPrompt: String,
        sessionID: UUID
    ) async throws -> String {
        let userPrompt = makePrompt(with: context, mode: mode)
        let attemptTitle = title(for: mode)

        do {
            let response = try await llmService.complete(
                messages: [
                    .init(role: "system", content: systemPrompt),
                    .init(role: "user", content: userPrompt)
                ],
                configuration: configuration
            )

            await recordDebugAttempt(
                sessionID: sessionID,
                title: attemptTitle,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                rawResponse: response,
                errorMessage: nil
            )

            return response
        } catch {
            await recordDebugAttempt(
                sessionID: sessionID,
                title: attemptTitle,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                rawResponse: nil,
                errorMessage: GitCommandError.describe(error)
            )
            throw error
        }
    }

    private func title(for mode: PromptMode) -> String {
        switch mode {
        case .initial:
            return "第 1 轮请求"
        case .retry:
            return "第 2 轮请求（重试）"
        }
    }

    private func beginDebugSession(
        id: UUID,
        repository: GitRepository,
        changedItemCount: Int,
        context: CommitMessageAnalysisContext,
        configuration: LLMProviderConfiguration
    ) async {
        guard let debugStore else { return }

        await MainActor.run {
            debugStore.beginSession(
                id: id,
                repositoryName: repository.name,
                changedFileCount: changedItemCount,
                committableFileCount: context.committableItems.count,
                configuration: configuration
            )
        }
    }

    private func recordDebugAttempt(
        sessionID: UUID,
        title: String,
        systemPrompt: String,
        userPrompt: String,
        rawResponse: String?,
        errorMessage: String?
    ) async {
        guard let debugStore else { return }

        await MainActor.run {
            debugStore.recordAttempt(
                sessionID: sessionID,
                title: title,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                rawResponse: rawResponse,
                errorMessage: errorMessage
            )
        }
    }

    private func finishDebugSession(id: UUID, finalMessage: String) async {
        guard let debugStore else { return }

        await MainActor.run {
            debugStore.completeSession(sessionID: id, finalMessage: finalMessage)
        }
    }

    private func failDebugSession(id: UUID, error: Error) async {
        guard let debugStore else { return }

        await MainActor.run {
            debugStore.failSession(
                sessionID: id,
                errorMessage: GitCommandError.describe(error)
            )
        }
    }

    private func makePrompt(
        with context: CommitMessageAnalysisContext,
        mode: PromptMode
    ) -> String {
        let budget = promptBudget(for: context.committableItems.count)

        let displayedFileSummaries = context.fileSummaries.prefix(budget.summaryLimit)
        let omittedSummaryCount = max(0, context.fileSummaries.count - displayedFileSummaries.count)
        let displayedPatches = context.patchSummaries.prefix(budget.patchDisplayLimit)
        let omittedPatchCount = max(0, context.patchSummaries.count - displayedPatches.count)

        var sections: [String] = [
            "仓库：\(context.repository.name)",
            "本次实际会提交 \(context.committableItems.count) 个文件改动。",
            "改动概览：\(context.changeOverview)",
            "模块分布：\(context.moduleSummary)",
            "生成侧重点：\(context.focusGuidance)"
        ]

        if context.excludedItemCount > 0 {
            sections.append("已排除 \(context.excludedItemCount) 个不参与默认 commit 的文件，例如冲突文件或 .gitignore。")
        }

        if !context.primarySignals.isEmpty {
            sections.append("高优先级业务线索：\(context.primarySignals.joined(separator: "，"))")
        }

        sections.append(
            """
            文件级摘要：
            \(displayedFileSummaries.joined(separator: "\n"))
            """
        )

        if omittedSummaryCount > 0 {
            sections.append("还有 \(omittedSummaryCount) 个文件未展开，生成时请优先概括主变更。")
        }

        if !displayedPatches.isEmpty {
            sections.append(
                """
                关键代码变更片段：
                \(displayedPatches.joined(separator: "\n\n"))
                """
            )
        }

        if omittedPatchCount > 0 {
            sections.append("其余文件未附 patch，避免上下文过大。")
        }

        switch mode {
        case .initial:
            sections.append("请直接输出最终 JSON。")
        case let .retry(reason, previousResponse):
            sections.append(
                """
                上一轮结果不合格。
                原因：\(reason)
                上一轮原始输出：\(previousResponse)

                请重新判断主要改动，只输出更准确的最终 JSON。
                """
            )
        }

        return sections.joined(separator: "\n\n")
    }

    private func makeAnalysisContext(
        for repository: GitRepository,
        changedItems: [RepositoryFileItem]
    ) throws -> CommitMessageAnalysisContext {
        let committableItems = changedItems.filter { item in
            item.isCheckableForCommit && !shouldExcludeFromDefaultCommit(item)
        }

        guard !committableItems.isEmpty else {
            throw GitCommandError(message: "当前没有可供 AI 分析的可提交文件变更。")
        }

        let budget = promptBudget(for: committableItems.count)

        let stagedStats = loadDiffStats(in: repository.path, items: committableItems, cached: true)
        let unstagedStats = loadDiffStats(in: repository.path, items: committableItems, cached: false)

        let topDetailedItems = selectDetailedItems(
            from: committableItems,
            stagedStats: stagedStats,
            unstagedStats: unstagedStats,
            limit: budget.detailedItemLimit
        )
        let detailedItemIDs = Set(topDetailedItems.map(\.id))

        let analyses = committableItems.map { item in
            var diffStat = diffStat(for: item, stagedStats: stagedStats, unstagedStats: unstagedStats)
            var snippet: String?
            var symbolHints: [String] = []
            let changeKind = classifyChangeKind(for: item.path)

            if detailedItemIDs.contains(item.id) {
                snippet = loadCondensedSnippet(for: item, in: repository.path, budget: budget)
                symbolHints = snippet.map(extractSymbolHints(from:)) ?? []

                if diffStat.total == 0, let snippet {
                    diffStat = diffStatFromPatch(snippet)
                }
            }

            return FileAnalysis(
                item: item,
                changeKind: changeKind,
                moduleLabel: moduleLabel(for: item.path),
                diffStat: diffStat,
                snippet: snippet,
                symbolHints: symbolHints
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

        return CommitMessageAnalysisContext(
            repository: repository,
            committableItems: committableItems,
            excludedItemCount: changedItems.count - committableItems.count,
            fileSummaries: analyses.map(\.summaryLine),
            patchSummaries: patchSummaries,
            moduleSummary: moduleSummary(from: analyses),
            changeOverview: changeOverview(from: analyses),
            focusGuidance: focusGuidance(from: analyses),
            primarySignals: primarySignals(from: analyses),
            hasProductionCodeChanges: analyses.contains { $0.changeKind == .sourceCode },
            hasTestChanges: analyses.contains { $0.changeKind == .testCode },
            expectedKeywords: expectedKeywords(from: analyses),
            displayKeywords: displayKeywords(from: analyses)
        )
    }

    private func selectDetailedItems(
        from items: [RepositoryFileItem],
        stagedStats: [String: DiffLineStat],
        unstagedStats: [String: DiffLineStat],
        limit: Int
    ) -> [RepositoryFileItem] {
        items.sorted { lhs, rhs in
            let lhsScore = rankingScore(for: lhs, stagedStats: stagedStats, unstagedStats: unstagedStats)
            let rhsScore = rankingScore(for: rhs, stagedStats: stagedStats, unstagedStats: unstagedStats)

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
        unstagedStats: [String: DiffLineStat]
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

        score += classifyChangeKind(for: item.path).detailWeight

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

        return score
    }

    private func promptBudget(for fileCount: Int) -> PromptBudget {
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

        return parseNumstatOutput(output)
    }

    private func parseNumstatOutput(_ output: String) -> [String: DiffLineStat] {
        var statsByPath: [String: DiffLineStat] = [:]

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = rawLine.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }

            guard let added = Int(fields[0]), let deleted = Int(fields[1]) else {
                continue
            }

            let path = fields[2...].joined(separator: "\t")
            var existing = statsByPath[path] ?? DiffLineStat()
            existing.added += added
            existing.deleted += deleted
            statsByPath[path] = existing
        }

        return statsByPath
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

    private func diffStatFromPatch(_ patch: String) -> DiffLineStat {
        var stat = DiffLineStat()

        for line in patch.components(separatedBy: .newlines) {
            if line.hasPrefix("+++") || line.hasPrefix("---") {
                continue
            }

            if line.hasPrefix("+") {
                stat.added += 1
            } else if line.hasPrefix("-") {
                stat.deleted += 1
            }
        }

        return stat
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

    private func moduleSummary(from analyses: [FileAnalysis]) -> String {
        let grouped = Dictionary(grouping: analyses, by: \.moduleLabel)
            .map { key, value in
                (key: key, count: value.count)
            }
            .sorted {
                if $0.count == $1.count {
                    return $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
                }

                return $0.count > $1.count
            }

        guard !grouped.isEmpty else {
            return "未识别模块"
        }

        return grouped
            .map { "\($0.key) \($0.count)" }
            .joined(separator: "，")
    }

    private func changeOverview(from analyses: [FileAnalysis]) -> String {
        let items = analyses.map(\.item)
        let added = items.filter(\.isUntracked).count
        let deleted = items.filter(\.isDeleted).count
        let renamed = items.filter { $0.previousPath != nil }.count
        let staged = items.filter(\.isStaged).count
        let unstaged = items.filter(\.hasUnstagedChanges).count
        let codeCount = analyses.filter { $0.changeKind == .sourceCode }.count
        let testCount = analyses.filter { $0.changeKind == .testCode }.count
        let docCount = analyses.filter { $0.changeKind == .documentation }.count
        let auxiliaryCount = analyses.filter {
            $0.changeKind != .sourceCode && $0.changeKind != .testCode
        }.count

        var parts: [String] = ["共 \(items.count) 个文件"]

        if added > 0 {
            parts.append("新增 \(added)")
        }

        if deleted > 0 {
            parts.append("删除 \(deleted)")
        }

        if renamed > 0 {
            parts.append("重命名 \(renamed)")
        }

        if staged > 0 {
            parts.append("含已暂存 \(staged)")
        }

        if unstaged > 0 {
            parts.append("含未暂存 \(unstaged)")
        }

        if codeCount > 0 {
            parts.append("代码 \(codeCount)")
        }

        if testCount > 0 {
            parts.append("测试 \(testCount)")
        }

        if docCount > 0 {
            parts.append("文档 \(docCount)")
        }

        if auxiliaryCount > docCount {
            parts.append("其他辅助改动 \(auxiliaryCount - docCount)")
        }

        return parts.joined(separator: "，")
    }

    private func focusGuidance(from analyses: [FileAnalysis]) -> String {
        let codeCount = analyses.filter { $0.changeKind == .sourceCode }.count
        let testCount = analyses.filter { $0.changeKind == .testCode }.count
        let docCount = analyses.filter { $0.changeKind == .documentation }.count
        let resourceCount = analyses.filter { $0.changeKind == .resource }.count
        let configCount = analyses.filter { $0.changeKind == .configuration }.count

        if codeCount > 0 && testCount > 0 {
            return "以生产代码的业务变化为主，测试文件视为验证或适配，不要把测试调整写成提交主体。"
        }

        if codeCount > 0 && (docCount > 0 || resourceCount > 0) {
            return "以代码行为变化为主，Markdown / 文档 / 资源改动降权处理，仅在确有必要时顺带提及。"
        }

        if codeCount > 0 && configCount > 0 {
            return "以代码改动为主，配置调整仅作为辅助背景。"
        }

        if docCount > 0 && codeCount == 0 {
            return "本次主要是文档改动，可以直接归纳为 docs 类提交。"
        }

        if resourceCount > 0 && codeCount == 0 && docCount == 0 {
            return "本次主要是资源或界面素材调整，避免误写成代码功能改动。"
        }

        if configCount > 0 && codeCount == 0 {
            return "本次主要是配置调整，优先概括配置层面的变化。"
        }

        return "优先总结最影响行为和结构的改动。"
    }

    private func primarySignals(from analyses: [FileAnalysis]) -> [String] {
        let prioritized = prioritizedAnalysesForKeywords(from: analyses)
        let values = prioritized.prefix(4).flatMap { analysis in
            var signals = analysis.symbolHints

            if analysis.changeKind == .sourceCode {
                signals.insert(fileStem(for: analysis.item.path), at: 0)
            }

            return signals
        }

        var seen: Set<String> = []
        return values.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.count >= 3, seen.insert(normalized.lowercased()).inserted else {
                return nil
            }
            return normalized
        }
    }

    private func expectedKeywords(from analyses: [FileAnalysis]) -> [String] {
        let keywords = prioritizedAnalysesForKeywords(from: analyses).prefix(6).flatMap { analysis in
            var values: [String] = [analysis.moduleLabel.lowercased()]
            values.append(fileStem(for: analysis.item.path).lowercased())
            values.append(contentsOf: analysis.symbolHints.map { $0.lowercased() })
            return values
        }

        var seen: Set<String> = []
        return keywords.compactMap { keyword in
            let normalized = keyword.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard normalized.count >= 3, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private func displayKeywords(from analyses: [FileAnalysis]) -> [String] {
        let values = prioritizedAnalysesForKeywords(from: analyses).prefix(5).flatMap { analysis in
            var keywords: [String] = [analysis.moduleLabel]
            keywords.append(fileStem(for: analysis.item.path))
            keywords.append(contentsOf: analysis.symbolHints)
            return keywords
        }

        var seen: Set<String> = []
        return values.compactMap { value in
            let normalized = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard normalized.count >= 2, seen.insert(normalized.lowercased()).inserted else {
                return nil
            }
            return normalized
        }
    }

    private func prioritizedAnalysesForKeywords(from analyses: [FileAnalysis]) -> [FileAnalysis] {
        let productionCodeAnalyses = analyses.filter { $0.changeKind == .sourceCode }
        if !productionCodeAnalyses.isEmpty {
            return productionCodeAnalyses + analyses.filter { $0.changeKind != .sourceCode }
        }

        let testAnalyses = analyses.filter { $0.changeKind == .testCode }
        return testAnalyses.isEmpty ? analyses : testAnalyses + analyses.filter { $0.changeKind != .testCode }
    }

    private func fileStem(for path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    private func classifyChangeKind(for path: String) -> ChangeKind {
        let fileURL = URL(fileURLWithPath: path)
        let normalizedPath = path.lowercased()
        let fileName = fileURL.lastPathComponent.lowercased()
        let fileExtension = fileURL.pathExtension.lowercased()

        if isTestLikePath(normalizedPath, fileName: fileName) {
            return .testCode
        }

        if [
            "swift", "m", "mm", "h", "c", "cc", "cpp", "cxx",
            "js", "jsx", "ts", "tsx",
            "py", "rb", "php", "java", "kt", "kts",
            "go", "rs", "scala", "sql", "sh", "zsh", "bash"
        ].contains(fileExtension) {
            return .sourceCode
        }

        if ["md", "markdown", "rst", "adoc", "txt"].contains(fileExtension) {
            return .documentation
        }

        if [
            "json", "yml", "yaml", "toml", "plist", "xcconfig",
            "pbxproj", "xcscheme", "entitlements", "strings"
        ].contains(fileExtension) || fileName == "project.yml" {
            return .configuration
        }

        if [
            "png", "jpg", "jpeg", "gif", "svg", "pdf",
            "ttf", "otf", "html", "css"
        ].contains(fileExtension) || normalizedPath.contains("/resources/") || normalizedPath.contains("/assets/") {
            return .resource
        }

        return .other
    }

    private func isTestLikePath(_ normalizedPath: String, fileName: String) -> Bool {
        if normalizedPath.contains("/tests/") || normalizedPath.contains("/test/") || normalizedPath.contains("/spec/") || normalizedPath.contains("/__tests__/") {
            return true
        }

        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent.lowercased()
        return stem.hasSuffix("tests") || stem.hasSuffix("test") || stem.hasSuffix("spec")
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

    private func shouldExcludeFromDefaultCommit(_ item: RepositoryFileItem) -> Bool {
        let fileName = (item.path as NSString).lastPathComponent
        return fileName == ".gitignore"
    }

    private func decodeCandidate(from response: String) -> GeneratedCommitCandidate? {
        let trimmedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResponse.isEmpty else { return nil }

        let candidateStrings = [
            trimmedResponse,
            extractJSONObject(from: trimmedResponse)
        ]
        .compactMap { $0 }

        let decoder = JSONDecoder()

        for candidateString in candidateStrings {
            guard let data = candidateString.data(using: .utf8) else { continue }
            if let candidate = try? decoder.decode(GeneratedCommitCandidate.self, from: data) {
                return candidate
            }
        }

        return nil
    }

    private func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
            return nil
        }

        guard start <= end else { return nil }
        return String(text[start...end])
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

    private func normalizeGeneratedMessage(_ message: String) -> String {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return "" }

        let firstLine = trimmedMessage
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'` ").union(.whitespacesAndNewlines))
            ?? ""

        return firstLine
    }
}

final class OpenAICompatibleChatService: @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func complete(
        messages: [OpenAIChatMessage],
        configuration: LLMProviderConfiguration
    ) async throws -> String {
        let endpoint = try makeEndpoint(from: configuration.baseURL)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 45
        request.httpBody = try JSONEncoder().encode(
            OpenAIChatCompletionRequest(
                model: configuration.model,
                messages: messages,
                temperature: 0.1,
                maxTokens: 220
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitCommandError(message: "AI 服务返回了无法识别的响应。")
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let serviceError = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data)
            let message = serviceError?.error.message
                ?? String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitCommandError(
                message: message.isEmpty ? "AI 服务请求失败（HTTP \(httpResponse.statusCode)）。" : message
            )
        }

        let completion = try JSONDecoder().decode(OpenAIChatCompletionResponse.self, from: data)
        guard let content = completion.choices.first?.message.content else {
            throw GitCommandError(message: "AI 服务没有返回可用内容。")
        }

        return content
    }

    private func makeEndpoint(from baseURL: URL) throws -> URL {
        guard !baseURL.absoluteString.isEmpty else {
            throw GitCommandError(message: "AI 服务 Base URL 不能为空。")
        }

        if baseURL.path.hasSuffix("/chat/completions") {
            return baseURL
        }

        return baseURL
            .appendingPathComponent("chat", isDirectory: false)
            .appendingPathComponent("completions", isDirectory: false)
    }
}

struct OpenAIChatMessage: Codable, Sendable {
    let role: String
    let content: String
}

private struct OpenAIChatCompletionRequest: Encodable, Sendable {
    let model: String
    let messages: [OpenAIChatMessage]
    let temperature: Double
    let maxTokens: Int

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
    }
}

private struct OpenAIChatCompletionResponse: Decodable, Sendable {
    let choices: [Choice]

    struct Choice: Decodable, Sendable {
        let message: OpenAIChatMessage
    }
}

private struct OpenAIErrorEnvelope: Decodable, Sendable {
    let error: OpenAIErrorBody
}

private struct OpenAIErrorBody: Decodable, Sendable {
    let message: String
}
