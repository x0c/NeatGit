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

    // 以下为原生差异视图准备的逐行对照结果。加载差异时不计算，全部保持默认值（空 / 0 / false）；
    // 只有调用 calculatingDiffRows() 才补全。
    /// 行按文档顺序排列；大文件可达数万行，等值比较不包含本字段。
    var rows: [RepositoryDiffRow] = []
    /// 原文行数（按 "\n" 切分，末尾换行符不产生空行）。
    var originalLines: Int = 0
    /// 修改后行数。
    var modifiedLines: Int = 0
    /// 原文非空且末尾没有换行符。
    var originalEndsWithoutNewline: Bool = false
    /// 修改后文本非空且末尾没有换行符。
    var modifiedEndsWithoutNewline: Bool = false

    /// 按需计算逐行对照结果，返回补全了 `rows`、两侧行数与末尾缺换行符标记的新文档；自身不变。
    ///
    /// 这是耗时操作：耗时随两侧全文行数增长（有预算上限，但大文件仍可能需要上百毫秒到秒级），
    /// 必须在后台线程调用，不要在主线程或界面刷新路径上调用。
    /// 加载差异（含悬停预读）不会计算这些结果，只有本方法会；当前界面尚未使用它们，
    /// 留给日后的原生差异视图按需调用。
    func calculatingDiffRows() -> RepositoryDiffDocument {
        let result = TextDiffCalculator.calculate(originalText: originalText, modifiedText: modifiedText)

        var document = self
        document.rows = result.rows
        document.originalLines = result.originalLines
        document.modifiedLines = result.modifiedLines
        document.originalEndsWithoutNewline = result.originalEndsWithoutNewline
        document.modifiedEndsWithoutNewline = result.modifiedEndsWithoutNewline
        return document
    }

    // 等值只比较标识与两侧全文，不逐行比较 rows；是否已计算逐行对照结果不影响等值。
    static func == (lhs: RepositoryDiffDocument, rhs: RepositoryDiffDocument) -> Bool {
        lhs.repositoryPath == rhs.repositoryPath
            && lhs.filePath == rhs.filePath
            && lhs.mode == rhs.mode
            && lhs.originalText == rhs.originalText
            && lhs.modifiedText == rhs.modifiedText
            && lhs.languageHint == rhs.languageHint
    }
}

/// 差异行的种类。
enum RepositoryDiffRowKind: Equatable, Sendable {
    /// 两侧都有且未变更。
    case context
    /// 仅修改后有。
    case added
    /// 仅原文有。
    case removed
    /// 两侧都有且同一位置的内容发生了变化。
    case modified
}

/// 差异行中某一侧的一行。
struct RepositoryDiffLine: Equatable, Sendable {
    /// 不含行尾换行符；按 "\n" 切分，行内 "\r" 保留。
    let text: String
    /// 所在文件的行号，1 起。
    let lineNumber: Int
}

/// 一行对照结果。
struct RepositoryDiffRow: Equatable, Sendable {
    let kind: RepositoryDiffRowKind
    /// 并排时该侧无内容则为 nil（填充行）。
    let original: RepositoryDiffLine?
    let modified: RepositoryDiffLine?
    /// 仅 .modified 行有意义；行内发生变化的字符区间，UTF-16 偏移，相对该侧 text，升序且互不重叠。
    let originalChangedRanges: [Range<Int>]
    let modifiedChangedRanges: [Range<Int>]
}
/// 网页差异视图的输入载荷；保留到网页视图被原生视图替换为止。
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
