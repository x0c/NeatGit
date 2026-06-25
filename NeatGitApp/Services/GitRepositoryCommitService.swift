import Foundation

enum GitCommitAction: Sendable {
    case commitOnly
    case commitAndPush
}

struct GitCommitRequest: Sendable {
    let repository: GitRepository
    let message: String
    let changedItems: [RepositoryFileItem]
    let action: GitCommitAction
}

struct GitCommitResult: Sendable {
    let didPush: Bool
    let pushErrorMessage: String?
}

final class GitRepositoryCommitService: @unchecked Sendable {
    func run(_ request: GitCommitRequest) async throws -> GitCommitResult {
        try await Task.detached(priority: .userInitiated) { [self] in
            try perform(request)
        }.value
    }

    private func perform(_ request: GitCommitRequest) throws -> GitCommitResult {
        let message = request.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            throw GitCommandError(message: "请输入 commit message。")
        }

        let committableItems = request.changedItems.filter { item in
            item.isCheckableForCommit && !CommitExclusion.shouldExcludeFromDefaultCommit(item)
        }

        try synchronizeIndex(
            committableItems: committableItems,
            changedItems: request.changedItems,
            repositoryPath: request.repository.path
        )

        try ensureCommitHasStagedChanges(
            in: request.repository.path,
            hasCommittableItems: !committableItems.isEmpty
        )

        try runGit(
            in: request.repository.path,
            arguments: ["commit", "-m", message],
            defaultMessage: "提交失败。"
        )

        guard request.action == .commitAndPush else {
            return GitCommitResult(didPush: false, pushErrorMessage: nil)
        }

        do {
            try runGit(
                in: request.repository.path,
                arguments: ["push"],
                defaultMessage: "推送失败。"
            )
            return GitCommitResult(didPush: true, pushErrorMessage: nil)
        } catch {
            return GitCommitResult(
                didPush: false,
                pushErrorMessage: GitCommandError.describe(error)
            )
        }
    }

    private func synchronizeIndex(
        committableItems: [RepositoryFileItem],
        changedItems: [RepositoryFileItem],
        repositoryPath: String
    ) throws {
        let includedIDs = Set(committableItems.map(\.id))
        let excludedStagedItems = changedItems.filter { item in
            item.isCheckableForCommit && item.isStaged && !includedIDs.contains(item.id)
        }

        let pathsToUnstage = uniquePaths(from: excludedStagedItems)
        if !pathsToUnstage.isEmpty {
            try runGitWithPathspecInput(
                in: repositoryPath,
                arguments: ["restore", "--staged"],
                paths: pathsToUnstage,
                defaultMessage: "取消暂存失败。"
            )
        }

        let itemsNeedingStageUpdate = committableItems.filter { item in
            item.isUntracked || item.hasUnstagedChanges
        }

        let pathsToStage = uniquePaths(from: itemsNeedingStageUpdate)
        if !pathsToStage.isEmpty {
            try runGitWithPathspecInput(
                in: repositoryPath,
                arguments: ["add", "-A"],
                paths: pathsToStage,
                defaultMessage: "暂存文件失败。"
            )
        }
    }

    private func ensureCommitHasStagedChanges(in repositoryPath: String, hasCommittableItems: Bool) throws {
        let result = try GitCommandRunner.run(
            in: repositoryPath,
            arguments: ["diff", "--cached", "--quiet", "--exit-code"]
        )

        switch result.terminationStatus {
        case 1:
            return
        case 0:
            let message: String
            if hasCommittableItems {
                message = "当前没有可提交的文件更改。"
            } else {
                message = "当前没有可提交的文件更改，默认会排除 .gitignore 和 skip-worktree 文件。"
            }
            throw GitCommandError(message: message)
        default:
            throw GitCommandError(
                message: GitCommandRunner.failureMessage(
                    from: result.outputData,
                    defaultMessage: "检查暂存区状态失败。"
                )
            )
        }
    }

    private func uniquePaths(from items: [RepositoryFileItem]) -> [String] {
        var seen: Set<String> = []
        var paths: [String] = []

        for item in items {
            for path in item.indexSyncPaths where seen.insert(path).inserted {
                paths.append(path)
            }
        }

        return paths
    }

    private func runGit(
        in repositoryPath: String,
        arguments: [String],
        defaultMessage: String
    ) throws {
        let result = try GitCommandRunner.run(in: repositoryPath, arguments: arguments)
        _ = try GitCommandRunner.requireSuccess(result, defaultMessage: defaultMessage)
    }

    private func runGitWithPathspecInput(
        in repositoryPath: String,
        arguments: [String],
        paths: [String],
        defaultMessage: String
    ) throws {
        let pathspecData = makePathspecData(from: paths)
        let result = try GitCommandRunner.run(
            in: repositoryPath,
            arguments: arguments + ["--pathspec-from-file=-", "--pathspec-file-nul"],
            standardInputData: pathspecData
        )
        _ = try GitCommandRunner.requireSuccess(result, defaultMessage: defaultMessage)
    }

    private func makePathspecData(from paths: [String]) -> Data {
        var data = Data()

        for path in paths {
            data.append(path.data(using: .utf8, allowLossyConversion: false) ?? Data(path.utf8))
            data.append(0)
        }

        return data
    }
}
