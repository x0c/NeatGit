import Foundation

enum GitIgnoreRuleTarget {
    case exactPath(String, isDirectory: Bool)
    case fileName(String)
    case directory(String)

    var rule: String {
        switch self {
        case let .exactPath(relativePath, isDirectory):
            let suffix = isDirectory ? "/" : ""
            return "/" + escapeGitIgnoreRule(relativePath) + suffix
        case let .fileName(fileName):
            return escapeGitIgnoreRule(fileName)
        case let .directory(relativePath):
            return "/" + escapeGitIgnoreRule(relativePath) + "/"
        }
    }

    private func escapeGitIgnoreRule(_ value: String) -> String {
        guard let firstCharacter = value.first, firstCharacter == "#" || firstCharacter == "!" else {
            return value
        }

        return "\\" + value
    }
}

final class GitIgnoreWriter: @unchecked Sendable {
    func append(_ target: GitIgnoreRuleTarget, to repository: GitRepository) async throws {
        try await Task.detached(priority: .userInitiated) { [self] in
            try self.append(rule: target.rule, to: repository.path)
        }.value
    }

    private func append(rule: String, to repositoryPath: String) throws {
        let fileURL = URL(fileURLWithPath: repositoryPath).appendingPathComponent(".gitignore")
        let currentContent = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        let normalizedLines = currentContent.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard !normalizedLines.contains(rule) else { return }

        var updatedContent = currentContent
        if !updatedContent.isEmpty, !updatedContent.hasSuffix("\n") {
            updatedContent.append("\n")
        }

        updatedContent.append(rule)
        updatedContent.append("\n")

        do {
            try updatedContent.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            throw GitCommandError(message: "写入 \(fileURL.path) 失败：\(error.localizedDescription)")
        }
    }
}
