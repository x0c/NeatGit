import Foundation
import Synchronization

/// 文本差异计算器：输入两侧全文，输出逐行对照结果与行内高亮区间。
///
/// 纯计算，只依赖 Foundation：不启动进程、不读写文件。输入就是两侧全文，
/// 计算时不再需要任何 Git 进程。由加载差异的后台任务经
/// `RepositoryDiffDocument.calculatingDiffRows()` 调用，主线程不做差异计算。
///
/// - 行级：Myers（线性空间的中点分割版本，与 git 默认差异同族）。先剔除公共前后缀，
///   只对中段求差异；中段带编辑距离预算，超预算的段落降级为「先全部删除、后全部新增」。
/// - 行内：只对 `.modified` 行逐行做字符级差异；超长行只标公共前后缀之间的整段。
enum TextDiffCalculator {

    /// 计算参数。
    struct Options: Sendable {
        /// 行级编辑距离预算：中段差异的编辑距离超过它时，该段降级为「先全删后全增」。
        /// 任何输入都能在有限时间内返回；内存占用与行数成正比，不随预算增长。
        var editDistanceBudget = 20_000
        /// 行级匹配的总搜索步数上限（按对角线访问次数与蛇的步数计）。超过后其余需要搜索的段落
        /// 不再搜索，降级为「先全删后全增」。这是真正的耗时上限，不随文件大小增长。
        ///
        /// 取 3,000 万的依据：1 万行、约 3 千行集中改动的各种形态实测消耗 230 万到 1,350 万步，
        /// 留有一倍余量且不降级；调试构建下每步约 18 纳秒，预算耗尽的最坏耗时约 0.55 秒。
        var lineSearchBudget = 30_000_000
        /// 行内差异只处理不超过这个字符数的行；超长行只标公共前后缀之间的整段。
        var inlineLineLengthLimit = 2_000
        /// 单行字符级差异的编辑距离预算（真实距离），超过则该行只标公共前后缀之间的整段。
        /// 取 4,000 是因为单行上限 2,000 字符时距离最多 4,000，即长度上限内的行总是算到底，
        /// 真正兜底耗时的是下面的总工作量上限。
        var inlineEditDistanceBudget = 4_000
        /// 整份文档行内字符级差异的总工作量上限（按搜索步数计），超过后其余改动行只标整段。
        var inlineWorkBudget = 20_000_000
        /// 改动块内「删除行 × 新增行」配对比较的总次数上限；超过后其余改动块不配对，
        /// 直接输出为先删除、后新增。
        var pairingBudget = 50_000
        /// 单个改动块参与配对比较的「删除行数 × 新增行数」上限，超过则该块不配对。
        var pairingBlockLimit = 1_024
        /// 两行被判为一处改动的相似度阈值（0 到 1）。
        var pairingThreshold = 0.5
        /// 行内区间是否把相邻、或只隔一个未变字符的区间合并成一段。
        var mergeSingleCharacterGaps = true

        init() {}
    }

    /// 计算结果。
    struct Result: Sendable {
        /// 逐行对照结果。
        var rows: [RepositoryDiffRow]
        var originalLines: Int
        var modifiedLines: Int
        var originalEndsWithoutNewline: Bool
        var modifiedEndsWithoutNewline: Bool
        /// 是否有段落因超出编辑距离预算而降级为「先全删后全增」。
        var didFallBack: Bool
    }

    /// 一段连续匹配：`a[aStart..<aEnd]` 与 `b[bStart..<bEnd]` 逐项相等。
    struct MatchedRun {
        var aStart: Int
        var aEnd: Int
        var bStart: Int
        var bEnd: Int
    }

    /// 行级匹配结果。
    struct Matching: Sendable {
        /// 按 `aStart` 升序。
        var runs: [MatchedRun]
        var exceededBudget: Bool
    }

    /// 进程内累计的 `calculate` 调用次数，只供测试证明某条路径有没有触发差异计算，不参与业务判断。
    private static let calculationCount = Mutex<Int>(0)
    /// 其中发生在主线程上的次数，只供测试证明差异计算没有落在主线程，不参与业务判断。
    private static let mainThreadCalculationCount = Mutex<Int>(0)

    /// 累计计算次数（测试观测用）。
    static var recordedCalculationCount: Int {
        calculationCount.withLock { $0 }
    }

    /// 其中发生在主线程上的次数（测试观测用）。
    static var recordedMainThreadCalculationCount: Int {
        mainThreadCalculationCount.withLock { $0 }
    }

    /// 把累计计算次数清零（测试观测用）。
    static func resetRecordedCalculationCount() {
        calculationCount.withLock { $0 = 0 }
        mainThreadCalculationCount.withLock { $0 = 0 }
    }

    /// 把两侧全文切分成行并计算差异。
    static func calculate(originalText: String, modifiedText: String, options: Options = Options()) -> Result {
        calculationCount.withLock { $0 += 1 }
        if Thread.isMainThread {
            mainThreadCalculationCount.withLock { $0 += 1 }
        }

        let originalLines = splitLines(originalText)
        let modifiedLines = splitLines(modifiedText)

        // 两侧共用一张编号表：编号相同当且仅当内容相同。
        var lineIDs: [String: Int] = [:]
        let originalIDs = intern(originalLines, into: &lineIDs)
        let modifiedIDs = intern(modifiedLines, into: &lineIDs)

        var lineWork = 0
        let matching = originalIDs.withUnsafeBufferPointer { originalBuffer in
            modifiedIDs.withUnsafeBufferPointer { modifiedBuffer in
                lineMatching(
                    a: originalBuffer,
                    b: modifiedBuffer,
                    budget: options.editDistanceBudget,
                    workBudget: options.lineSearchBudget,
                    work: &lineWork
                )
            }
        }

        var pairingBudget = options.pairingBudget
        var inlineWork = 0
        let rows = makeRows(
            original: originalLines,
            modified: modifiedLines,
            matching: matching,
            options: options,
            pairingBudget: &pairingBudget,
            inlineWork: &inlineWork
        )

        return Result(
            rows: rows,
            originalLines: originalLines.count,
            modifiedLines: modifiedLines.count,
            originalEndsWithoutNewline: Self.lacksTrailingNewline(originalText),
            modifiedEndsWithoutNewline: Self.lacksTrailingNewline(modifiedText),
            didFallBack: matching.exceededBudget
        )
    }

    /// 按 "\n" 切分；行内 "\r" 保留；末尾换行符不产生空行；空文本得到 0 行。
    ///
    /// 含 "\r\n" 时按字符逐个走：Swift 把 "\r\n" 当成一个字符，直接按 "\n" 切会整份切不开。
    static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }

        var lines: [String]
        if text.range(of: "\r\n") == nil {
            lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if text.hasSuffix("\n") {
                lines.removeLast()
            }
        } else {
            lines = []
            var start = text.startIndex
            var index = text.startIndex
            while index < text.endIndex {
                let next = text.index(after: index)
                let character = text[index]
                if character == "\n" || character == "\r\n" {
                    let ending = character == "\r\n" ? "\r" : ""
                    lines.append(String(text[start..<index]) + ending)
                    start = next
                }
                index = next
            }
            if start < text.endIndex {
                lines.append(String(text[start...]))
            }
        }

        return lines
    }

    /// 文本非空且末尾没有换行符；`"\r\n"` 也算换行符，与切行的口径一致。
    static func lacksTrailingNewline(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        // `hasSuffix` 按字符比较，而 "\r\n" 是一个字符，所以两种写法都要看。
        return !text.hasSuffix("\n") && !text.hasSuffix("\r\n")
    }

    /// 把每一项映射成整数编号，后续比较只比编号，避免反复比较内容。
    /// 两段序列写入同一张编号表时，内容相同的项才会得到相同的编号。
    static func intern<Item: Hashable, Items: Collection>(_ items: Items, into ids: inout [Item: Int]) -> [Int] where Items.Element == Item {
        var result: [Int] = []
        result.reserveCapacity(items.count)

        for item in items {
            if let id = ids[item] {
                result.append(id)
            } else {
                let id = ids.count
                ids[item] = id
                result.append(id)
            }
        }

        return result
    }

    // MARK: - 行级 Myers

    /// 求两段序列的最长匹配（中点分割的 Myers，线性空间）。
    ///
    /// 未匹配的下标即改动行。编辑距离超过 `budget`、或累计搜索步数达到 `workBudget` 的段落
    /// 不求匹配，由 `exceededBudget` 标出。
    static func lineMatching(
        a: UnsafeBufferPointer<Int>,
        b: UnsafeBufferPointer<Int>,
        budget: Int,
        workBudget: Int,
        work: inout Int
    ) -> Matching {
        guard a.count > 0, b.count > 0 else {
            return Matching(runs: [], exceededBudget: false)
        }
        // 预算为 0 时不直接判降级：循环里会先剔除公共前后缀，只剩真正需要搜索的段落才算降级。

        // 搜索深度最多是编辑距离的一半；数组宽度按最坏情况分配，一次分配、全程复用。
        let limit = min((a.count + b.count + 1) / 2, (budget + 1) / 2)
        let width = 2 * limit + 5
        var forward = [Int](repeating: 0, count: width)
        var backward = [Int](repeating: 0, count: width)

        return forward.withUnsafeMutableBufferPointer { forwardBuffer in
            backward.withUnsafeMutableBufferPointer { backwardBuffer in
                var runs: [MatchedRun] = []
                var exceeded = false
                var pending: [Pending] = [Pending(aStart: 0, aEnd: a.count, bStart: 0, bEnd: b.count, budget: budget)]

                while let piece = pending.popLast() {
                    var aStart = piece.aStart
                    var aEnd = piece.aEnd
                    var bStart = piece.bStart
                    var bEnd = piece.bEnd

                    // 公共前缀与公共后缀直接算匹配，只对中段搜索。
                    while aStart < aEnd, bStart < bEnd, a[aStart] == b[bStart] {
                        aStart += 1
                        bStart += 1
                    }
                    if aStart > piece.aStart {
                        runs.append(MatchedRun(aStart: piece.aStart, aEnd: aStart, bStart: piece.bStart, bEnd: bStart))
                    }

                    while aEnd > aStart, bEnd > bStart, a[aEnd - 1] == b[bEnd - 1] {
                        aEnd -= 1
                        bEnd -= 1
                    }
                    if aEnd < piece.aEnd {
                        runs.append(MatchedRun(aStart: aEnd, aEnd: piece.aEnd, bStart: bEnd, bEnd: piece.bEnd))
                    }

                    // 一侧为空：整段是增删，不需要搜索。
                    if aStart == aEnd || bStart == bEnd || piece.budget <= 0 {
                        if aStart < aEnd, bStart < bEnd {
                            exceeded = true
                        }
                        continue
                    }

                    // 总步数用尽：其余段落一律降级，保证任何输入都能在有限时间内返回。
                    guard work < workBudget else {
                        exceeded = true
                        continue
                    }
                    let searchBudget = piece.budget
                    guard let snake = findMiddleSnake(
                        a: a,
                        b: b,
                        aStart: aStart,
                        aEnd: aEnd,
                        bStart: bStart,
                        bEnd: bEnd,
                        budget: searchBudget,
                        workBudget: workBudget,
                        forward: forwardBuffer.baseAddress!,
                        backward: backwardBuffer.baseAddress!,
                        offset: limit + 2,
                        work: &work
                    ) else {
                        // 超预算：整段降级为「先全删后全增」。
                        exceeded = true
                        continue
                    }

                    // 蛇本身不含编辑，最优路径在蛇处分开：前半段的编辑数是「距离 + 1」的一半，后半段是「距离」的一半。
                    // 按这两个份额下发预算，子段预算一定不小于父段，暂存数组宽度也就一定够用。
                    // 长度差为偶数时蛇可能为空（例如一行换成另一行），此时按相遇点分割。
                    let leftBudget = (snake.distance + 1) / 2
                    let rightBudget = snake.distance / 2
                    let isEmptySnake = snake.aStart == snake.aEnd
                    let meetsStart = snake.aStart == aStart && snake.bStart == bStart
                    let meetsEnd = snake.aEnd == aEnd && snake.bEnd == bEnd
                    guard !(isEmptySnake && (meetsStart || meetsEnd)) else {
                        // 相遇点落在段的首尾角，分不出更小的段：整段降级为「先全删后全增」。
                        exceeded = true
                        continue
                    }
                    if !isEmptySnake {
                        runs.append(MatchedRun(aStart: snake.aStart, aEnd: snake.aEnd, bStart: snake.bStart, bEnd: snake.bEnd))
                    }
                    pending.append(Pending(aStart: snake.aEnd, aEnd: aEnd, bStart: snake.bEnd, bEnd: bEnd, budget: rightBudget))
                    pending.append(Pending(aStart: aStart, aEnd: snake.aStart, bStart: bStart, bEnd: snake.bStart, budget: leftBudget))
                }

                runs.sort { $0.aStart < $1.aStart }
                return Matching(runs: runs, exceededBudget: exceeded)
            }
        }
    }

    /// 待处理的子段。
    private struct Pending {
        var aStart: Int
        var aEnd: Int
        var bStart: Int
        var bEnd: Int
        var budget: Int
    }

    /// 搜索一段的中点蛇：正向与反向各推进一步，相遇即得到把编辑路径从中分开的蛇。
    ///
    /// `forward` / `backward` 是复用的暂存数组，下标为 `对角线 + offset`。
    /// 返回值的 `distance` 是本段的真实编辑距离；超过 `budget` 或累计步数超过 `workBudget` 返回 nil。
    static func findMiddleSnake(
        a: UnsafeBufferPointer<Int>,
        b: UnsafeBufferPointer<Int>,
        aStart: Int,
        aEnd: Int,
        bStart: Int,
        bEnd: Int,
        budget: Int,
        workBudget: Int,
        forward: UnsafeMutablePointer<Int>,
        backward: UnsafeMutablePointer<Int>,
        offset: Int,
        work: inout Int
    ) -> (distance: Int, aStart: Int, aEnd: Int, bStart: Int, bEnd: Int)? {
        let n = aEnd - aStart
        let m = bEnd - bStart
        let delta = n - m
        let deltaIsOdd = (delta & 1) != 0
        let limit = min((n + m + 1) / 2, (budget + 1) / 2)

        forward[offset + 1] = 0
        backward[offset + 1] = 0

        var d = 0
        while d <= limit {
            // 正向：从段首出发，x 为在 a 中到达的下标。
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && forward[offset + k - 1] < forward[offset + k + 1]) {
                    x = forward[offset + k + 1]
                } else {
                    x = forward[offset + k - 1] + 1
                }
                var y = x - k
                let snakeStartX = x
                while x < n, y < m, a[aStart + x] == b[bStart + y] {
                    x += 1
                    y += 1
                }
                forward[offset + k] = x
                // 蛇走过的每一步也是工作量，必须计入，否则长公共段会让耗时失去上限。
                work += x - snakeStartX

                // 与上一轮反向搜索相遇：中间蛇就是刚走完的这条。
                if deltaIsOdd, abs(delta - k) < d, x + backward[offset + delta - k] >= n {
                    return (2 * d - 1, aStart + snakeStartX, aStart + x, bStart + snakeStartX - k, bStart + x - k)
                }
                k += 2
            }

            // 反向：从段尾出发，xr 为在 a 中距段尾的下标。
            var reverseDiagonal = -d
            while reverseDiagonal <= d {
                let k = delta - reverseDiagonal
                var x: Int
                if reverseDiagonal == -d
                    || (reverseDiagonal != d && backward[offset + reverseDiagonal - 1] < backward[offset + reverseDiagonal + 1])
                {
                    x = backward[offset + reverseDiagonal + 1]
                } else {
                    x = backward[offset + reverseDiagonal - 1] + 1
                }
                var y = x - reverseDiagonal
                let snakeStartX = x
                while x < n, y < m, a[aEnd - 1 - x] == b[bEnd - 1 - y] {
                    x += 1
                    y += 1
                }
                backward[offset + reverseDiagonal] = x
                work += x - snakeStartX

                // 与本轮正向搜索相遇：中间蛇是刚走完的这条（换回正向坐标）。
                if !deltaIsOdd, abs(k) <= d, forward[offset + k] + x >= n {
                    // 搜索深度按「预算 + 1」的一半取整，偶数距离可能刚好超出一格，这里按真实距离把关。
                    guard 2 * d <= budget else {
                        return nil
                    }
                    return (
                        2 * d,
                        aEnd - x,
                        aEnd - snakeStartX,
                        bEnd - y,
                        bEnd - (snakeStartX - reverseDiagonal)
                    )
                }
                reverseDiagonal += 2
            }

            // 每轮正反向各走 d + 1 条对角线。
            work += 2 * (d + 1)
            if work > workBudget {
                return nil
            }
            d += 1
        }

        return nil
    }

    // MARK: - 组装差异行

    static func makeRows(
        original: [String],
        modified: [String],
        matching: Matching,
        options: Options,
        pairingBudget: inout Int,
        inlineWork: inout Int
    ) -> [RepositoryDiffRow] {
        var rows: [RepositoryDiffRow] = []
        rows.reserveCapacity(max(original.count, modified.count) + 16)

        var originalIndex = 0
        var modifiedIndex = 0
        for run in matching.runs {
            appendChangeBlock(
                to: &rows,
                original: original[originalIndex..<run.aStart].map { $0[...] },
                modified: modified[modifiedIndex..<run.bStart].map { $0[...] },
                originalStart: originalIndex,
                modifiedStart: modifiedIndex,
                options: options,
                pairingBudget: &pairingBudget,
                inlineWork: &inlineWork
            )

            for offset in 0..<(run.aEnd - run.aStart) {
                let a = run.aStart + offset
                let b = run.bStart + offset
                rows.append(RepositoryDiffRow(
                    kind: .context,
                    original: RepositoryDiffLine(text: String(original[a]), lineNumber: a + 1),
                    modified: RepositoryDiffLine(text: String(modified[b]), lineNumber: b + 1),
                    originalChangedRanges: [],
                    modifiedChangedRanges: []
                ))
            }

            originalIndex = run.aEnd
            modifiedIndex = run.bEnd
        }

        appendChangeBlock(
            to: &rows,
            original: original[originalIndex..<original.count].map { $0[...] },
            modified: modified[modifiedIndex..<modified.count].map { $0[...] },
            originalStart: originalIndex,
            modifiedStart: modifiedIndex,
            options: options,
            pairingBudget: &pairingBudget,
            inlineWork: &inlineWork
        )

        return rows
    }


    /// 输出一个改动块：原文侧与修改侧都非空时，按相似度把「同一处修改前后」的两行配成 `.modified`。
    ///
    /// 配对必须保持两侧顺序（同侧行号严格递增）；未配对的行输出为 `.removed` / `.added`。
    /// 不配对时输出为先全部删除、后全部新增。
    /// - Parameters:
    ///   - original: 改动块里原文侧的行，下标从 0 起。
    ///   - modified: 改动块里修改侧的行，下标从 0 起。
    ///   - originalStart / modifiedStart: 改动块第一行在各自文件里的下标（行号从 1 起，所以要加 1）。
    static func appendChangeBlock(
        to rows: inout [RepositoryDiffRow],
        original: [Substring],
        modified: [Substring],
        originalStart: Int,
        modifiedStart: Int,
        options: Options,
        pairingBudget: inout Int,
        inlineWork: inout Int
    ) {
        let pairs = pairChangeBlock(original: original, modified: modified, options: options, pairingBudget: &pairingBudget)

        func appendRemoved(_ index: Int) {
            rows.append(RepositoryDiffRow(
                kind: .removed,
                original: RepositoryDiffLine(text: String(original[index]), lineNumber: originalStart + index + 1),
                modified: nil,
                originalChangedRanges: [],
                modifiedChangedRanges: []
            ))
        }

        func appendAdded(_ index: Int) {
            rows.append(RepositoryDiffRow(
                kind: .added,
                original: nil,
                modified: RepositoryDiffLine(text: String(modified[index]), lineNumber: modifiedStart + index + 1),
                originalChangedRanges: [],
                modifiedChangedRanges: []
            ))
        }

        func appendPaired(_ originalIndex: Int, _ modifiedIndex: Int) {
            let originalLine = original[originalIndex]
            let modifiedLine = modified[modifiedIndex]
            var ranges: (original: [Range<Int>], modified: [Range<Int>]) = ([], [])
            // 降级段落里两侧可能存在完全相同的行，按未变更处理。
            let kind: RepositoryDiffRowKind = originalLine == modifiedLine ? .context : .modified
            if kind == .modified {
                ranges = inlineChangedRanges(
                    original: originalLine,
                    modified: modifiedLine,
                    options: options,
                    work: &inlineWork
                )
            }

            rows.append(RepositoryDiffRow(
                kind: kind,
                original: RepositoryDiffLine(text: String(originalLine), lineNumber: originalStart + originalIndex + 1),
                modified: RepositoryDiffLine(text: String(modifiedLine), lineNumber: modifiedStart + modifiedIndex + 1),
                originalChangedRanges: ranges.original,
                modifiedChangedRanges: ranges.modified
            ))
        }

        // 空数组表示不配对。
        guard !pairs.isEmpty else {
            for index in original.indices {
                appendRemoved(index)
            }
            for index in modified.indices {
                appendAdded(index)
            }
            return
        }

        let pairedOriginals = Set(pairs.compactMap { $0 })
        var a = 0
        var b = 0

        while a < original.count || b < modified.count {
            if a < original.count, !pairedOriginals.contains(a) {
                appendRemoved(a)
                a += 1
            } else if b < modified.count, pairs[b] == nil {
                appendAdded(b)
                b += 1
            } else if a < original.count, b < modified.count {
                appendPaired(a, b)
                a += 1
                b += 1
            } else {
                // 配对信息与行范围不一致时按增删兜底，保证两侧行都能输出。
                if a < original.count {
                    appendRemoved(a)
                    a += 1
                }
                if b < modified.count {
                    appendAdded(b)
                    b += 1
                }
            }
        }
    }

    /// 改动块内的配对：返回修改侧每一行配对的原文下标（从 0 起；nil 表示未配对）；空数组表示不配对。
    ///
    /// 在「保持顺序」的前提下选总相似度最高的配对方案（序列比对动态规划）。
    static func pairChangeBlock(
        original: [Substring],
        modified: [Substring],
        options: Options,
        pairingBudget: inout Int
    ) -> [Int?] {
        let removedCount = original.count
        let addedCount = modified.count
        let comparisons = removedCount * addedCount
        guard removedCount > 0, addedCount > 0, comparisons <= options.pairingBlockLimit, pairingBudget >= comparisons else {
            return []
        }
        pairingBudget -= comparisons

        let cap = options.inlineLineLengthLimit
        var scores = [Double](repeating: 0, count: comparisons)
        for i in 0..<removedCount {
            for j in 0..<addedCount {
                scores[i * addedCount + j] = similarity(
                    original[i],
                    modified[j],
                    cap: cap
                )
            }
        }

        // 0 跳过一行原文，1 跳过一行修改，2 配成一处改动。
        let stride = addedCount + 1
        var best = [Double](repeating: 0, count: (removedCount + 1) * stride)
        var moves = [UInt8](repeating: 0, count: comparisons)
        for i in 1...removedCount {
            for j in 1...addedCount {
                let skipOriginal = best[(i - 1) * stride + j]
                let skipModified = best[i * stride + j - 1]
                var value = skipOriginal
                var move: UInt8 = 0
                if skipModified > value {
                    value = skipModified
                    move = 1
                }

                let score = scores[(i - 1) * addedCount + (j - 1)]
                if score >= options.pairingThreshold, best[(i - 1) * stride + j - 1] + score >= value {
                    value = best[(i - 1) * stride + j - 1] + score
                    move = 2
                }

                best[i * stride + j] = value
                moves[(i - 1) * addedCount + (j - 1)] = move
            }
        }

        var pairs = [Int?](repeating: nil, count: addedCount)
        var i = removedCount
        var j = addedCount
        while i > 0, j > 0 {
            switch moves[(i - 1) * addedCount + (j - 1)] {
            case 0:
                i -= 1
            case 1:
                j -= 1
            default:
                pairs[j - 1] = i - 1
                i -= 1
                j -= 1
            }
        }

        return pairs
    }

    /// 两行的相似度（0 到 1）：公共前后缀占两行总长度的比例，与字符构成重合度，取较大值。
    /// 前后缀各最多比较 `cap` 个 UTF-16 单元。
    ///
    /// 按 Unicode 标量逐个前进 / 后退比较：不用 `String.UTF16View` 的下标运算，
    /// 该视图在增补平面字符（如 emoji）上前后移动时下标不对齐，会越界。
    static func similarity(_ a: Substring, _ b: Substring, cap: Int) -> Double {
        let aLength = a.utf16.count
        let bLength = b.utf16.count
        guard aLength > 0, bLength > 0 else { return 0 }

        var aForward = a.unicodeScalars.makeIterator()
        var bForward = b.unicodeScalars.makeIterator()
        var aPrefix = 0
        var bPrefix = 0
        while aPrefix < cap, bPrefix < cap, let x = aForward.next(), let y = bForward.next(), x == y {
            aPrefix += Self.utf16Width(x)
            bPrefix += Self.utf16Width(y)
        }

        var aBackward = a.unicodeScalars.reversed().makeIterator()
        var bBackward = b.unicodeScalars.reversed().makeIterator()
        var aSuffix = 0
        var bSuffix = 0
        while aSuffix < min(cap, aLength - aPrefix), bSuffix < min(cap, bLength - bPrefix),
              let x = aBackward.next(), let y = bBackward.next(), x == y
        {
            aSuffix += Self.utf16Width(x)
            bSuffix += Self.utf16Width(y)
        }

        let affixRatio = Double(aPrefix + aSuffix + bPrefix + bSuffix) / Double(aLength + bLength)
        guard affixRatio < 1 else { return 1 }

        // 一行里相隔较远的两处小改动，公共前后缀占比很低（例如 aXbcdefgYh → aQbcdefgZh 只有 0.2）。
        // 再比一下字符构成的重合度作为补充；只看前 256 个字符，保证比较次数有上限。
        let overlapLimit = 256
        var counts: [Character: Int] = [:]
        var countedA = 0
        for character in a {
            guard countedA < overlapLimit else { break }
            counts[character, default: 0] += 1
            countedA += 1
        }
        var shared = 0
        var countedB = 0
        for character in b {
            guard countedB < overlapLimit else { break }
            if let remaining = counts[character], remaining > 0 {
                counts[character] = remaining - 1
                shared += 1
            }
            countedB += 1
        }
        let overlapRatio = Double(2 * shared) / Double(countedA + countedB)
        return max(affixRatio, overlapRatio)
    }

    /// 一个 Unicode 标量占用的 UTF-16 单元数。
    static func utf16Width(_ scalar: Unicode.Scalar) -> Int {
        scalar.value > 0xFFFF ? 2 : 1
    }

    // MARK: - 行内高亮

    /// 一对改动行的行内变化区间（UTF-16 偏移，相对各自文本，升序且互不重叠）。
    ///
    /// 先剔除公共前后缀，再对剩余中段做字符级差异；超过单行字符数上限或工作量用尽时，
    /// 只把公共前后缀之间的整段标为变化。
    static func inlineChangedRanges(
        original: Substring,
        modified: Substring,
        options: Options,
        work: inout Int
    ) -> (original: [Range<Int>], modified: [Range<Int>]) {
        guard options.inlineLineLengthLimit > 0,
              max(original.count, modified.count) <= options.inlineLineLengthLimit
        else {
            return wholeMiddleRanges(original: original, modified: modified)
        }

        let originalCharacters = Array(original)
        let modifiedCharacters = Array(modified)

        // 以字符（字素簇）为单位，保证高亮边界能落在可渲染的位置上。
        var prefix = 0
        while prefix < min(originalCharacters.count, modifiedCharacters.count),
              originalCharacters[prefix] == modifiedCharacters[prefix]
        {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(originalCharacters.count, modifiedCharacters.count) - prefix,
              originalCharacters[originalCharacters.count - 1 - suffix] == modifiedCharacters[modifiedCharacters.count - 1 - suffix]
        {
            suffix += 1
        }

        let originalMiddle = originalCharacters[prefix..<(originalCharacters.count - suffix)]
        let modifiedMiddle = modifiedCharacters[prefix..<(modifiedCharacters.count - suffix)]

        // 中段一侧为空，或预算 / 总工作量不足：只标整段。
        guard !originalMiddle.isEmpty, !modifiedMiddle.isEmpty,
              options.inlineEditDistanceBudget > 0, work < options.inlineWorkBudget
        else {
            return wholeMiddleRanges(original: original, modified: modified)
        }

        var ids: [Character: Int] = [:]
        let originalIDs = intern(originalMiddle, into: &ids)
        let modifiedIDs = intern(modifiedMiddle, into: &ids)
        let matching = originalIDs.withUnsafeBufferPointer { originalBuffer in
            modifiedIDs.withUnsafeBufferPointer { modifiedBuffer in
                lineMatching(
                    a: originalBuffer,
                    b: modifiedBuffer,
                    budget: options.inlineEditDistanceBudget,
                    // 行内只能用整份文档剩余的行内工作量，用尽后本行按整段标出。
                    workBudget: options.inlineWorkBudget - work,
                    work: &work
                )
            }
        }
        // 本行搜索超预算或工作量用尽：同样只标整段，保证两侧剩余文本仍然相等。
        if matching.exceededBudget {
            return wholeMiddleRanges(original: original, modified: modified)
        }

        let originalOffsets = utf16Offsets(of: originalCharacters)
        let modifiedOffsets = utf16Offsets(of: modifiedCharacters)
        // 长度不超过 1 的匹配段，只要两侧各有相邻的变化段可并，就并入变化：必须按匹配段统一决定、两侧同时生效。
        // 如果只在某一侧按「相邻就合并」处理，另一侧可能因为前后没有区间而保留该字符，两侧剩余文本就不相等了。
        var absorbedRuns = Set<Int>()
        if options.mergeSingleCharacterGaps {
            let lastRunIndex = matching.runs.count - 1
            for (index, run) in matching.runs.enumerated() where run.aEnd - run.aStart <= 1 {
                // 前面（或后面）还有别的匹配段，或者任一侧在它前面（或后面）还有未匹配的字符，才算有相邻的变化段。
                let hasChangeBefore = index > 0 || run.aStart > 0 || run.bStart > 0
                let hasChangeAfter = index < lastRunIndex || run.aEnd < originalMiddle.count || run.bEnd < modifiedMiddle.count
                if hasChangeBefore, hasChangeAfter {
                    absorbedRuns.insert(index)
                }
            }
        }
        let originalRanges = changedCharacterRanges(
            matching: matching, count: originalMiddle.count, start: \.aStart, end: \.aEnd, absorbedRuns: absorbedRuns
        )
        let modifiedRanges = changedCharacterRanges(
            matching: matching, count: modifiedMiddle.count, start: \.bStart, end: \.bEnd, absorbedRuns: absorbedRuns
        )
        return (
            originalRanges.map { (originalOffsets[prefix + $0.lowerBound])..<(originalOffsets[prefix + $0.upperBound]) },
            modifiedRanges.map { (modifiedOffsets[prefix + $0.lowerBound])..<(modifiedOffsets[prefix + $0.upperBound]) }
        )
    }

    /// 超长行：不建字符数组，直接按字符统计公共前后缀，只标中间整段。
    static func wholeMiddleRanges(original: Substring, modified: Substring) -> (original: [Range<Int>], modified: [Range<Int>]) {
        var originalIterator = original.makeIterator()
        var modifiedIterator = modified.makeIterator()
        var originalPrefix = 0
        var modifiedPrefix = 0
        var prefixCharacters = 0
        var modifiedPrefixCharacters = 0
        while let a = originalIterator.next(), let b = modifiedIterator.next(), a == b {
            originalPrefix += a.utf16.count
            modifiedPrefix += b.utf16.count
            prefixCharacters += 1
            modifiedPrefixCharacters += 1
        }

        var originalSuffix = 0
        var modifiedSuffix = 0
        var suffixCharacters = 0
        var originalReverse = original.reversed().makeIterator()
        var modifiedReverse = modified.reversed().makeIterator()
        let originalLimit = original.count - prefixCharacters
        let modifiedLimit = modified.count - modifiedPrefixCharacters
        while suffixCharacters < originalLimit, suffixCharacters < modifiedLimit,
              let a = originalReverse.next(), let b = modifiedReverse.next(), a == b
        {
            originalSuffix += a.utf16.count
            modifiedSuffix += b.utf16.count
            suffixCharacters += 1
        }

        // 区间终点是「该侧总 UTF-16 长度 − 公共后缀长度」，不是「前缀 + 后缀」：
        // 后缀从行尾起算，中间隔着真正变化的内容。
        let originalLength = original.utf16.count
        let modifiedLength = modified.utf16.count
        let originalEnd = originalLength - originalSuffix
        let modifiedEnd = modifiedLength - modifiedSuffix
        return (
            originalPrefix < originalEnd ? [originalPrefix..<originalEnd] : [],
            modifiedPrefix < modifiedEnd ? [modifiedPrefix..<modifiedEnd] : []
        )
    }

    /// 每个字符起始位置的 UTF-16 偏移，末尾附带总长度。
    static func utf16Offsets(of characters: [Character]) -> [Int] {
        var offsets = [Int](repeating: 0, count: characters.count + 1)
        for (index, character) in characters.enumerated() {
            offsets[index + 1] = offsets[index] + character.utf16.count
        }

        return offsets
    }

    /// 一侧中段里「算作变化」的字符下标区间：未匹配的字符，加上被并入变化的匹配段。
    ///
    /// 区间非空、升序、互不重叠；两侧用同一份 `absorbedRuns`，所以去掉区间后两侧剩余文本相同。
    static func changedCharacterRanges(
        matching: Matching,
        count: Int,
        start: (MatchedRun) -> Int,
        end: (MatchedRun) -> Int,
        absorbedRuns: Set<Int>
    ) -> [Range<Int>] {
        var changed = [Bool](repeating: true, count: count)
        for (index, run) in matching.runs.enumerated() where !absorbedRuns.contains(index) {
            guard run.aEnd >= run.aStart, run.bEnd >= run.bStart, run.aEnd - run.aStart == run.bEnd - run.bStart else { continue }
            let lower = max(start(run), 0)
            let upper = min(end(run), count)
            guard lower <= upper else { continue }
            for position in lower..<upper {
                changed[position] = false
            }
        }

        var ranges: [Range<Int>] = []
        var rangeStart: Int?
        for (position, isChanged) in changed.enumerated() {
            if isChanged {
                if rangeStart == nil { rangeStart = position }
            } else if let start = rangeStart {
                ranges.append(start..<position)
                rangeStart = nil
            }
        }
        if let start = rangeStart {
            ranges.append(start..<changed.count)
        }
        return ranges
    }
}
