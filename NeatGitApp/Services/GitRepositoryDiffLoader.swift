import Foundation

final class GitRepositoryDiffLoader: @unchecked Sendable {
    private let maxTextBytes = 750_000

    func loadDiff(
        for item: RepositoryFileItem,
        in repository: GitRepository,
        mode: RepositoryDiffMode
    ) async throws -> RepositoryDiffDocument {
        try await Task.detached(priority: .userInitiated) { [self] in
            try makeDocument(for: item, in: repository, mode: mode)
        }.value
    }

    private func makeDocument(
        for item: RepositoryFileItem,
        in repository: GitRepository,
        mode: RepositoryDiffMode
    ) throws -> RepositoryDiffDocument {
        guard item.section == .changed else {
            throw GitCommandError(message: "当前只支持更改文件的 diff 预览。")
        }

        guard !item.hasConflict else {
            throw GitCommandError(message: "冲突文件的可视化 diff 还没接入。")
        }

        guard item.availableDiffModes.contains(mode) else {
            throw GitCommandError(message: "这个文件当前没有可展示的 \(mode.title) diff。")
        }

        let (originalData, modifiedData) = try loadContents(for: item, in: repository, mode: mode)

        if max(originalData.count, modifiedData.count) > maxTextBytes {
            throw GitCommandError(message: "文件过大，第一版暂不展示超过 750 KB 的文本 diff。")
        }

        if isBinaryData(originalData) || isBinaryData(modifiedData) {
            throw GitCommandError(message: "当前只支持文本 diff，二进制文件稍后再接。")
        }

        let originalText = decodeText(originalData)
        let modifiedText = decodeText(modifiedData)

        return RepositoryDiffDocument(
            repositoryPath: repository.path,
            filePath: item.path,
            mode: mode,
            originalText: originalText,
            modifiedText: modifiedText,
            languageHint: languageHint(for: item.path)
        )
    }

    /// diff 两侧内容的来源：空、某个 Git 对象、或工作区文件。
    private enum DiffSide {
        case empty
        case gitObject(String)
        case workingTreeFile(String)
    }

    /// 先把两侧来源判断完，再一次性取数据。
    ///
    /// Git 对象走同一次 `cat-file --batch`，避免每侧各启动「存在性检查 + 读内容」两个进程。
    private func loadContents(
        for item: RepositoryFileItem,
        in repository: GitRepository,
        mode: RepositoryDiffMode
    ) throws -> (original: Data, modified: Data) {
        let originalSide = originalSide(for: item, mode: mode)
        let modifiedSide = modifiedSide(for: item, mode: mode)
        let specifiers = [originalSide, modifiedSide].compactMap { side -> String? in
            if case let .gitObject(specifier) = side { return specifier }
            return nil
        }
        let objects = try GitCommandRunner.readObjects(specifiers: specifiers, in: repository.path)
        var remainingObjects = objects[...]

        func resolve(_ side: DiffSide) throws -> Data {
            switch side {
            case .empty:
                return Data()
            case .gitObject:
                let object = remainingObjects.first ?? nil
                remainingObjects = remainingObjects.dropFirst()
                return object ?? Data()
            case let .workingTreeFile(path):
                return try readWorkingTreeFile(at: path, in: repository.path)
            }
        }

        return (try resolve(originalSide), try resolve(modifiedSide))
    }

    private func originalSide(for item: RepositoryFileItem, mode: RepositoryDiffMode) -> DiffSide {
        if item.isUntracked {
            return .empty
        }

        switch mode {
        case .workingTree:
            let sourcePath = referencePath(for: item, statusCode: item.workTreeStatusCode)
            return .gitObject(":\(sourcePath)")
        case .staged:
            guard let indexStatusCode = item.indexStatusCode, indexStatusCode != "A" else {
                return .empty
            }

            let sourcePath = referencePath(for: item, statusCode: indexStatusCode)
            return .gitObject("HEAD:\(sourcePath)")
        }
    }

    private func modifiedSide(for item: RepositoryFileItem, mode: RepositoryDiffMode) -> DiffSide {
        switch mode {
        case .workingTree:
            if !item.isUntracked, item.workTreeStatusCode == "D" {
                return .empty
            }

            return .workingTreeFile(item.path)
        case .staged:
            if item.indexStatusCode == "D" {
                return .empty
            }

            return .gitObject(":\(item.path)")
        }
    }

    private func readWorkingTreeFile(at path: String, in repositoryPath: String) throws -> Data {
        let fileURL = URL(fileURLWithPath: repositoryPath).appendingPathComponent(path)

        do {
            return try Data(contentsOf: fileURL)
        } catch {
            throw GitCommandError(message: "无法读取工作区文件：\(path)")
        }
    }

    private func isBinaryData(_ data: Data) -> Bool {
        data.contains(0)
    }

    private func decodeText(_ data: Data) -> String {
        if let string = String(data: data, encoding: .utf8) {
            return string
        }

        return String(decoding: data, as: UTF8.self)
    }

    private func languageHint(for path: String) -> String? {
        let fileExtension = URL(fileURLWithPath: path).pathExtension.lowercased()

        switch fileExtension {
        case "c":
            return "c"
        case "cc", "cpp", "cxx", "hpp", "hxx":
            return "cpp"
        case "h", "m":
            return "objective-c"
        case "mm":
            return "objective-cpp"
        case "css":
            return "css"
        case "go":
            return "go"
        case "html", "htm":
            return "html"
        case "java":
            return "java"
        case "js", "cjs", "mjs":
            return "javascript"
        case "json":
            return "json"
        case "kt", "kts":
            return "kotlin"
        case "md":
            return "markdown"
        case "php":
            return "php"
        case "py":
            return "python"
        case "rb":
            return "ruby"
        case "rs":
            return "rust"
        case "sh", "zsh", "bash":
            return "shell"
        case "sql":
            return "sql"
        case "swift":
            return "swift"
        case "ts":
            return "typescript"
        case "tsx":
            return "typescript"
        case "txt":
            return "plaintext"
        case "xml":
            return "xml"
        case "yaml", "yml":
            return "yaml"
        default:
            return nil
        }
    }

    private func referencePath(for item: RepositoryFileItem, statusCode: Character?) -> String {
        if statusCode == "R" || statusCode == "C" {
            return item.previousPath ?? item.path
        }

        return item.path
    }
}
