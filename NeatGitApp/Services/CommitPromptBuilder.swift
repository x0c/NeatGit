import Foundation

enum CommitPromptBuilder {
    static func buildUserPrompt(
        with context: CommitAnalysisContext,
        featureFlags: CommitGenerationFeatureFlags = .default
    ) -> String {
        let budget = PromptBudget.forFileCount(context.committableItems.count)

        let displayedFileSummaries: ArraySlice<String>
        let omittedSummaryCount: Int
        let displayedPatches: ArraySlice<String>
        let omittedPatchCount: Int

        if featureFlags.useFileSelectionBudget {
            displayedFileSummaries = context.fileSummaries.prefix(budget.summaryLimit)
            omittedSummaryCount = max(0, context.fileSummaries.count - displayedFileSummaries.count)
            displayedPatches = context.patchSummaries.prefix(budget.patchDisplayLimit)
            omittedPatchCount = max(0, context.patchSummaries.count - displayedPatches.count)
        } else {
            displayedFileSummaries = context.fileSummaries[context.fileSummaries.indices]
            omittedSummaryCount = 0
            displayedPatches = context.patchSummaries[context.patchSummaries.indices]
            omittedPatchCount = 0
        }

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

        sections.append("请直接输出最终 JSON。")

        return sections.joined(separator: "\n\n")
    }

    static func buildRetryPrompt(reason: String, previousResponse: String) -> String {
        """
        上一轮结果不合格。
        原因：\(reason)
        上一轮原始输出：\(previousResponse)

        请重新判断主要改动，只输出更准确的最终 JSON。
        """
    }

    static func buildMapPhasePrompt(for fileInput: FileMapInput) -> String {
        var sections: [String] = [
            "文件：\(fileInput.path)",
            "状态：\(fileInput.statusLabel)",
            "类型：\(fileInput.changeKind.label)"
        ]

        if fileInput.diffStat.total > 0 {
            sections.append("变更行数：+\(fileInput.diffStat.added)/-\(fileInput.diffStat.deleted)")
        }

        if let snippet = fileInput.snippet, !snippet.isEmpty {
            sections.append(
                """
                代码变更：
                \(snippet)
                """
            )
        }

        sections.append(
            """
            请用 3-5 条要点概括该文件的核心变更。每条以 "- " 开头，使用祈使语气。
            只输出要点，不要输出其他内容。
            """
        )

        return sections.joined(separator: "\n\n")
    }

    static func buildReducePhasePrompt(
        repositoryName: String,
        fileSummaries: [String],
        changeOverview: String,
        moduleSummary: String
    ) -> String {
        var sections: [String] = [
            "仓库：\(repositoryName)",
            "改动概览：\(changeOverview)",
            "模块分布：\(moduleSummary)",
            "以下是对每个文件核心变更的独立分析："
        ]

        for summary in fileSummaries {
            sections.append(summary)
        }

        sections.append(
            """
            请基于以上各文件分析，生成一个统一的 commit message。
            请直接输出最终 JSON。
            """
        )

        return sections.joined(separator: "\n\n")
    }

    static let defaultSystemPrompt = """
    你是一个资深工程师，负责为 Git 改动生成 commit message。
    任务目标：
    - 只总结这次会真正提交的改动
    - 优先总结这次提交的主线变化
    - 如果存在多个并列的重要改动，subject 需要合并表达这些主线，不要只取其中一个局部改动
    - 不要罗列所有细节，但也不要为了简短而遗漏同等重要的主线变化
    - 不要编造 diff 中没有的改动、行为或原因

    输出规则：
    - 只输出一个 JSON 对象，不要输出 Markdown、代码块、解释或前后缀
    - JSON 格式固定为：
      {"type":"...", "scope":"...", "subject":"...", "body":["..."], "confidence":0.0, "reasons":["..."]}
    - type 取值范围：feat / fix / refactor / docs / chore / test / style / perf / build / ci，改动类型不明确时省略
    - scope 为可选的短模块名，无法确定时省略或设为 null
    - subject 必须单行、简体中文、准确、简洁，不超过 72 个字符
    - body 为 0-5 条要点，每条以祈使语气描述具体变更，不要写空泛描述
    - reasons 用来说明你判断 subject 的依据，保留 1 到 3 条短语即可
    - confidence 取 0 到 1 之间的小数，表示你对 subject 准确性的判断

    约束：
    - 使用祈使语气（如"添加功能"而非"添加了功能"）
    - 排除 import 排序、纯格式化、纯注释变更，除非它们是主要变更
    - 不要写"更新代码""优化逻辑""调整细节""处理问题"这类空泛表述
    - 如果同时存在代码改动与 Markdown / 文档 / 资源等非代码改动，subject 必须优先概括代码行为变化
    - 如果同时存在生产代码改动与测试改动，subject 必须优先概括生产代码的业务变化
    - 只有当本次主要改动本身就是文档或说明文字时，才把文档更新写成主体
    - 如果 diff 明确出现新增字段、入参、分支条件或核心服务逻辑，优先在 subject 中体现这些业务变化
    """

    static let mapPhaseSystemPrompt = """
    你是一个资深工程师，负责精确概括单个文件的 Git diff 核心变更。
    规则：
    - 只基于 diff 中可见的实际变更进行概括，不要编造
    - 用 3-5 条要点概括，每条以 "- " 开头
    - 使用祈使语气
    - 排除 import 排序、纯格式化、纯注释变更，除非它们是主要变更
    - 只输出要点列表，不要输出其他内容
    """

    static func moduleSummary(from analyses: [FileAnalysis]) -> String {
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

    static func changeOverview(from analyses: [FileAnalysis]) -> String {
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

    static func focusGuidance(from analyses: [FileAnalysis]) -> String {
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

    static func primarySignals(from analyses: [FileAnalysis]) -> [String] {
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

    static func expectedKeywords(from analyses: [FileAnalysis]) -> [String] {
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

    static func displayKeywords(from analyses: [FileAnalysis]) -> [String] {
        let values = prioritizedAnalysesForKeywords(from: analyses).prefix(5).flatMap { analysis in
            var keywords: [String] = [analysis.moduleLabel]
            keywords.append(fileStem(for: analysis.item.path))
            keywords.append(contentsOf: analysis.symbolHints)
            return keywords
        }

        var seen: Set<String> = []
        return values.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.count >= 2, seen.insert(normalized.lowercased()).inserted else {
                return nil
            }
            return normalized
        }
    }

    private static func prioritizedAnalysesForKeywords(from analyses: [FileAnalysis]) -> [FileAnalysis] {
        let productionCodeAnalyses = analyses.filter { $0.changeKind == .sourceCode }
        if !productionCodeAnalyses.isEmpty {
            return productionCodeAnalyses + analyses.filter { $0.changeKind != .sourceCode }
        }

        let testAnalyses = analyses.filter { $0.changeKind == .testCode }
        return testAnalyses.isEmpty ? analyses : testAnalyses + analyses.filter { $0.changeKind != .testCode }
    }

    private static func fileStem(for path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }
}
