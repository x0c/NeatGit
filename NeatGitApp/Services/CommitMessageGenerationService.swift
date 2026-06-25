import Foundation

final class CommitMessageGenerationService: @unchecked Sendable {
    private let llmService: LLMChatService
    private let diffAnalyzer: CommitDiffAnalyzer
    private let debugStore: AICommitDebugStore?
    private let strategyThreshold: CommitGenerationStrategyThreshold
    private let featureFlags: CommitGenerationFeatureFlags

    init(
        llmService: LLMChatService = LLMChatService(),
        diffAnalyzer: CommitDiffAnalyzer = CommitDiffAnalyzer(),
        debugStore: AICommitDebugStore? = nil,
        strategyThreshold: CommitGenerationStrategyThreshold = .default,
        featureFlags: CommitGenerationFeatureFlags = .default
    ) {
        self.llmService = llmService
        self.diffAnalyzer = diffAnalyzer
        self.debugStore = debugStore
        self.strategyThreshold = strategyThreshold
        self.featureFlags = featureFlags
    }

    func generateMessage(
        for repository: GitRepository,
        changedItems: [RepositoryFileItem],
        configuration: LLMProviderConfiguration,
        systemPrompt: String
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) { [self] in
            let sessionID = UUID()
            let context = try diffAnalyzer.analyze(for: repository, changedItems: changedItems, featureFlags: featureFlags)

            let strategy = resolveStrategy(
                fileCount: context.committableItems.count,
                totalDiffLines: context.totalDiffLines
            )

            await beginDebugSession(
                id: sessionID,
                repository: repository,
                changedItemCount: changedItems.count,
                context: context,
                configuration: configuration,
                strategy: strategy
            )

            do {
                let message: String
                switch strategy {
                case .singlePass:
                    message = try await singlePassGenerate(
                        context: context,
                        configuration: configuration,
                        systemPrompt: systemPrompt,
                        sessionID: sessionID
                    )
                case .twoStepMapReduce:
                    message = try await mapReduceGenerate(
                        repository: repository,
                        changedItems: changedItems,
                        context: context,
                        configuration: configuration,
                        systemPrompt: systemPrompt,
                        sessionID: sessionID
                    )
                }

                await finishDebugSession(id: sessionID, finalMessage: message)
                return message
            } catch {
                await failDebugSession(id: sessionID, error: error)
                throw error
            }
        }.value
    }

    private func resolveStrategy(fileCount: Int, totalDiffLines: Int) -> CommitGenerationStrategy {
        strategyThreshold.shouldUseMapReduce(fileCount: fileCount, totalDiffLines: totalDiffLines)
            ? .twoStepMapReduce
            : .singlePass
    }

    private func singlePassGenerate(
        context: CommitAnalysisContext,
        configuration: LLMProviderConfiguration,
        systemPrompt: String,
        sessionID: UUID
    ) async throws -> String {
        let userPrompt = CommitPromptBuilder.buildUserPrompt(with: context, featureFlags: featureFlags)
        let response = try await requestLLM(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            configuration: configuration,
            sessionID: sessionID,
            attemptTitle: "单次调用"
        )

        return normalizeGeneratedMessage(response)
    }

    private func mapReduceGenerate(
        repository: GitRepository,
        changedItems: [RepositoryFileItem],
        context: CommitAnalysisContext,
        configuration: LLMProviderConfiguration,
        systemPrompt: String,
        sessionID: UUID
    ) async throws -> String {
        let fileInputs = try diffAnalyzer.fileSummariesForMapReduce(
            for: repository,
            changedItems: changedItems
        )

        let fileSummaries = await mapPhase(
            fileInputs: fileInputs,
            configuration: configuration,
            sessionID: sessionID
        )

        guard !fileSummaries.isEmpty else {
            return try await singlePassGenerate(
                context: context,
                configuration: configuration,
                systemPrompt: systemPrompt,
                sessionID: sessionID
            )
        }

        let changeOverview = CommitPromptBuilder.changeOverview(
            from: fileInputs.map {
                FileAnalysis(
                    item: dummyItem(from: $0),
                    changeKind: $0.changeKind,
                    moduleLabel: "Workspace",
                    diffStat: $0.diffStat,
                    snippet: nil,
                    symbolHints: [],
                    featureFlags: featureFlags
                )
            }
        )

        let moduleGroups = Dictionary(grouping: fileInputs, by: { pathModuleLabel($0.path) })
        let moduleSummary = moduleGroups
            .map { "\($0.key) \($0.value.count)" }
            .sorted { $0 > $1 }
            .joined(separator: "，")

        let reducePrompt = CommitPromptBuilder.buildReducePhasePrompt(
            repositoryName: repository.name,
            fileSummaries: fileSummaries,
            changeOverview: changeOverview,
            moduleSummary: moduleSummary
        )

        let response = try await requestLLM(
            systemPrompt: systemPrompt,
            userPrompt: reducePrompt,
            configuration: configuration,
            sessionID: sessionID,
            attemptTitle: "汇总阶段（Reduce）"
        )

        return normalizeGeneratedMessage(response)
    }

    private func mapPhase(
        fileInputs: [FileMapInput],
        configuration: LLMProviderConfiguration,
        sessionID: UUID
    ) async -> [String] {
        await withTaskGroup(of: String?.self) { group in
            for fileInput in fileInputs {
                group.addTask { [self] in
                    let userPrompt = CommitPromptBuilder.buildMapPhasePrompt(for: fileInput)

                    do {
                        let result = try await llmService.complete(
                            messages: [
                                .init(role: "system", content: CommitPromptBuilder.mapPhaseSystemPrompt),
                                .init(role: "user", content: userPrompt)
                            ],
                            configuration: configuration,
                            temperature: 0.1,
                            maxTokens: 150
                        )

                        await self.recordDebugAttempt(
                            sessionID: sessionID,
                            title: "文件分析（Map）：\(fileInput.path)",
                            systemPrompt: CommitPromptBuilder.mapPhaseSystemPrompt,
                            userPrompt: userPrompt,
                            rawResponse: result.content,
                            errorMessage: nil
                        )

                        return "[\(fileInput.path)]\n\(result.content)"
                    } catch {
                        await self.recordDebugAttempt(
                            sessionID: sessionID,
                            title: "文件分析（Map）：\(fileInput.path)",
                            systemPrompt: CommitPromptBuilder.mapPhaseSystemPrompt,
                            userPrompt: userPrompt,
                            rawResponse: nil,
                            errorMessage: GitCommandError.describe(error)
                        )
                        return nil
                    }
                }
            }

            var summaries: [String] = []
            for await result in group {
                if let summary = result {
                    summaries.append(summary)
                }
            }
            return summaries
        }
    }

    private func requestLLM(
        systemPrompt: String,
        userPrompt: String,
        configuration: LLMProviderConfiguration,
        sessionID: UUID,
        attemptTitle: String
    ) async throws -> String {
        do {
            let result = try await llmService.complete(
                messages: [
                    .init(role: "system", content: systemPrompt),
                    .init(role: "user", content: userPrompt)
                ],
                configuration: configuration,
                responseFormat: .jsonObject
            )

            await recordDebugAttempt(
                sessionID: sessionID,
                title: attemptTitle,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                rawResponse: result.content,
                errorMessage: nil
            )

            return result.content
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

    private func normalizeGeneratedMessage(_ response: String) -> String {
        if let candidate = CommitMessageCandidate.decode(from: response) {
            let composed = candidate.composedMessage
            return composed.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let trimmedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResponse.isEmpty else { return "" }

        let firstLine = trimmedResponse
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'` ").union(.whitespacesAndNewlines))
            ?? ""

        return firstLine
    }

    private func beginDebugSession(
        id: UUID,
        repository: GitRepository,
        changedItemCount: Int,
        context: CommitAnalysisContext,
        configuration: LLMProviderConfiguration,
        strategy: CommitGenerationStrategy
    ) async {
        guard let debugStore else { return }

        await MainActor.run {
            debugStore.beginSession(
                id: id,
                repositoryName: repository.name,
                changedFileCount: changedItemCount,
                committableFileCount: context.committableItems.count,
                configuration: configuration,
                strategy: strategy
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

    private func pathModuleLabel(_ path: String) -> String {
        let components = path.split(separator: "/").map(String.init)
        if components.contains("Services") { return "Services" }
        if components.contains("Stores") { return "Stores" }
        if components.contains("Domain") { return "Domain" }
        if components.contains("Views") { return "Views" }
        if components.contains("Resources") { return "Resources" }
        if components.contains("NeatGitApp") { return "App" }
        return "Workspace"
    }

    private func dummyItem(from input: FileMapInput) -> RepositoryFileItem {
        RepositoryFileItem(
            section: .changed,
            path: input.path,
            kind: .file,
            state: .changed(input.statusLabel),
            gitStatusCode: nil,
            previousPath: nil
        )
    }
}
