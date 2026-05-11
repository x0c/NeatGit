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

        if let standardInputData, let standardInputPipe {
            standardInputPipe.fileHandleForWriting.write(standardInputData)
            try? standardInputPipe.fileHandleForWriting.close()
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
