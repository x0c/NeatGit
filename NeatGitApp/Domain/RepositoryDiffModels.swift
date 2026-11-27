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
    /// 本次加载内容的稳定身份。渲染协调器用它比较版本，避免反复比较两侧全文。
    let renderingID: UUID

    // 以下为原生差异视图准备的逐行对照结果，由加载差异的后台任务（含悬停预读）算好，
    // 加载完成的文档总带有完整的 rows。
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

    init(
        repositoryPath: String,
        filePath: String,
        mode: RepositoryDiffMode,
        originalText: String,
        modifiedText: String,
        languageHint: String?,
        renderingID: UUID = UUID(),
        rows: [RepositoryDiffRow] = [],
        originalLines: Int = 0,
        modifiedLines: Int = 0,
        originalEndsWithoutNewline: Bool = false,
        modifiedEndsWithoutNewline: Bool = false
    ) {
        self.repositoryPath = repositoryPath
        self.filePath = filePath
        self.mode = mode
        self.originalText = originalText
        self.modifiedText = modifiedText
        self.languageHint = languageHint
        self.renderingID = renderingID
        self.rows = rows
        self.originalLines = originalLines
        self.modifiedLines = modifiedLines
        self.originalEndsWithoutNewline = originalEndsWithoutNewline
        self.modifiedEndsWithoutNewline = modifiedEndsWithoutNewline
    }

    /// 重新计算逐行对照结果，返回补全了 `rows`、两侧行数与末尾缺换行符标记的新文档；自身不变。
    ///
    /// 正常流程不需要调用：加载差异时已经在后台算好。这是耗时操作：耗时随两侧全文行数增长
    /// （有预算上限，但大文件仍可能需要上百毫秒到秒级），必须在后台线程调用，
    /// 不要在主线程或界面刷新路径上调用。
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
