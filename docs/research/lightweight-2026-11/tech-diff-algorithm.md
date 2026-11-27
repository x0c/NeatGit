# tech-diff-algorithm：原生 diff 视图的数据来源与算法选型

> 调研日期：本轮。git 版本 2.51.2（本机）。实验仓库在 `~/…` 之外的临时目录 `/tmp/swarm/diffexp/`，未触碰用户仓库。

## 一、结论

1. **推荐「以 git 输出为准」**：行级与词级都让 git 算，Swift 侧只写解析器，不引入任何第三方依赖、不绑定 C 库。（已验证，依据见二、三）
2. **`apple/swift-diff` 仓库不存在**。（已验证：`git ls-remote` 对 `apple/swift-diff`、`swiftlang/swift-diff` 均返回 Repository not found；`gh repo list swiftlang` 共 82 个仓库无 diff 相关条目）
3. Apple 自带、可直接用的是标准库 `CollectionDifference`：只有「插入 / 删除(offset, element, associatedWith)」两种变更和 `inferringMoves()`，没有「原地替换」语义，不做词级。（已验证：本机 SDK 的 `Swift.swiftmodule/arm64e-apple-macos.swiftinterface` 36871–37172 行；算法与性能未核对）
4. 词级高亮**可以**由 git 直接给出（`--word-diff=porcelain`），免去自研算法；但 porcelain 输出不能单独承担行结构，需与行级输出配合，并有 6 个已实测的坑（见三）。
5. 750 KB 限制来自应用自身对 Web 渲染通道的保护，不是 git 的能力边界：实测 7.6 MB / 10 万行、4 处改动的文件，`git diff -U0` 全程 100–150 ms（单次测量，含进程启动）。（已验证）

## 二、三条路线对比

| 维度 | A. 以 git 输出为准 | B. Swift 自算（标准库 / 第三方库） | C. 绑定 C 库 |
|---|---|---|---|
| 依赖 | 无新增 | 无（标准库）或 +1 包 | 新增二进制依赖与工程配置 |
| 行级结果 | 与命令行一致，可选 `--diff-algorithm=patience/minimal/histogram/myers`（已验证，man git-diff 141–158 行） | 标准库只给增删，无替换配对；DifferenceKit 明示「不保证最短」（已验证，源码注释） | 未核对 |
| 词级结果 | git 直接给（已验证） | 两者都没有，仍要自己写 | 未核对 |
| 大文件 | 受 `core.bigFileThreshold`（默认 512 MiB，git-config 手册）约束，超出按二进制处理（已验证：阈值调成 1k 后 45 KB 文本被报为 Binary） | 取决于自算复杂度，未测 | 未核对 |
| 与 CLI 一致性 | 完全一致 | 可能不同，用户会看到「和终端不一样」的高亮 | 未核对 |
| 主要代价 | 解析器 + 配置隔离 + 若干格式坑 | 算法质量与性能要自己负责，词级仍缺 | 未核对；本项目当前零第三方依赖 |

**B 细节（已验证）**：`ra1028/DifferenceKit`，Apache-2.0，`swift-tools-version:5.0`，最新标签 1.3.0，master 最新提交 2022-06-24，本机 Swift 6.4.2 工具链 `swift build` 通过（9.3 s）。它是面向界面批量更新的集合差异库（Paul Heckel 算法），输出是带偏移的增删操作，不是文本行 / 词级 diff，**不适用**。其余 Swift diff 库（DeepDiff、Diff.swift、Dwifft 等）未评估——检索配额用尽。

**C 细节**：未查到（检索配额用尽），本机也未安装 libgit2，无法一手核对，列入未验证清单。

## 三、git 输出格式实测（均为已验证，`/tmp/swarm/diffexp/repo`）

**格式要点**

- `git diff -U0`：每个改动块一个 `@@ -旧起,旧数 +新起,新数 @@` 头，随后只有 `-` / `+` 行；头后面可能跟函数名上下文文本（如 `@@ -3 +3 @@ keep line one`），解析时须忽略。
- `--word-diff=porcelain -U0`：同样的 `@@` 头，块内是「增量段」，每段一行，首字符 ` `（共同）/ `-`（旧）/ `+`（新），换行用单独一行的 `~` 表示。内容恰为 `~` 的行显示为 ` ~`，可区分。
- 二进制：两种格式都只输出一行 `Binary files a/x and b/x differ`；`--numstat` 给 `-\t-`。
- 末行无换行：unified 有 `\ No newline at end of file`；**porcelain 没有**（实测 n.txt）。
- 改名文件：只传新路径时，git 把它当「全新文件」对比 `/dev/null`（实测，加不加 `--no-renames` 都一样）；要得到「旧路径内容 vs 新路径内容」用 `git diff <blobA> <blobB>`（如 `HEAD:旧路径 :新路径`），支持 porcelain，退出码 0，对象不存在时退出码 128。
- 换行符：本机 `core.autocrlf=input`，工作区文件进 diff 前已被转成 LF（输出无 `^M`），与现有加载器「直读工作区原始字节」口径不同；`--ignore-cr-at-eol` 可用。

**已实测的坑**

| # | 现象 | 证据 |
|---|---|---|
| 1 | porcelain 丢「末行无换行」标记 | n.txt 两种输出对照 |
| 2 | porcelain 的孤立 `~` 无法归 side：头写 `-4,2 +4,3`，按流重建旧侧却得 3 行 | c.txt |
| 3 | 用户配置 `diff.wordRegex` 会把改动悄悄变成上下文（新词整行显示为共同内容）；`-c diff.wordRegex=` 空值直接报错 | F2 组 |
| 4 | 默认按空白分词，粒度粗（`fox!`、`end, changed` 整体高亮）；`--word-diff-regex='[A-Za-z0-9_]+\|[^[:space:]]'` 更细；正则漏写非空白兜底则标点被忽略 | p.txt 组 |
| 5 | 仅空白变化：行级有差异，porcelain 无任何 `-`/`+` 段 | w.txt |
| 6 | `--no-index` 有差异时退出码为 1；现有 `requireSuccess` 会当失败 | untracked 组 |

**可行的取数方式（已验证）**

- 行级：`git diff --no-ext-diff --no-color --no-renames -U0 [--cached] -- <路径>`。
- 词级：把行级已配对的「旧行 / 新行」逐对加上唯一序号前缀，写入临时文件后跑一次 `git diff --no-index --word-diff=porcelain --word-diff-regex=… -U0 -- A B`。唯一前缀强制第 k 行只与第 k 行配对（内容互换时也不会错配），每段按前缀即可回填到具体行对；相同行自动不出现。代价：两个临时文件 + 退出码 1 需特殊处理。
- 改名 / 复制：改用 blob 对 blob。

**性能（单次测量，含进程启动，量级参考）**

| 文件 | 行级 -U0（myers） | histogram | porcelain 词级 | 默认 -U3 |
|---|---|---|---|---|
| 7.6 MB / 10 万行，4 处改动 | 122 ms | 138 ms | 104 ms | 151 ms |
| 724 KB / 1 万行，4 处改动 | 66 ms | 35 ms | 113 ms | 37 ms |
| 293 KB / 2.9 万行高度重复 | 66 ms | 35 ms | 52 ms | 46 ms |

高度重复内容下三种算法输出完全相同（均 10001 变更行），`--word-diff-regex=.`（字符级）耗时升至 513 ms、段数近 9 万，不建议默认使用。

## 四、现有加载链路（文件:行号）

**现在怎么取**（已验证，读源码）

- `NeatGitApp/Services/GitRepositoryDiffLoader.swift:105-135` 先判定两侧来源（空 / Git 对象 / 工作区文件），`:67-103` 把 Git 对象合并成**一次** `cat-file --batch`（`Services/GitCommandSupport.swift:89-103`），工作区侧 `:137-145` 直接读文件。**全程不跑 `git diff`，Swift 里没有任何 diff 算法。**
- `:3` 定义 `maxTextBytes = 750_000`，`:36-38` 判定；`:40-42` 以「含 NUL 字节」判二进制；`:44-45` UTF-8 容错解码；`:47-55` 把**两份全文**装进 `RepositoryDiffDocument`。
- 行级与词级差异全部由 Monaco 在网页里算（`Web/MonacoDiff/src/main.js:154` `diffAlgorithm: 'advanced'`），「只看变更」靠 Monaco 的 `hideUnchangedRegions`（知识库 154、169 行；文档写明早先的「Swift 侧解析 @@」方案因进程数 4–5 个而被废弃）。
- `NeatGitApp/Domain/RepositoryDiffModels.swift:33-40`（两份全文）`:42-66`（网页载荷）；`NeatGitApp/Stores/RepositoryDiffStore.swift:342-346`（缓存键）、`:313-333`（按刷新版本失效）、`:107-113`（`payloadForDisplay`）；`NeatGitApp/Domain/DiffLineStat.swift:20-34`（`fromPatch`：现成的极简 unified 解析，仅供提交分析用，`Services/CommitDiffAnalyzer.swift:135`）。

**现有数据结构能否直接喂原生视图**：不能。`RepositoryDiffDocument` 只有两份全文，没有行号、改动块、词级段；原生视图要的正是这些。

**改为 git 路线需要动的点**

1. `Domain/RepositoryDiffModels.swift:33-66`：文档模型改为「改动块 + 段」结构（旧 / 新起止行号、每段的类型与文本、是否末行无换行）；`MonacoDiffPayload` 视去留决定保留或删除。
2. `Services/GitRepositoryDiffLoader.swift:36-55`：去掉 750 KB 判定或大幅上调；二进制判定改用 git 输出的 `Binary files … differ` 行；`:105-135` 两侧来源判定保留（决定传不传 `--cached`、改名走 blob 对 blob、未跟踪走 `--no-index`）。
3. `Services/GitCommandSupport.swift:29-31`：stdout 与 stderr 共用一根管道，CRLF 警告会混进 diff 输出，需分开或过滤；`:64-74` `requireSuccess` 需允许 `--no-index` 的退出码 1。
4. 新增解析器（unified 与 porcelain 两种），放在 `Services/`，复用 `GitCommandRunner`；参数固定带 `--no-ext-diff --no-color --no-textconv --no-renames --word-diff-regex=…`（先例：`Services/CommitDiffAnalyzer.swift:238`）。
5. `Stores/RepositoryDiffStore.swift`：缓存与失效逻辑可原样保留，仅类型随模型变化。
6. 视图：`Views/RepositoryStatus/RepositoryPreviewPane.swift:35-37` 换掉 `MonacoDiffView`；「只看变更」不再由 Monaco 承担，需自带上下文行数与真实行号（知识库 154 行的要求不变）。
7. 测试：`NeatGitTests/RepositoryDiffStoreTests.swift:31-37,42,59,74,115` 与 `MonacoWebViewTests.swift:87-88,149` 断言的是全文内容，需随模型改写；知识库 122、154、169 行需同步修订。

## 五、外部依据与未验证清单

**本机一手依据**：`man git-diff`（2.51.2，`-U<n>` 99 行、算法 116–158 行、porcelain 341–381 行、`--textconv` 629–634 行、`--ignore-cr-at-eol` 581 行、`diff.external` 1193 行、`diff.wordRegex` 1275 行）；`man git-config`（`core.bigFileThreshold` 2009–2012 行）；SDK 接口文件；DifferenceKit 浅克隆的 `Package.swift`、`LICENSE`、`Sources/Algorithm.swift`；以上全部实验输出。

**页面直取（仅确认可访问，未做检索）**：`https://git-scm.com/docs/diff-options`、`https://git-scm.com/docs/git-config`、`https://github.com/ra1028/DifferenceKit`、`https://developer.apple.com/documentation/swift/collectiondifference`。

**未查到（检索配额用尽，429）**：DifferenceKit 近两年的发布动态（`gh api` 显示仓库 2026-06 有推送，但 master 最新提交为 2022-06-24，未核对是哪个分支）；其他 Swift diff 库；libgit2 等 C 库的 Swift 绑定现状；`CollectionDifference` 所用算法与复杂度。

**未验证假设**：解析器的代码量与原生视图渲染 10 万行级别的性能；「唯一前缀批量词级」方式对超长单行（如压缩后的一行 JSON）的表现。
