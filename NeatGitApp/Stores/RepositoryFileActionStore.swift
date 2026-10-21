import Foundation
import Observation

/// 文件级 Git 操作的状态容器：写 .gitignore、标记/移出「不提交的文件」。
///
/// 原先这几个动作在 `ContentView` 里各写一遍
/// 「`Task` → `try await` → `MainActor.run { 刷新 }` → `MainActor.run { 弹错 }`」，
/// 四处结构完全相同只有服务调用不同。这里收成一条通道，新增文件级操作只加一个方法。
@MainActor
@Observable
final class RepositoryFileActionStore {
    struct Alert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var alert: Alert?

    @ObservationIgnored
    private let gitIgnoreWriter: GitIgnoreWriter
    @ObservationIgnored
    private let skipWorktreeService: GitSkipWorktreeService

    init(
        gitIgnoreWriter: GitIgnoreWriter = GitIgnoreWriter(),
        skipWorktreeService: GitSkipWorktreeService = GitSkipWorktreeService()
    ) {
        self.gitIgnoreWriter = gitIgnoreWriter
        self.skipWorktreeService = skipWorktreeService
    }

    func appendIgnoreRule(
        _ target: GitIgnoreRuleTarget,
        in repository: GitRepository,
        onFinish: @escaping () -> Void
    ) {
        perform(failureTitle: "更新 .gitignore 失败", onFinish: onFinish) { [gitIgnoreWriter] in
            try await gitIgnoreWriter.append(target, to: repository)
        }
    }

    func markAsSkipped(
        _ item: RepositoryFileItem,
        in repository: GitRepository,
        onFinish: @escaping () -> Void
    ) {
        guard item.canMarkAsSkipped else { return }

        perform(failureTitle: "更新不提交文件失败", onFinish: onFinish) { [skipWorktreeService] in
            try await skipWorktreeService.markSkipped(item, in: repository)
        }
    }

    func removeFromSkipped(
        _ item: RepositoryFileItem,
        in repository: GitRepository,
        onFinish: @escaping () -> Void
    ) {
        guard item.canRemoveFromSkipped else { return }

        perform(failureTitle: "移出不提交文件失败", onFinish: onFinish) { [skipWorktreeService] in
            try await skipWorktreeService.removeSkipped(item, in: repository)
        }
    }

    /// 所有文件级操作共用的执行壳：成功后回调刷新，失败转成界面提示。
    private func perform(
        failureTitle: String,
        onFinish: @escaping () -> Void,
        operation: @escaping () async throws -> Void
    ) {
        Task {
            do {
                try await operation()
                onFinish()
            } catch {
                alert = Alert(title: failureTitle, message: GitCommandError.describe(error))
            }
        }
    }
}
