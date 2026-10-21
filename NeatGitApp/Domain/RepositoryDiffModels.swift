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

extension RepositoryDiffDocument {
    // 内容始终为全文；「只看变更」是渲染侧的折叠开关，走独立通道，切换时不重传正文。
    var monacoPayload: MonacoDiffPayload {
        MonacoDiffPayload(
            filePath: filePath,
            modeTitle: mode.title,
            originalLabel: mode.originalLabel,
            modifiedLabel: mode.modifiedLabel,
            originalText: originalText,
            modifiedText: modifiedText,
            languageHint: languageHint
        )
    }
}
