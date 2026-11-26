# 开源 / 原生 diff 实现调研（competitors-native-oss）

调研日期：2026-11-26。源码均为本次 `git clone --depth 1` 到 `/tmp/swarm/oss/` 后只读查看；star、许可证、语言构成、pushed 时间取自 GitHub API（`gh api repos/<owner>/<repo>`）。

## 一、结论

1. **没有可直接拿来用的 Swift diff 视图组件**【已验证】。GitHub 上按 star 排序的 Swift「diff」项目全是集合差分算法库（DifferenceKit 3666★、DeepDiff 2020★、Dwifft 1843★，均不做文本 diff 展示）；独立的 Swift「git diff viewer」全部 ≤4★。所有成熟实现都长在各自 App 内部，没有拆成包。
2. **原生渲染路线已有多个可运行先例，最值得借鉴的是 foldgit（MIT）和 Maple（MIT）**【已验证】。两者都是：调 `git diff` 命令 → 自己解析文本 → 纯 SwiftUI / AppKit 渲染，零 WebView。
3. **最成熟的原生渲染是 GitUp，但它是 GPL-3.0 + Objective-C + libgit2**，代码不能直接并入 NeatGit，只能看思路【已验证】。
4. **Xit（Apache-2.0）证明「瘦身 Web 路线」可行**：同样用 WKWebView，整站 HTML/CSS/JS 合计约 32K【已验证，`du -sh Xit/html`】。
5. NeatGit 仓库根目前没有许可证文件【已验证】。要借鉴他人代码前需先定自己的许可证。

## 二、对比表

| 项目 | Star | 许可证 | 语言构成（GitHub 统计字节） | 最近提交 | diff 来源 | 渲染方式 | 并排 | 行内高亮 | 大文件策略 |
|---|---|---|---|---|---|---|---|---|---|
| [git-up/GitUp](https://github.com/git-up/GitUp) | 12175 | GPL-3.0 | ObjC 1.84M、Shell 6K、C 3K | 2026-10-08 | libgit2 | 自绘（CoreText `CTLineDraw`） | 有 | 有（公共前后缀字节扫描，仅等长的删/增行配对） | 文本 diff 上限 8MB，超过按二进制处理 |
| [Uncommon/Xit](https://github.com/Uncommon/Xit) | 1177 | Apache-2.0（COPYING；API 显示 NOASSERTION） | Swift 1.10M、CSS 4.9K、C 2.5K | 2026-04-07 | libgit2 | WKWebView + 极简 HTML | 未见（单栏 HTML） | 未见 | 未查到 |
| [gitx/gitx](https://github.com/gitx/gitx) | 920 | GPL-2.0（仅 v2） | ObjC 1.04M、CSS 112K、JS 67K、HTML 52K、Swift 12K | 2026-11-05 | git 命令 + objective-git | 旧式 WebView 注入 JS | 未查到 | 未查到 | 未查到 |
| [maoyama/Changes](https://github.com/maoyama/Changes) | 344 | MIT | Swift 306K | 2026-11-03 | git 命令 | SwiftUI `Text` + Sourceful 语法着色 | 无 | 无 | 未见专门处理 |
| [dufu1991/foldgit](https://github.com/dufu1991/foldgit) | 188 | MIT | Swift 1.52M、C# 270K（Windows 端）、Python 71K、JS 34K、HTML 133K | 2026-11-25 | git 命令（swift-subprocess） | SwiftUI `Text`；并排栏用 `NSTextView` | 有 | 有（词元级有界 LCS） | 超 80 个文件或 8000 行默认折叠 |
| [Commit-Plus/commit-plus](https://github.com/Commit-Plus/commit-plus) | 159 | AGPL-3.0 | Swift 7.66M、Shell 30K、Python 5.6K、HTML 9.6K | 2026-11-24 | git 命令 | AppKit，按 hunk 自绘（CoreText） | 未查到 | 未见（仅语法着色缓存） | 只绘制可见切片；按固定行高定位可见 hunk |
| [sanvibyfish/openowl-app](https://github.com/sanvibyfish/openowl-app) | 72 | GPL-3.0 | Swift 1.06M、Shell 17K | 2026-10-22 | git 命令 | SwiftUI `Text` | 明确不做（窄栏自动换行） | 未见 | 未跟踪文件数量上限 |
| [poolcamacho/Maple](https://github.com/poolcamacho/Maple) | 57 | MIT | Swift 252K | 2026-07-28 | git 命令 | SwiftUI `Text`（ScrollView + LazyVStack） | 无 | 无 | 无；二进制文件有占位态 |
| [michaelneale/swifty-diff](https://github.com/michaelneale/swifty-diff) | 4 | 无许可证文件 | HTML 133K、Swift 54K、Shell 5K | 2025-11-12 | git 命令 | SwiftUI `Text` | 有（两栏同处一个滚动容器） | 无 | 未见 |
| [davidfstr/git-visual-compare](https://github.com/davidfstr/git-visual-compare) | 2 | MIT | Python 168K、JS 42K、Shell 26K、CSS 11K | 2026-05-19 | git 命令（参数透传） | WKWebView（pywebview）+ 手写 JS | 无 | 未见 | 未见 |
| [g-cqd/GitDiffViewer](https://github.com/g-cqd/GitDiffViewer) | 0（已归档，迁入 Atelier） | MIT | Swift 582K、Shell 1K | 2026-09-17 | git 命令 | TextKit 2 | 有 | 有（按语法词元） | 未查到 |

闭源标杆（只看功能形态，未看内部实现）：

| 产品 | 核对到的功能形态 | 来源 |
|---|---|---|
| Sublime Merge | 并排 diff、语法高亮、字符级差异、拖动 hunk 边缘展开上下文 | https://sublimemerge.com （直取） |
| Kaleidoscope | 文本 / 图片 / 文件夹比较与合并；其余细节未核对 | https://www.kaleidoscope.app （直取） |
| Beyond Compare | 支持 Windows / macOS / Linux，文件与文件夹比较合并；细节未核对 | https://www.scootersoftware.com （直取） |
| JetBrains IDE | 独立 Merge 对话框，中间栏处理冲突 | https://www.jetbrains.com/help/idea/resolving-conflicts.html （直取） |
| Xcode 自带 diff | 未核对（检索配额用尽） | — |

## 三、最值得借鉴的 3 个实现（文件级指引）

### 1. foldgit（MIT，首选）

- `Shared/Sources/FoldGitCore/Git/Diff/Diff.swift`（244 行）：解析 `git diff` 原始输出。
- `Shared/Sources/FoldGitCore/Git/Diff/SideBySideDiff.swift`（155 行）：单栏块转并排行，带占位行。
- `Shared/Sources/FoldGitCore/Git/Diff/InlineDiff.swift`（213 行）：行内高亮，做法是「先做行配对，再词元级 LCS，再字符级细化」，并带硬性预算：单行 ≤8192、矩阵 ≤65536、总预算 100 万，超限退回只标整行底色。
- `Platforms/macOS/Sources/Features/Diff/SideBySideChunkView.swift`（397 行）：并排两栏用 `NSTextView` 放进 `NSViewRepresentable`，支持换行开关与横向滚动。
- `Platforms/macOS/Sources/Features/Diff/CommitDiffView.swift:214-227`：大 diff 默认折叠。
- 注意：仓库 2026-10-28 才创建，项目很新；Windows 端占比较大。

### 2. Maple（MIT，结构最接近 NeatGit）

- `Maple/Views/DiffView.swift`（317 行）：每行一个 `Text` 的单栏渲染，行号、增删底色、hunk 头。
- `Maple/Services/DiffParser.swift`（158 行）：保留每个文件的原前导行，便于重建补丁。
- `Maple/Services/GitService.swift:405-480`：`git diff --no-color` / `git show --format=`，未跟踪文件直接读文件合成。
- `Maple/Models/GitModels.swift:120-200`：按 hunk / 按行重建补丁后 `git apply --cached`。
- 短板：无并排、无行内高亮、无大文件处理。

### 3. GitUp（GPL-3.0，只看思路不抄代码）

- `GitUpKit/Interface/GIUnifiedDiffView.m`（667 行）、`GISplitDiffView.m`（816 行）：CoreText 自绘，单栏 / 并排共用一套行模型。
- `GitUpKit/Interface/GIFunctions.m:24-80`：行内高亮用「公共前缀 + 公共后缀」字节扫描，复杂度线性，比 LCS 便宜但精度低。
- `GitUpKit/Components/GIDiffContentsViewController.m:250-257`：按窗口宽度自动在单栏 / 并排间切换。
- `GitUpKit/Core/GCDiff.m:22,504`：8MB 文本 diff 上限。

补充参照：Xit 的 `Xit/html/`（32K）与 `Xit/FileView/Previews/FileDiffController.swift`（305 行）是「保留 Web 但砍掉 Monaco」的现成样板；commit-plus 的 `DiffHunkGeometry.swift`（固定行高 + 二分找可见 hunk）是大文件虚拟化的简明范例。

## 四、外部依据说明

- 一手直取：上表 11 个仓库的 star / 许可证 / 语言 / pushed 时间（GitHub API），最近提交日期与全部文件路径、行号（本地浅克隆）。
- 检索服务：本会话前段成功执行过 4 次 `tavily_search`（用于定位 Maple 仓库与其 dev.to 文章），之后小时配额用满返回 429，后续发现改用 GitHub 搜索接口。
- 未能核对：Kaleidoscope、Beyond Compare 的详细功能，Xcode 自带 diff 的形态；gitx 的并排与大文件策略；Xit、commit-plus 是否支持并排与行内高亮（源码 grep 未命中，不等于确定没有）。
