import Foundation
import Observation

struct AICommitDebugAttempt: Identifiable, Sendable {
    let id: UUID
    let title: String
    let systemPrompt: String
    let userPrompt: String
    let rawResponse: String?
    let errorMessage: String?
    let createdAt: Date
}

struct AICommitDebugSession: Identifiable, Sendable {
    let id: UUID
    let repositoryName: String
    let changedFileCount: Int
    let committableFileCount: Int
    let strategy: CommitGenerationStrategy
    let baseURL: String
    let model: String
    let startedAt: Date
    var completedAt: Date?
    var attempts: [AICommitDebugAttempt]
    var finalMessage: String?
    var finalErrorMessage: String?
}

@MainActor
@Observable
final class AICommitDebugStore {
    private(set) var latestSession: AICommitDebugSession?

    func beginSession(
        id: UUID,
        repositoryName: String,
        changedFileCount: Int,
        committableFileCount: Int,
        configuration: LLMProviderConfiguration,
        strategy: CommitGenerationStrategy = .singlePass
    ) {
        latestSession = AICommitDebugSession(
            id: id,
            repositoryName: repositoryName,
            changedFileCount: changedFileCount,
            committableFileCount: committableFileCount,
            strategy: strategy,
            baseURL: configuration.baseURL.absoluteString,
            model: configuration.model,
            startedAt: Date(),
            completedAt: nil,
            attempts: [],
            finalMessage: nil,
            finalErrorMessage: nil
        )
    }

    func recordAttempt(
        sessionID: UUID,
        title: String,
        systemPrompt: String,
        userPrompt: String,
        rawResponse: String?,
        errorMessage: String?
    ) {
        guard latestSession?.id == sessionID else { return }

        latestSession?.attempts.append(
            AICommitDebugAttempt(
                id: UUID(),
                title: title,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                rawResponse: rawResponse,
                errorMessage: errorMessage,
                createdAt: Date()
            )
        )
    }

    func completeSession(sessionID: UUID, finalMessage: String) {
        guard latestSession?.id == sessionID else { return }
        latestSession?.finalMessage = finalMessage
        latestSession?.finalErrorMessage = nil
        latestSession?.completedAt = Date()
    }

    func failSession(sessionID: UUID, errorMessage: String) {
        guard latestSession?.id == sessionID else { return }
        latestSession?.finalErrorMessage = errorMessage
        latestSession?.completedAt = Date()
    }
}
