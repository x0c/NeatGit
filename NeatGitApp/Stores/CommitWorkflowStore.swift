import Foundation
import Observation
import os

/// 提交工作流的状态容器：提交说明、AI 生成、提交/推送、忙碌态与弹窗提示。
///
/// 这些逻辑原先全部堆在 `ContentView` 里，视图既要排版又要编排 Git 与 LLM 调用，
/// 且每条异步分支都手写 `Task { ... await MainActor.run { ... } }`。
/// 收进 `@MainActor` 容器后，视图只读状态、只触发意图，异步回写天然在主线程，
/// 不再需要 `MainActor.run` 包裹。
@MainActor
@Observable
final class CommitWorkflowStore {
    /// 需要用户确认的提示（提交失败、推送失败、AI 配置缺失等）。
    struct Alert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var commitMessage = ""
    private(set) var isRunningCommitAction = false
    private(set) var isGeneratingMessage = false
    var alert: Alert?

    /// 提交与 AI 生成互斥：任一进行中都不接受新的提交类操作。
    var isBusy: Bool {
        isRunningCommitAction || isGeneratingMessage
    }

    @ObservationIgnored
    private let commitService: GitRepositoryCommitService
    @ObservationIgnored
    private let generationService: CommitMessageGenerationService
    @ObservationIgnored
    private let llmSettingsStore: LLMSettingsStore
    @ObservationIgnored
    private static let logger = Logger(subsystem: "io.github.x0c.neatgit", category: "AICommit")

    init(
        llmSettingsStore: LLMSettingsStore,
        generationService: CommitMessageGenerationService,
        commitService: GitRepositoryCommitService = GitRepositoryCommitService()
    ) {
        self.llmSettingsStore = llmSettingsStore
        self.generationService = generationService
        self.commitService = commitService
    }

    /// 底部状态条文案：说明本次会提交多少个文件、排除了什么。
    func statusMessage(
        repository: GitRepository?,
        snapshot: RepositoryFileSnapshot?
    ) -> String {
        guard repository != nil else {
            return "选择仓库后，会自动暂存并提交可提交的文件更改。"
        }

        guard let snapshot else {
            return "正在读取仓库状态..."
        }

        let excludedCount = snapshot.changedFiles.filter(CommitExclusion.shouldExcludeFromDefaultCommit).count
        let committableCount = snapshot.changedFiles.filter(\.isCommittableByDefault).count

        guard committableCount > 0 else {
            return "没有可提交的更改，自动排除 .gitignore 和不提交的文件。"
        }

        if excludedCount > 0 {
            return "自动暂存并提交 \(committableCount) 个更改，排除 \(excludedCount) 个 .gitignore 和不提交的文件。"
        }

        return "自动暂存并提交 \(committableCount) 个更改，排除不提交的文件。"
    }

    func generateMessage(
        for repository: GitRepository?,
        snapshot: RepositoryFileSnapshot?
    ) {
        guard !isGeneratingMessage else {
            Self.logger.info("AI 生成被跳过：正在生成中")
            return
        }

        guard let repository else {
            showAlert(title: "无法生成", message: "请先选择仓库。")
            return
        }

        guard let snapshot, !snapshot.changedFiles.isEmpty else {
            showAlert(title: "无法生成", message: "当前仓库没有可分析的文件变更。")
            return
        }

        let configuration: LLMProviderConfiguration
        do {
            configuration = try llmSettingsStore.makeConfiguration()
        } catch {
            Self.logger.error("LLM 配置失败: \(GitCommandError.describe(error))")
            showAlert(
                title: "AI 设置未完成",
                message: "\(GitCommandError.describe(error))\n\n可使用 cmd+, 打开设置页继续配置。"
            )
            return
        }

        isGeneratingMessage = true
        let changedFiles = snapshot.changedFiles
        let systemPrompt = llmSettingsStore.effectiveSystemPrompt
        Self.logger.info("开始 AI 生成，文件数=\(changedFiles.count)")

        Task { [generationService] in
            defer { isGeneratingMessage = false }

            do {
                commitMessage = try await generationService.generateMessage(
                    for: repository,
                    changedItems: changedFiles,
                    configuration: configuration,
                    systemPrompt: systemPrompt
                )
            } catch {
                Self.logger.error("AI 生成失败: \(GitCommandError.describe(error))")
                showAlert(title: "生成失败", message: GitCommandError.describe(error))
            }
        }
    }

    /// 执行提交；`onFinish` 用于通知外部刷新文件状态。
    func commit(
        _ action: GitCommitAction,
        repository: GitRepository?,
        snapshot: RepositoryFileSnapshot?,
        onFinish: @escaping () -> Void
    ) {
        guard !isBusy, let repository, let snapshot else { return }

        let request = GitCommitRequest(
            repository: repository,
            message: commitMessage,
            changedItems: snapshot.changedFiles,
            action: action
        )

        isRunningCommitAction = true

        Task { [commitService] in
            defer { isRunningCommitAction = false }

            do {
                let result = try await commitService.run(request)
                commitMessage = ""
                onFinish()

                if let pushErrorMessage = result.pushErrorMessage {
                    showAlert(
                        title: "推送失败",
                        message: "本地 commit 已完成，但推送远端失败：\(pushErrorMessage)"
                    )
                }
            } catch {
                showAlert(title: "提交失败", message: GitCommandError.describe(error))
            }
        }
    }

    private func showAlert(title: String, message: String) {
        alert = Alert(title: title, message: message)
    }
}
