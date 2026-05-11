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

        let originalData = try loadOriginalData(for: item, in: repository, mode: mode)
        let modifiedData = try loadModifiedData(for: item, in: repository, mode: mode)

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
            languageHint: languageHint(for: item.path),
            hunks: try loadHunks(
                for: item,
                in: repository,
                mode: mode,
                originalText: originalText,
                modifiedText: modifiedText
            )
        )
    }

    private func loadOriginalData(
        for item: RepositoryFileItem,
        in repository: GitRepository,
        mode: RepositoryDiffMode
    ) throws -> Data {
        if item.isUntracked {
            return Data()
        }

        switch mode {
        case .workingTree:
            let sourcePath = referencePath(for: item, statusCode: item.workTreeStatusCode)
            return try readIndexBlob(at: sourcePath, in: repository.path) ?? Data()
        case .staged:
            guard let indexStatusCode = item.indexStatusCode else {
                return Data()
            }

            if indexStatusCode == "A" {
                return Data()
            }

            let sourcePath = referencePath(for: item, statusCode: indexStatusCode)
            return try readHeadBlob(at: sourcePath, in: repository.path) ?? Data()
        }
    }

    private func loadModifiedData(
        for item: RepositoryFileItem,
        in repository: GitRepository,
        mode: RepositoryDiffMode
    ) throws -> Data {
        switch mode {
        case .workingTree:
            if item.isUntracked {
                return try readWorkingTreeFile(at: item.path, in: repository.path)
            }

            if item.workTreeStatusCode == "D" {
                return Data()
            }

            return try readWorkingTreeFile(at: item.path, in: repository.path)
        case .staged:
            if item.indexStatusCode == "D" {
                return Data()
            }

            return try readIndexBlob(at: item.path, in: repository.path) ?? Data()
        }
    }

    private func readHeadBlob(at path: String, in repositoryPath: String) throws -> Data? {
        try readGitBlob(objectSpecifier: "HEAD:\(path)", in: repositoryPath)
    }

    private func readIndexBlob(at path: String, in repositoryPath: String) throws -> Data? {
        try readGitBlob(objectSpecifier: ":\(path)", in: repositoryPath)
    }

    private func readGitBlob(objectSpecifier: String, in repositoryPath: String) throws -> Data? {
        guard try gitBlobExists(objectSpecifier: objectSpecifier, in: repositoryPath) else {
            return nil
        }

        let result = try GitCommandRunner.run(
            in: repositoryPath,
            arguments: ["show", "--no-textconv", objectSpecifier]
        )
        return try GitCommandRunner.requireSuccess(result, defaultMessage: "Git diff 内容读取失败。")
    }

    private func gitBlobExists(objectSpecifier: String, in repositoryPath: String) throws -> Bool {
        let result = try GitCommandRunner.run(
            in: repositoryPath,
            arguments: ["cat-file", "-e", objectSpecifier]
        )

        if result.terminationStatus == 0 {
            return true
        }

        if result.terminationStatus == 128 {
            return false
        }

        throw GitCommandError(
            message: GitCommandRunner.failureMessage(
                from: result.outputData,
                defaultMessage: "无法检查 Git blob 是否存在。"
            )
        )
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

    private func loadHunks(
        for item: RepositoryFileItem,
        in repository: GitRepository,
        mode: RepositoryDiffMode,
        originalText: String,
        modifiedText: String
    ) throws -> [RepositoryDiffHunk] {
        if item.isUntracked {
            return [
                RepositoryDiffHunk(
                    originalStartLine: 1,
                    originalLineCount: 0,
                    modifiedStartLine: 1,
                    modifiedLineCount: lineCount(in: modifiedText)
                )
            ]
        }

        let patch = try loadPatch(for: item, in: repository, mode: mode)
        let hunks = parseHunks(from: patch)

        if !hunks.isEmpty {
            return hunks
        }

        guard originalText != modifiedText else {
            return []
        }

        return [
            RepositoryDiffHunk(
                originalStartLine: 1,
                originalLineCount: lineCount(in: originalText),
                modifiedStartLine: 1,
                modifiedLineCount: lineCount(in: modifiedText)
            )
        ]
    }

    private func loadPatch(
        for item: RepositoryFileItem,
        in repository: GitRepository,
        mode: RepositoryDiffMode
    ) throws -> String {
        let arguments = diffArguments(for: item, mode: mode)
        let result = try GitCommandRunner.run(in: repository.path, arguments: arguments)
        let patchData = try GitCommandRunner.requireSuccess(result, defaultMessage: "Git diff 内容读取失败。")
        return decodeText(patchData)
    }

    private func diffArguments(for item: RepositoryFileItem, mode: RepositoryDiffMode) -> [String] {
        var arguments = ["diff", "--no-ext-diff", "--no-color", "--unified=0"]

        if mode == .staged {
            arguments.append("--cached")
        }

        arguments.append("--")
        arguments.append(contentsOf: item.indexSyncPaths)
        return arguments
    }

    private func parseHunks(from patch: String) -> [RepositoryDiffHunk] {
        let pattern = #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#
        guard let regularExpression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        return patch
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line -> RepositoryDiffHunk? in
                let lineString = String(line)
                let range = NSRange(lineString.startIndex..<lineString.endIndex, in: lineString)
                guard let match = regularExpression.firstMatch(in: lineString, range: range) else {
                    return nil
                }

                guard
                    let originalStart = captureInt(at: 1, in: lineString, match: match),
                    let modifiedStart = captureInt(at: 3, in: lineString, match: match)
                else {
                    return nil
                }

                let originalLineCount = captureInt(at: 2, in: lineString, match: match) ?? 1
                let modifiedLineCount = captureInt(at: 4, in: lineString, match: match) ?? 1

                return RepositoryDiffHunk(
                    originalStartLine: originalStart,
                    originalLineCount: originalLineCount,
                    modifiedStartLine: modifiedStart,
                    modifiedLineCount: modifiedLineCount
                )
            }
    }

    private func captureInt(
        at index: Int,
        in line: String,
        match: NSTextCheckingResult
    ) -> Int? {
        guard index < match.numberOfRanges else {
            return nil
        }

        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: line) else {
            return nil
        }

        return Int(line[swiftRange])
    }

    private func lineCount(in text: String) -> Int {
        guard !text.isEmpty else {
            return 0
        }

        let newlineCount = text.reduce(into: 0) { count, character in
            if character == "\n" {
                count += 1
            }
        }

        return text.last == "\n" ? newlineCount : newlineCount + 1
    }
}
