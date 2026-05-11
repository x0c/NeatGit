import Foundation

final class GitRepositoryStatusLoader: @unchecked Sendable {
    func loadSnapshot(for repository: GitRepository) async throws -> RepositoryFileSnapshot {
        try await Task.detached(priority: .userInitiated) { [self] in
            try self.makeSnapshot(for: repository)
        }.value
    }

    private func makeSnapshot(for repository: GitRepository) throws -> RepositoryFileSnapshot {
        let statusData = try loadGitOutput(
            in: repository.path,
            arguments: ["status", "--porcelain=v2", "--ignored=matching", "--untracked-files=all", "-z"],
            defaultMessage: "Git 命令执行失败。"
        )
        let skippedData = try loadGitOutput(
            in: repository.path,
            arguments: ["ls-files", "-t", "-z"],
            defaultMessage: "Git 命令执行失败。"
        )

        let statusEntries = try parseStatusEntries(from: statusData)
        let skippedPaths = parseSkippedPaths(from: skippedData)
        let skippedSet = Set(skippedPaths)

        let changedFiles = statusEntries.compactMap { entry -> RepositoryFileItem? in
            switch entry {
            case let .changed(path, xy, previousPath):
                guard !skippedSet.contains(path) else { return nil }
                return makeFileItem(
                    section: .changed,
                    path: path,
                    state: .changed(summarizeStatus(xy)),
                    gitStatusCode: xy,
                    previousPath: previousPath,
                    repositoryPath: repository.path
                )
            case let .untracked(path):
                guard !skippedSet.contains(path) else { return nil }
                return makeFileItem(
                    section: .changed,
                    path: path,
                    state: .untracked,
                    gitStatusCode: "??",
                    previousPath: nil,
                    repositoryPath: repository.path
                )
            case .ignored:
                return nil
            }
        }

        let skippedFiles = skippedPaths.map {
            makeFileItem(
                section: .skipped,
                path: $0,
                state: .skipped,
                gitStatusCode: nil,
                previousPath: nil,
                repositoryPath: repository.path
            )
        }

        let ignoredFiles = statusEntries.compactMap { entry -> RepositoryFileItem? in
            guard case let .ignored(path) = entry else { return nil }
            return makeFileItem(
                section: .ignored,
                path: path,
                state: .ignored,
                gitStatusCode: "!!",
                previousPath: nil,
                repositoryPath: repository.path
            )
        }

        return RepositoryFileSnapshot(
            repositoryPath: repository.path,
            changedFiles: deduplicatedFileItems(changedFiles).sorted(by: sortFileItems),
            skippedFiles: deduplicatedFileItems(skippedFiles).sorted(by: sortFileItems),
            ignoredFiles: deduplicatedFileItems(ignoredFiles).sorted(by: sortFileItems)
        )
    }

    private func parseStatusEntries(from data: Data) throws -> [GitStatusEntry] {
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
        var entries: [GitStatusEntry] = []
        var index = 0

        while index < records.count {
            let record = String(decoding: records[index], as: UTF8.self)

            if record.hasPrefix("1 ") {
                let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9 else {
                    throw GitCommandError(message: "无法解析 Git 变更记录。")
                }

                entries.append(.changed(path: String(fields[8]), xy: String(fields[1]), previousPath: nil))
            } else if record.hasPrefix("2 ") {
                let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard fields.count == 10 else {
                    throw GitCommandError(message: "无法解析 Git 重命名记录。")
                }

                guard records.indices.contains(index + 1) else {
                    throw GitCommandError(message: "Git 重命名记录缺少原始路径。")
                }

                let previousPath = String(decoding: records[index + 1], as: UTF8.self)
                entries.append(.changed(path: String(fields[9]), xy: String(fields[1]), previousPath: previousPath))
                index += 1
            } else if record.hasPrefix("u ") {
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11 else {
                    throw GitCommandError(message: "无法解析 Git 冲突记录。")
                }

                entries.append(.changed(path: String(fields[10]), xy: String(fields[1]), previousPath: nil))
            } else if record.hasPrefix("! ") {
                entries.append(.ignored(path: String(record.dropFirst(2))))
            } else if record.hasPrefix("? ") {
                entries.append(.untracked(path: String(record.dropFirst(2))))
            }

            index += 1
        }

        return entries
    }

    private func parseSkippedPaths(from data: Data) -> [String] {
        data.split(separator: 0, omittingEmptySubsequences: true)
            .compactMap { record in
                let line = String(decoding: record, as: UTF8.self)
                guard line.hasPrefix("S ") else { return nil }
                return String(line.dropFirst(2))
            }
    }

    private func summarizeStatus(_ xy: String) -> String {
        let x = xy.first ?? "."
        let y = xy.dropFirst().first ?? "."

        if x == "U" || y == "U" {
            return "冲突"
        }

        if x == "R" || y == "R" {
            return "重命名"
        }

        if x == "D" || y == "D" {
            return "删除"
        }

        if x == "A" || y == "A" {
            return "新增"
        }

        if x == "T" || y == "T" {
            return "类型变更"
        }

        if x != "." && y != "." {
            return "已暂存 + 未暂存"
        }

        if x != "." {
            return "已暂存"
        }

        return "未暂存"
    }

    private func makeFileItem(
        section: RepositoryFileSection,
        path: String,
        state: RepositoryFileState,
        gitStatusCode: String?,
        previousPath: String?,
        repositoryPath: String
    ) -> RepositoryFileItem {
        RepositoryFileItem(
            section: section,
            path: path,
            kind: fileKind(for: path, repositoryPath: repositoryPath),
            state: state,
            gitStatusCode: gitStatusCode,
            previousPath: previousPath
        )
    }

    private func fileKind(for path: String, repositoryPath: String) -> RepositoryFileKind {
        if path.hasSuffix("/") {
            return .directory
        }

        let absolutePath = URL(fileURLWithPath: repositoryPath)
            .appendingPathComponent(path)
            .path
        var isDirectory = ObjCBool(false)

        if FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDirectory), isDirectory.boolValue {
            return .directory
        }

        return .file
    }

    private func deduplicatedFileItems(_ items: [RepositoryFileItem]) -> [RepositoryFileItem] {
        var seenIDs: Set<RepositoryFileItem.ID> = []
        return items.filter { item in
            seenIDs.insert(item.id).inserted
        }
    }

    private func sortFileItems(_ lhs: RepositoryFileItem, _ rhs: RepositoryFileItem) -> Bool {
        let lhsDisplayName = lhs.displayName
        let rhsDisplayName = rhs.displayName

        let fileNameOrder = lhsDisplayName.localizedCaseInsensitiveCompare(rhsDisplayName)
        if fileNameOrder != .orderedSame {
            return fileNameOrder == .orderedAscending
        }

        let lhsParentPath = lhs.parentPathDisplay ?? ""
        let rhsParentPath = rhs.parentPathDisplay ?? ""
        let parentPathOrder = lhsParentPath.localizedCaseInsensitiveCompare(rhsParentPath)
        if parentPathOrder != .orderedSame {
            return parentPathOrder == .orderedAscending
        }

        return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
    }

    private func loadGitOutput(
        in repositoryPath: String,
        arguments: [String],
        defaultMessage: String
    ) throws -> Data {
        let result = try GitCommandRunner.run(in: repositoryPath, arguments: arguments)
        return try GitCommandRunner.requireSuccess(result, defaultMessage: defaultMessage)
    }
}

private enum GitStatusEntry {
    case changed(path: String, xy: String, previousPath: String?)
    case ignored(path: String)
    case untracked(path: String)
}
