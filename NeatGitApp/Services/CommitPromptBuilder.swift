import Foundation

enum CommitPromptBuilder {
    static func buildUserPrompt(with context: CommitAnalysisContext) -> String {
        let budget = PromptBudget.forFileCount(context.committableItems.count)
        let displayedFileSummaries = context.fileSummaries.prefix(budget.summaryLimit)
        let displayedPatches = context.patchSummaries.prefix(budget.detailedItemLimit)

        var sections: [String] = [
            "仓库：\(context.repository.name)",
            "本次会提交 \(context.committableItems.count) 个文件改动。"
        ]

        if context.excludedItemCount > 0 {
            sections.append("已排除 \(context.excludedItemCount) 个不参与默认 commit 的文件。")
        }

        sections.append("改动概览：\(context.changeOverview)")
        sections.append("模块分布：\(context.moduleSummary)")
        sections.append("生成侧重点：\(context.focusGuidance)")

        if !context.primarySignals.isEmpty {
            sections.append("高优先级业务线索：\(context.primarySignals.joined(separator: "，"))")
        }

        sections.append(
            """
            文件级摘要：
            \(displayedFileSummaries.joined(separator: "\n"))
            """
        )

        if !displayedPatches.isEmpty {
            sections.append(
                """
                代码变更片段：
                \(displayedPatches.joined(separator: "\n\n"))
                """
            )
        }

        sections.append("请直接输出最终 JSON。")
        return sections.joined(separator: "\n\n")
    }

    static let defaultSystemPrompt = """
    为 Git 改动生成 commit message。只总结 diff 中的实际改动，不要编造。
    输出纯 JSON，不要 Markdown/代码块/解释：{"type":"...","scope":"...","subject":"...","body":["..."],"confidence":0.0,"reasons":["..."]}
    type: feat/fix/refactor/docs/chore/test，不明确 null。scope: 短模块名，不明确 null。subject: 单行中文摘要，≤72字，祈使语气。body: 0-3要点。reasons: 1-2依据。confidence: 0-1。
    不要写"更新代码""优化逻辑"等空泛表述。排除 import 排序/纯格式化。
    """

    // MARK: - 上下文计算

    static func moduleSummary(from analyses: [FileAnalysis]) -> String {
        let grouped = Dictionary(grouping: analyses, by: \.moduleLabel)
            .map { (key: $0.key, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.key < $1.key }

        guard !grouped.isEmpty else { return "未识别模块" }
        return grouped.map { "\($0.key) \($0.count)" }.joined(separator: "，")
    }

    static func changeOverview(from analyses: [FileAnalysis]) -> String {
        let items = analyses.map(\.item)
        let added      = items.filter(\.isUntracked).count
        let deleted    = items.filter(\.isDeleted).count
        let renamed    = items.filter { $0.previousPath != nil }.count
        let codeCount  = analyses.filter { $0.changeKind == .sourceCode }.count
        let testCount  = analyses.filter { $0.changeKind == .testCode }.count
        let docCount   = analyses.filter { $0.changeKind == .documentation }.count
        let auxCount   = analyses.filter { $0.changeKind != .sourceCode && $0.changeKind != .testCode }.count

        var parts = ["共 \(items.count) 个文件"]
        if added > 0   { parts.append("新增 \(added)") }
        if deleted > 0 { parts.append("删除 \(deleted)") }
        if renamed > 0 { parts.append("重命名 \(renamed)") }
        if codeCount > 0 { parts.append("代码 \(codeCount)") }
        if testCount > 0 { parts.append("测试 \(testCount)") }
        if docCount > 0  { parts.append("文档 \(docCount)") }
        if auxCount > docCount { parts.append("其他辅助改动 \(auxCount - docCount)") }
        return parts.joined(separator: "，")
    }

    static func focusGuidance(from analyses: [FileAnalysis]) -> String {
        let codeCount   = analyses.filter { $0.changeKind == .sourceCode }.count
        let testCount   = analyses.filter { $0.changeKind == .testCode }.count
        let docCount    = analyses.filter { $0.changeKind == .documentation }.count
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
        let prioritized = prioritizedAnalyses(from: analyses)
        let values = prioritized.prefix(4).flatMap { analysis -> [String] in
            var signals = analysis.symbolHints
            if analysis.changeKind == .sourceCode {
                signals.insert(fileStem(for: analysis.item.path), at: 0)
            }
            return signals
        }

        var seen: Set<String> = []
        return values.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.count >= 3, seen.insert(normalized.lowercased()).inserted else { return nil }
            return normalized
        }
    }

    // MARK: - 私有

    private static func prioritizedAnalyses(from analyses: [FileAnalysis]) -> [FileAnalysis] {
        let code = analyses.filter { $0.changeKind == .sourceCode }
        if !code.isEmpty { return code + analyses.filter { $0.changeKind != .sourceCode } }
        let tests = analyses.filter { $0.changeKind == .testCode }
        return tests.isEmpty ? analyses : tests + analyses.filter { $0.changeKind != .testCode }
    }

    private static func fileStem(for path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }
}
