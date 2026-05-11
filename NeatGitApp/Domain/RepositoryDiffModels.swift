import Foundation

enum RepositoryDiffMode: String, CaseIterable, Identifiable {
    case workingTree
    case staged

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workingTree:
            return "未暂存"
        case .staged:
            return "已暂存"
        }
    }

    var originalLabel: String {
        switch self {
        case .workingTree:
            return "Index"
        case .staged:
            return "HEAD"
        }
    }

    var modifiedLabel: String {
        switch self {
        case .workingTree:
            return "Working Tree"
        case .staged:
            return "Index"
        }
    }
}

struct RepositoryDiffDocument: Equatable {
    let repositoryPath: String
    let filePath: String
    let mode: RepositoryDiffMode
    let originalText: String
    let modifiedText: String
    let languageHint: String?
    let hunks: [RepositoryDiffHunk]
}

struct MonacoDiffPayload: Encodable, Equatable {
    let filePath: String
    let modeTitle: String
    let originalLabel: String
    let modifiedLabel: String
    let originalText: String
    let modifiedText: String
    let languageHint: String?
}

struct RepositoryDiffHunk: Equatable, Sendable {
    let originalStartLine: Int
    let originalLineCount: Int
    let modifiedStartLine: Int
    let modifiedLineCount: Int
}

extension RepositoryDiffDocument {
    func monacoPayload(showChangesOnly: Bool) -> MonacoDiffPayload {
        let displayedContent = showChangesOnly
            ? changesOnlyContent()
            : (original: originalText, modified: modifiedText)

        return MonacoDiffPayload(
            filePath: filePath,
            modeTitle: mode.title,
            originalLabel: mode.originalLabel,
            modifiedLabel: mode.modifiedLabel,
            originalText: displayedContent.original,
            modifiedText: displayedContent.modified,
            languageHint: languageHint
        )
    }

    private func changesOnlyContent() -> (original: String, modified: String) {
        guard !hunks.isEmpty else {
            return (originalText, modifiedText)
        }

        let originalLines = lineArray(from: originalText)
        let modifiedLines = lineArray(from: modifiedText)
        var trimmedOriginalLines: [String] = []
        var trimmedModifiedLines: [String] = []

        for hunk in hunks {
            trimmedOriginalLines.append(
                contentsOf: slice(
                    from: originalLines,
                    startLine: hunk.originalStartLine,
                    lineCount: hunk.originalLineCount
                )
            )
            trimmedModifiedLines.append(
                contentsOf: slice(
                    from: modifiedLines,
                    startLine: hunk.modifiedStartLine,
                    lineCount: hunk.modifiedLineCount
                )
            )
        }

        return (
            trimmedOriginalLines.joined(),
            trimmedModifiedLines.joined()
        )
    }

    private func lineArray(from text: String) -> [String] {
        guard !text.isEmpty else {
            return []
        }

        var lines: [String] = []
        var lineStart = text.startIndex
        var index = text.startIndex

        while index < text.endIndex {
            if text[index] == "\n" {
                let nextIndex = text.index(after: index)
                lines.append(String(text[lineStart..<nextIndex]))
                lineStart = nextIndex
            }

            index = text.index(after: index)
        }

        if lineStart < text.endIndex {
            lines.append(String(text[lineStart..<text.endIndex]))
        }

        return lines
    }

    private func slice(
        from lines: [String],
        startLine: Int,
        lineCount: Int
    ) -> ArraySlice<String> {
        guard lineCount > 0, !lines.isEmpty else {
            return []
        }

        let lowerBound = max(startLine - 1, 0)
        let upperBound = min(lowerBound + lineCount, lines.count)
        guard lowerBound < upperBound else {
            return []
        }

        return lines[lowerBound..<upperBound]
    }
}
