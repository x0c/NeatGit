import Foundation

struct GitCommandError: Error {
    let message: String
}

extension GitCommandError {
    static func describe(_ error: Error) -> String {
        if let error = error as? GitCommandError {
            return error.message
        }

        return error.localizedDescription
    }
}

struct GitCommandResult {
    let outputData: Data
    let terminationStatus: Int32
}

enum GitCommandRunner {
    static func run(
        in repositoryPath: String,
        arguments: [String],
        standardInputData: Data? = nil
    ) throws -> GitCommandResult {
        let process = Process()
        let combinedPipe = Pipe()
        let standardInputPipe = standardInputData.map { _ in Pipe() }

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "--no-optional-locks", "-C", repositoryPath] + arguments
        process.standardOutput = combinedPipe
        process.standardError = combinedPipe
        process.standardInput = standardInputPipe

        try process.run()

        // 标准输入的写入必须与标准输出的读取并行。
        //
        // Git 在读完全部 pathspec 之前就会往标准输出写内容（警告、进度、对象内容），
        // 若在本线程把标准输入一次写满再去读输出，双方会各自等对方腾出管道缓冲区：
        // 本线程阻塞在 write，Git 阻塞在 write，形成死锁。
        // 实测 `cat-file --batch` 请求约 820 KB、输出更大时必然卡死，
        // 把写入挪到独立线程后同一用例正常返回。
        if let standardInputData, let standardInputPipe {
            let inputHandle = standardInputPipe.fileHandleForWriting
            Thread.detachNewThread {
                inputHandle.write(standardInputData)
                try? inputHandle.close()
            }
        }

        let outputData = combinedPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return GitCommandResult(
            outputData: outputData,
            terminationStatus: process.terminationStatus
        )
    }

    static func requireSuccess(
        _ result: GitCommandResult,
        defaultMessage: String
    ) throws -> Data {
        guard result.terminationStatus == 0 else {
            throw GitCommandError(
                message: failureMessage(from: result.outputData, defaultMessage: defaultMessage)
            )
        }

        return result.outputData
    }

    static func failureMessage(from outputData: Data, defaultMessage: String) -> String {
        let message = String(decoding: outputData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return message.isEmpty ? defaultMessage : message
    }

    /// 一次进程读取多个 Git 对象内容，缺失对象返回 nil。
    ///
    /// 旧写法对每个对象先 `cat-file -e` 再 `show`，单文件 diff 要启动 4 个 git 进程；
    /// `cat-file --batch` 把存在性判断和内容读取合并成一次进程启动，
    /// 本机实测同样的读取从约 105ms 降到约 23ms。
    static func readObjects(
        specifiers: [String],
        in repositoryPath: String
    ) throws -> [Data?] {
        guard !specifiers.isEmpty else { return [] }

        let request = Data((specifiers.joined(separator: "\n") + "\n").utf8)
        let result = try run(
            in: repositoryPath,
            arguments: ["cat-file", "--batch"],
            standardInputData: request
        )
        let outputData = try requireSuccess(result, defaultMessage: "Git 对象内容读取失败。")
        return try parseBatchOutput(outputData, expectedCount: specifiers.count)
    }

    /// `cat-file --batch` 响应：命中为「对象 ID 类型 字节数」后跟内容和换行，缺失为「请求 missing」。
    private static func parseBatchOutput(_ data: Data, expectedCount: Int) throws -> [Data?] {
        var objects: [Data?] = []
        var cursor = data.startIndex

        while objects.count < expectedCount {
            guard let lineEnd = data[cursor...].firstIndex(of: UInt8(ascii: "\n")) else {
                throw GitCommandError(message: "Git 对象内容读取结果不完整。")
            }

            let header = String(decoding: data[cursor..<lineEnd], as: UTF8.self)
            cursor = data.index(after: lineEnd)

            let fields = header.split(separator: " ")
            guard fields.count == 3, let byteCount = Int(fields[2]), byteCount >= 0 else {
                // 「missing」「ambiguous」等都按对象不存在处理，与旧的 cat-file -e 语义一致。
                objects.append(nil)
                continue
            }

            guard let contentEnd = data.index(cursor, offsetBy: byteCount, limitedBy: data.endIndex) else {
                throw GitCommandError(message: "Git 对象内容读取结果不完整。")
            }

            objects.append(Data(data[cursor..<contentEnd]))
            // 内容之后 git 会补一个换行分隔符。
            cursor = data.index(contentEnd, offsetBy: 1, limitedBy: data.endIndex) ?? data.endIndex
        }

        return objects
    }
}

final class GitSkipWorktreeService: @unchecked Sendable {
    func markSkipped(_ item: RepositoryFileItem, in repository: GitRepository) async throws {
        try await updateIndex(arguments: ["update-index", "--skip-worktree", "--", item.path], in: repository)
    }

    func removeSkipped(_ item: RepositoryFileItem, in repository: GitRepository) async throws {
        try await updateIndex(arguments: ["update-index", "--no-skip-worktree", "--", item.path], in: repository)
    }

    private func updateIndex(arguments: [String], in repository: GitRepository) async throws {
        try await Task.detached(priority: .userInitiated) {
            let result = try GitCommandRunner.run(in: repository.path, arguments: arguments)
            _ = try GitCommandRunner.requireSuccess(result, defaultMessage: "更新 skip-worktree 状态失败。")
        }.value
    }
}
