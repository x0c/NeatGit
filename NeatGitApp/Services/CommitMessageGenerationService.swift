import Foundation
import os

final class CommitMessageGenerationService: @unchecked Sendable {
    private let llmService: LLMChatService
    private let diffAnalyzer: CommitDiffAnalyzer
    private let debugStore: AICommitDebugStore?
    private static let logger = Logger(subsystem: "io.github.x0c.neatgit", category: "CommitGeneration")

    init(
        llmService: LLMChatService = LLMChatService(),
        diffAnalyzer: CommitDiffAnalyzer = CommitDiffAnalyzer(),
        debugStore: AICommitDebugStore? = nil
    ) {
        self.llmService = llmService
        self.diffAnalyzer = diffAnalyzer
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
            Self.logger.info("开始分析 diff，文件数=\(changedItems.count)")
            let context = try diffAnalyzer.analyze(for: repository, changedItems: changedItems)
            Self.logger.info("分析完成，committable=\(context.committableItems.count)，diffLines=\(context.totalDiffLines)")

            await beginDebugSession(
                id: sessionID,
                repository: repository,
                changedItemCount: changedItems.count,
                context: context,
                configuration: configuration
            )

            do {
                let userPrompt = CommitPromptBuilder.buildUserPrompt(with: context)
                Self.logger.info("userPrompt 长度=\(userPrompt.count)")

                let response = try await requestLLM(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    configuration: configuration,
                    sessionID: sessionID,
                    attemptTitle: "单次调用"
                )

                let message = try extractCommitMessage(from: response)
                await finishDebugSession(id: sessionID, finalMessage: message)
                return message
            } catch {
                await failDebugSession(id: sessionID, error: error)
                throw error
            }
        }.value
    }

    // MARK: - LLM 调用

    private func requestLLM(
        systemPrompt: String,
        userPrompt: String,
        configuration: LLMProviderConfiguration,
        sessionID: UUID,
        attemptTitle: String
    ) async throws -> String {
        do {
            Self.logger.info("调用 LLM: model=\(configuration.model)")
            let result = try await llmService.complete(
                messages: [
                    .init(role: "system", content: systemPrompt),
                    .init(role: "user", content: userPrompt)
                ],
                configuration: configuration,
                maxTokens: 1024,
                responseFormat: .jsonObject,
                disableThinking: true
            )
            Self.logger.info("LLM 响应成功，长度=\(result.content.count)，finish=\(result.finishReason ?? "nil")")
            await recordDebugAttempt(sessionID: sessionID, title: attemptTitle, systemPrompt: systemPrompt, userPrompt: userPrompt, rawResponse: result.content, errorMessage: nil)

            if result.finishReason == "length" {
                // 即便 content 非空，length 截断也常导致 JSON 不完整
                Self.logger.error("LLM 输出因 length 截断")
            }

            return result.content
        } catch {
            await recordDebugAttempt(sessionID: sessionID, title: attemptTitle, systemPrompt: systemPrompt, userPrompt: userPrompt, rawResponse: nil, errorMessage: GitCommandError.describe(error))
            throw error
        }
    }

    private func extractCommitMessage(from response: String) throws -> String {
        if let message = CommitMessageCandidate.extractSubjectFromRawResponse(response), !message.isEmpty {
            return message
        }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            throw GitCommandError(message: "AI 返回了不完整或无法解析的 JSON（常见于输出被截断），请重试。")
        }

        let firstLine = trimmed
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'` ").union(.whitespacesAndNewlines))
            ?? ""

        guard !firstLine.isEmpty else {
            throw GitCommandError(message: "AI 生成了空内容，请重试。")
        }

        return firstLine
    }

    // MARK: - Debug

    private func beginDebugSession(
        id: UUID,
        repository: GitRepository,
        changedItemCount: Int,
        context: CommitAnalysisContext,
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
        await MainActor.run { debugStore.completeSession(sessionID: id, finalMessage: finalMessage) }
    }

    private func failDebugSession(id: UUID, error: Error) async {
        guard let debugStore else { return }
        await MainActor.run { debugStore.failSession(sessionID: id, errorMessage: GitCommandError.describe(error)) }
    }
}
