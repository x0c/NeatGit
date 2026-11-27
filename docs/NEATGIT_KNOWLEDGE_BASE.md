# NeatGit 核心知识库

> 覆盖范围：NeatGit 核心功能（仓库扫描、文件状态、Diff、提交流程、原生差异渲染、状态管理）的业务规则、代码入口、隐性约束与验证路径。

---

## 产品北极星

NeatGit 是面向 macOS 的原生 Git 客户端（SwiftUI 构建）。核心循环：扫描本地 Git 仓库 → 查看文件状态与 diff → 填写 commit message（可 AI 生成）→ 提交/推送。目标用户是 macOS 开发者，优先覆盖高频 Git 操作，不做臃肿全能客户端。

## 目录索引

- 界面与系统版本约定
- Compact Settings (layout, prompt editing and verification)
- 一、目录结构与领域划分
- 二、核心业务规则与隐性约束
  - 2.1 Git 命令执行基础设施（GitCommandRunner）
  - 2.2 文件状态模型（FileSection / isCheckableForCommit）
  - 2.3 Diff 当前边界（5 MB / 二进制 / 冲突 / 仓库级变动列表 / 原生渲染 / 只看变更）
  - 2.4 Diff 加载流程
  - 2.5 仓库切换与零加载（SWR）机制
  - 2.6 提交流程（index 同步机制）
  - 2.7 AI commit message 生成
  - 2.8 原生差异渲染链路
  - 2.9 状态管理规范
  - 2.10 仓库扫描约束
  - 2.11 应用内更新与签名发布约束
  - 2.12 后台端到端验收（Tests/E2E）
- 三、AI 易错点（10 条）
- 四、验证路径
- 五、关联文档

---

## 界面与系统版本约定

- 最低支持 **macOS 26.0**，以 Xcode 26 的系统 SDK 构建，不再保留旧系统的界面兼容分支。
- 窗口、三栏导航、列表选择、工具栏、输入框、设置与弹窗优先使用 SwiftUI 系统控件；不遍历窗口内部视图改标题颜色，不自绘系统已有的选择态与折叠控件。
- 系统负责 Liquid Glass、浅色/深色外观与辅助功能适配；玻璃用于导航和操作区域，代码与表单正文保持清晰，不叠加装饰性玻璃。
- 差异预览当前使用原生 TextKit 文本视图，不内嵌网页；右侧以全部变更文件折叠列表呈现，仅当前关注文件展开并加载差异，其余文件不为预览启动内容加载。原生视图的装配顺序与容器尺寸约束见 2.8，违反后分别表现为内容区整片空白、改尺寸时崩溃。
- Git、AI 和本地配置的业务语义不因 UI API 升级而改变。
- 主窗口的四个工作区采用一致的原生标题层级：项目 / 文件更改带系统图标，差异标题带轻量文件图标；文件摘要使用短状态标签，零计数回落为中性色，不让“0 个不提交”呈现为警示。新增间距与语义色统一接入 `Theme`，不在各视图另起一套视觉常量。
- 提交区保持独立实底卡片和固定 72pt 的滚动输入区，避免旧版弹性输入区吸走整栏剩余高度；卡片只表达功能边界，不给代码正文叠加装饰性材质。

依据：[Apple 新设计迁移指南](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)、[WWDC25 SwiftUI 新设计](https://developer.apple.com/videos/play/wwdc2025/323/)。接口可用性以本机 Xcode 26 SDK 声明和实际构建为准。

## Compact Settings (owner rollout, 2026-10-22)

The fleet inventory previously omitted NeatGit. Apply the [shared settings specification](~/Codes/_standards/workspace-docs/swift-docs/macos-settings-visual-spec.md) to its existing native Settings scene.

- One 480-point, content-sized grouped `Form`: connection fields, a system-prompt edit action, automatic-update switches, then the 32-point app identity/version with Check for Updates and Quit. All settings and actions must remain visible without scrolling or scrollbars. Keep the native close control and Command-comma entry.
- Reuse the actual NeatWebApp `GeneralSettingsPane`/`AboutRow` and measured-form pattern after inspection; do not copy its launcher, login-item or termination-guard behavior. NeatGit has ordinary application termination.
- Use public SwiftUI `Settings`, `Form`, `Section`, `TextField`, `SecureField`, `LabeledContent`, `Toggle`, `sheet` and `TextEditor` directly. The installed macOS 27.2 SDK declares these APIs and `onScrollGeometryChange`/`scrollDisabled`; the deployment target remains macOS 26. Apple references: [Form](https://developer.apple.com/documentation/swiftui/form), [TextEditor](https://developer.apple.com/documentation/swiftui/texteditor), [scrollDisabled](https://developer.apple.com/documentation/swiftui/view/scrolldisabled(_:)).
- The prompt is arbitrary user content, not additional settings rows. Edit it in a native sheet with a multiline editor and Cancel/Done; cancellation discards the draft, Done persists through the existing store, and Restore Default updates only the draft. The main Settings surface must never grow or scroll with prompt length. The editor retains native text navigation, selection and undo; its content can scroll inside the editor.
- Remove tutorial paragraphs from the form; retain useful connection/prompt explanations as hover help. Do not perform AI requests, Git commits/pushes or modify the user's repository selection during acceptance.
- This visual change preserves `LLMSettingsStore` persistence. Its existing explicit no-Keychain product decision in `AI_COMMIT_GUIDE.md` conflicts with the newer shared Keychain default. Credential migration is outside this visual change; it remains an unresolved storage decision, not a claim of secure-at-rest credential storage. Never print credentials or preferences wholesale.
- Validate current installed Settings pixels, full geometry, native secure input and prompt Cancel/Done behavior separately. Lock-screen restrictions on physical keyboard/VoiceOver do not prevent attempted window capture and do not establish those interaction passes.

## 一、目录结构与领域划分

```
NeatGitApp/
├── Domain/           # 纯数据模型，无 I/O
│   ├── GitRepository.swift          # 仓库实体（路径/名称/ID）
│   ├── RepositoryFileModels.swift   # 文件状态模型（FileSection / FileItem / FileState）
│   ├── RepositoryDiffModels.swift   # Diff 相关模型（DiffMode / DiffDocument / 逐行对照结果 RepositoryDiffRow）
│   ├── RepositoryGroup.swift       # 左侧栏分组模型
│   ├── ChangeKind.swift            # 文件分类枚举 + 权重
│   ├── DiffLineStat.swift          # diff 行统计 + numstat 解析
│   ├── CommitMessageCandidate.swift # 结构化输出模型 + JSON 解码
│   ├── LLMProviderConfiguration.swift # LLM 配置值对象
│   └── CommitExclusion.swift       # .gitignore 硬排除逻辑（共享）
├── Services/         # 纯副作用层，不持有状态
│   ├── GitCommandSupport.swift      # Git 进程执行基础设施（核心）
│   ├── GitRepositoryScanner.swift   # 扫描 Home 目录下的 Git 仓库
│   ├── GitRepositoryStatusLoader.swift  # 读取仓库 git status
│   ├── GitRepositoryDiffLoader.swift    # 加载并解析文件 diff
│   ├── TextDiffCalculator.swift     # 进程内计算行级与行内差异（Myers，带预算降级）
│   ├── GitRepositoryCommitService.swift # 提交 / 推送
│   ├── GitIgnoreWriter.swift            # 写 .gitignore
│   ├── CommitMessageGenerationService.swift  # AI commit 协调层（分析 → 构建 prompt → 单次 LLM 调用）
│   ├── AppUpdater.swift                     # Sparkle 应用内更新桥接（温和提醒）
│   ├── CommitDiffAnalyzer.swift      # diff 分析、摘要、symbol 提取
│   ├── CommitPromptBuilder.swift     # prompt 构建 + 摘要/guidance/signals
│   ├── LLMChatService.swift          # OpenAI 兼容 API 调用 + response_format
│   └── KeychainSecretStore.swift        # Keychain 读写（LLM API Key）
├── Stores/           # @Observable 状态容器，运行在 @MainActor
│   ├── RepositoryStore.swift        # 全局仓库列表 + 扫描状态 + 星标
│   ├── RepositoryStatusStore.swift  # 当前仓库文件状态快照（跨仓库 SWR 缓存 + 悬停预取）
│   ├── RepositoryDiffStore.swift    # 当前选中文件 diff（含预取缓存）
│   ├── LLMSettingsStore.swift       # LLM 配置（持久化到 UserDefaults）
│   └── AICommitDebugStore.swift     # AI 生成调试日志
├── Views/            # SwiftUI 视图层
│   ├── Sidebar/      # 左栏：仓库列表与分组
│   ├── RepositoryStatus/ # 中栏：文件状态面板 + 右栏：预览/diff
│   ├── Diff/         # 原生差异视图（NativeDiffView：NSTextView + 系统默认 TextKit 1，并排 / 单栏）
│   ├── Commit/       # 底部提交栏 + AI 调试窗口
│   └── Settings/     # LLM 配置设置页
├── ContentView.swift # 原生三栏 NavigationSplitView + safeAreaBar
└── NeatGitApp.swift  # App 入口，Window Group + WindowScene 配置
```

---

## 二、核心业务规则与隐性约束

### 2.1 Git 命令执行基础设施

**唯一入口**：`GitCommandRunner`（`NeatGitApp/Services/GitCommandSupport.swift`）。

- 所有 Git 子命令必须通过 `GitCommandRunner.run(in:arguments:standardInputData:)` 执行，不要在新 Service 里复制粘贴 `Process + Pipe + terminationStatus` 模板。
- `GitCommandError.describe(_:)` 是唯一的 Git 错误格式化方法；UI 层展示 Git 错误时统一调用它。
- 读多个 Git 对象内容走 `GitCommandRunner.readObjects(specifiers:in:)`，它用一次 `cat-file --batch` 完成存在性判断与内容读取，缺失对象返回 `nil`。不要回到「每个对象先 `cat-file -e` 再 `show`」的写法：那会把单文件 diff 的进程启动数从 1 抬到 4，本机实测约 105ms vs 约 23ms。
- 长驻的 `cat-file --batch` 进程不可用作缓存：索引在进程启动时快照，暂存后同一进程仍返回旧 blob（已实测证伪）。
- 错误信息字符串均为中文，新增时保持一致。

### 2.2 文件状态模型

`RepositoryFileSection`（枚举，3 种）：

| case | 含义 | 提交逻辑 |
|------|------|---------|
| `changed` | 有变更的 tracked/untracked 文件 | 默认参与提交（除 .gitignore 文件） |
| `skipped` | skip-worktree 文件 | 不参与提交 |
| `ignored` | .gitignore 忽略的文件 | 不参与提交 |

**`RepositoryFileItem.isCheckableForCommit`**：只有 `section == .changed && !hasConflict` 的文件才能被加入提交。

**冲突判定**：`hasConflict` 即 `RepositoryFileItem.isUnmergedStatus(gitStatusCode)`。七种未合并状态码（`DD` / `AU` / `UD` / `UA` / `DU` / `AA` / `UU`，与 `man git-status` 的对照表一致）全部算冲突；`AA`、`DD` 不含字母 `U`，不能只认 `U`。状态加载器的「冲突」摘要与提交范围共用这一份判断。

**gitStatusCode**：两字符字符串（`XY`），`indexStatusCode = X`（暂存区状态），`workTreeStatusCode = Y`（工作区状态）。重命名/复制文件的原路径记在 `previousPath`。

### 2.3 Diff 当前边界（2026-06）

**单文件文本 diff 完整约束**：

- 只支持单文件、文本内容。
- 最大文件大小：5 MB（`maxTextBytes = 5_000_000`，`GitRepositoryDiffLoader`）。判断时机在 `loadContents` 之后、`isBinaryData` 检测之前，取 `max(originalData.count, modifiedData.count) > maxTextBytes`，超过则抛出 `GitCommandError`（"文件过大，暂不展示超过 5 MB 的文本差异。"）。
- 前置守卫顺序（`makeDocument` 方法内）：① `section == .changed` 检查 → ② `hasConflict` 检查 → ③ `availableDiffModes.contains(mode)` 检查 → ④ 文件大小检查 → ⑤ 二进制检测。任一不满足立即 throw，不会继续执行后续步骤。

**二进制文件处理**：

- 检测方式：`isBinaryData(_:)` 检查 `Data` 是否含 null byte（`data.contains(0)`），original / modified 任一侧命中即判二进制。不依赖 `git diff --stat` 的 `-Binary` 标记，也不看扩展名。
- 返回结果：抛出 `GitCommandError`（"当前只支持文本 diff，二进制文件稍后再接。"），由 `RepositoryDiffStore.applyFailure(_:)` 格式化后经 `ContentUnavailableView` + `GitCommandError.describe(_:)` 展示中文错误。

**冲突文件处理**：

- 检测方式：`item.hasConflict == true` 时在 `makeDocument` 最前的 guard 阶段拦截。
- 拒绝原因：冲突内容包含 conflict markers（`<<<<<<<` / `=======` / `>>>>>>>`），差异视图只做两方对照，会把 marker 当普通文本渲染，无法表达三方合并语义，容易误导用户，故直接拒绝展示而非展示带 marker 的原文。
- 返回结果：抛出 `GitCommandError`（"冲突文件的可视化 diff 还没接入。"）。

**仓库级变动列表（2026-11-27 用户确认）**：

- 右侧展示当前仓库全部 `changedFiles`，但只展开当前关注的一个文件；其他文件始终为紧凑折叠行。展开状态复用 `WorkspaceSelectionStore.selectedFileIDs`，右侧点击通过 `ContentView` 回调 `selection.selectFile`，不在预览视图另存一套展开状态。
- `RepositoryDiffStore`、`RepositoryDiffDocument` 与缓存继续保持单文件语义，只读取当前展开文件；不为折叠行预加载或拼接多文件文档，不引入多文件缓存键。
- 无选择或多选时全部折叠并显示选择提示。二进制、冲突、过大文件等拒绝原因只出现在对应文件的展开区域，不再遮盖整个文件列表。
- 展开区使用有界高度的 `NativeDiffView`，内部滚动；外层列表负责折叠行滚动，不伪造整页连续滚动。切换展开文件时沿用现有任务取消、缓存、预取、模式切换和“只看变更”链路。

**原生渲染约束**（链路与装配约束见 2.8）：

- 输入只认加载好的 `RepositoryDiffDocument`，差异不在界面侧另算。把逐行结果变成富文本是后台任务；期间换了文档、布局或开关，旧批次结果按批次号直接丢弃。
- 布局分并排（左原文、右改后，各一个只读文本视图，逐行对齐、滚动联动）与单栏（删除行在上、新增行在下，行首带 `-` / `+`）两种，不随窗口宽度自动切换，由头部「差异布局」选择。
- 固定行高；容器宽度取内容宽度与可视宽度的较大者，内容更宽时横向滚动。任何一行都不能折行，否则其后全部行错位。
- 配色全部是随外观动态解析的系统颜色，浅色 / 深色 / 高对比切换时只重绘，不重建富文本。
- 没有语法高亮，只有增删与行内着色。

**「只看变更」的实现边界**：

- 由原生渲染侧折叠未变更内容承担：输入始终是完整的逐行对照结果，长段未变更内容前后各留 3 行（`NativeDiffRenderBuilder.contextLines`），中间折叠成一行可点击的展开行，行号保持文件里的真实值。不要回到在 Swift 侧按 hunk 裁剪文本（旧做法）：那会丢掉上下文与真实行号。
- 开关、布局与展开集合是渲染侧的独立状态，不进 `RepositoryDiffStore` 的文档缓存键；切换它们不重新读 git。

### 2.4 Diff 加载流程

```
RepositoryDiffStore.select / selectMode → loadCurrentSelection
  └─ GitRepositoryDiffLoader.loadDiff(for:in:mode:)   # 整体在一个 Task.detached 里执行
       ├─ loadContents()      # 先定两侧来源（空 / Git 对象 / 工作区文件）
       │    ├─ GitCommandRunner.readObjects()  # Git 对象合并成一次 cat-file --batch
       │    └─ readWorkingTreeFile()           # 工作区侧直读文件
       └─ TextDiffCalculator.calculate()      # 进程内算出逐行对照结果，写入 RepositoryDiffDocument.rows
  └─ NativeDiffView（RepositoryPreviewPane 里）
       └─ NativeDiffRenderBuilder.render()     # 后台把逐行结果变成各面板的富文本
       └─ NativeDiffPaneController.apply()     # 主线程写进原生文本视图
```

读内容时不再额外跑 `git diff` 解析 `@@` 行：只看变更由原生渲染侧折叠未变更区域，hunk 模型已废弃。单文件 diff 因此只启动 1 个 git 进程（旧实现是 4–5 个），本机实测 2000 行文件的读取中位数约 15ms。

**逐行对照结果（原生差异视图的直接输入）**：`GitRepositoryDiffLoader.makeDocument` 在同一个后台任务里调用 `TextDiffCalculator.calculate(originalText:modifiedText:)`，把结果写进 `RepositoryDiffDocument` 的 `rows` / `originalLines` / `modifiedLines` / `originalEndsWithoutNewline` / `modifiedEndsWithoutNewline`；主线程不做差异计算，也不为此启动 git 进程。行级用 Myers 算法，超出编辑距离或搜索步数预算的段落降级为「先全部删除、后全部新增」，任何输入都在有限时间内返回；行内只给改动行标字符区间（`RepositoryDiffRow.originalChangedRanges` / `modifiedChangedRanges`，UTF-16 偏移、相对该侧 `text`）。行模型 `RepositoryDiffRow` / `RepositoryDiffLine` / `RepositoryDiffRowKind` 定义在 `Domain/RepositoryDiffModels.swift`。`RepositoryDiffDocument` 的 `==` 不比较 `rows`；渲染侧靠 `renderingID` 区分每次加载的版本，不比较两侧全文。`calculatingDiffRows()` 是耗时操作，只在后台调用，不要在主线程或界面刷新路径上调。

`RepositoryDiffStore` 有预取缓存（最多 24 条，文件行悬停延迟 60ms 触发），缓存里的文档同样带算好的 `rows`。双状态文件通过原生分段选择器切换暂存区/工作区，只读允许的模式；有暂存内容时默认显示暂存区。刷新版本号变化会清理该仓库缓存。

### 2.5 仓库切换与零加载（SWR）机制

`RepositoryStatusStore` 的核心约束（2026-10 引入）：

- **跨仓库快照缓存**：LRU 上限 10 个仓库（`maxCachedSnapshots`）。`load(for:)` 命中缓存时**同步立即显示旧快照**（零等待），随后后台静默刷新。
- **版本号纪律**：`applySnapshot` 中新旧快照 `Equatable` 相等时**不递增 `snapshotRevision`**——这是右侧 diff 缓存和选中态不被误清的前提；只有数据真实变化才递增。`RepositoryFileSnapshot` 因此必须保持 `Equatable`，新增字段时注意保持该语义。
- **刷新失败保留内容**：已有内容时 `applyFailure` 不清空 snapshot，只设置 errorMessage；`RepositoryFilePanel` 中 snapshot 展示优先级高于 errorMessage，错误降级为顶部栏提示。
- **侧栏悬停预取**：侧栏仓库行只上报进入 / 离开事件（`RepositoryHoverEvent`），停留判定与并发上限都收在 `RepositoryStatusStore.prefetch(for:)`。停留满 200ms（`defaultHoverPrefetchDelay`）才开始，快速划过不触发；同时最多 1 个在途，在途期间只记最新一个目标，离开全部行时尚未开始的一律作废。预取只填缓存不动 UI；选中时 `fetchSnapshot` 复用同仓库在途预取，同一仓库不会跑两遍 git status。选中仓库的正式加载不受预取在途上限约束。
- **并行加载**：`GitRepositoryStatusLoader.loadSnapshot` 中 `git status` 与 `git ls-files` 通过 `async let` 并行执行，首次加载耗时从两者之和降为最大值。
- 回归测试：`NeatGitTests/RepositoryStatusStoreTests.swift`（缓存命中立即显示 / 无变化版本号稳定 / 有变化递增 / 失败保留内容 / 预取命中与选中复用 / 悬停须停留、单在途、只记最新目标、离开作废）。

### 2.6 提交流程（index 同步机制）

`GitRepositoryCommitService.perform(_:)` 提交前会自动同步 index：

1. 把**不在提交列表但已暂存**的文件 `restore --staged`（取消暂存）。
2. 把**在提交列表但未暂存**的 untracked / 有未暂存变更文件 `add -A`（暂存）。
3. 最后 `commit -m <message>`。

「提交列表」指 `changedItems` 里通过 `isCommittableByDefault` 的文件。

路径通过 stdin 传入（`--pathspec-from-file=- --pathspec-file-nul`），避免路径含空格的问题；`makePathspecData` 还给每条路径加 `:(literal)` 前缀按字面匹配。Git 默认把路径当通配模式：名为 `a*.txt` 的文件会连带暂存 `av.txt`，`?`、`[` 和开头的 `:` 同样有特殊含义。新增带路径的 Git 命令时两点都要沿用。

**隐性约束**：`.gitignore` 文件被 `shouldExcludeFromDefaultCommit` 硬排除，不会默认加入提交。

### 2.7 AI commit message 生成

调用链：`CommitComposerBar` → `CommitMessageGenerationService`（协调层）

- LLM 调用参数来自 `LLMSettingsStore`：`baseURL` / `apiKey` / `model`，全部持久化到 `UserDefaults`。
- `CommitMessageGenerationService` 是薄协调层，编排 `CommitDiffAnalyzer`（diff 分析）、`CommitPromptBuilder`（prompt 构建）和 `LLMChatService`（API 调用）。
- 生成只有单次调用一条路径：`CommitDiffAnalyzer.analyze()` 产出 `CommitAnalysisContext` → `CommitPromptBuilder.buildUserPrompt(with:)` → `LLMChatService.complete(... maxTokens: 1024, responseFormat: .jsonObject)`。
- 新增文件（untracked）没有可比对的基线，`CommitDiffAnalyzer` 直接读工作区正文节选作为 snippet，不取 diff。
- 结构化输出：`CommitMessageCandidate` 解码 LLM JSON 响应（`type`/`scope`/`subject`/`body`），通过 `composedMessage` 组装为完整 commit message（含 body）。
- `ChangeKind` 分类逻辑已移到 `Domain/ChangeKind.swift`（public），权重影响 prompt 详略。
- `.gitignore` 排除逻辑统一到 `CommitExclusion.shouldExcludeFromDefaultCommit`，`CommitDiffAnalyzer` 和 `GitRepositoryCommitService` 共用。
- 调试日志通过 `AICommitDebugStore` 记录，可在 `AICommitDebugWindowView` 中查看。

### 2.8 原生差异渲染链路

```
RepositoryPreviewPane（展开文件的区域，固定高度 240–640）
  └─ NativeDiffView（NSViewRepresentable）→ Coordinator
       ├─ 小文档快速路径（≤256 行且两侧合计 ≤64,000 UTF-8 字节）：同步准备，省去异步调度
       ├─ 大文档后台任务：NativeDiffRenderBuilder.render(document, layout, showChangesOnly, expanded)
       │    # 把逐行对照结果变成各面板的显示行、富文本、行样式与行号；不做差异计算
       └─ 主线程：NativeDiffContainerView.install → NativeDiffPaneController.apply
            └─ NSScrollView（NativeDiffClipView）→ NativeDiffTextView（系统默认 TextKit 1，只读可选）
                 # 在背景绘制阶段画行号、整行底色、彩色行上的选择高亮与展开行
```

- **装配顺序**：`NSScrollView` 必须先换成自定义裁剪视图、再挂文档视图。反过来的话文档视图会留在被换掉的旧裁剪视图里，不在窗口层级内，真实窗口里内容区整片空白。
- **容器高度必须是有限值**：文本容器高度等于按行数算出的文档高度，不设无限高。无限高的容器在有内容之后再改尺寸（窗口变宽、切换文件都会走到），系统会在内部通知旧版排版器时直接崩溃。
- **行号与底色画在背景绘制阶段**：`draw(_:)` 返回后行号栏区域已被裁掉，画不进去。
- **过期结果不上屏**：批次号与任务取消双重保护；换了文档先清空面板，避免新结果到达前闪现旧文件。
- **渲染结果小缓存**：最近 4 种「文档版本 + 布局 + 只看变更 + 展开集合」组合，避免来回切换重复构建富文本。
- **滚动联动**：并排时两栏行数、行高相同，位置直接照搬，只走系统位置变化通知一个通道。
- **滚动锚点**：换内容（展开折叠行、开关只看变更）后按视口顶部最近的一处改动恢复位置，不跳回顶部。
- **性能量测与派生数据缓存**：项目/文件分组、文件索引和提交计数只在输入变化时计算；文件悬停只在右侧视图观察。统一 `InteractionProfiler` 的采集、指标口径、实测数据与锁屏边界见 [交互性能指南](INTERACTION_PERFORMANCE.md)，不得把后台 Git 或异步调度耗时算成 MainActor 点击处理耗时。

已知遗留（未解决，不计为通过）：折叠展开行的点击在真实用户路径上复核不充分；大文件内存仍偏高。

旧网页差异视图已删除：`MonacoDiffView`、`BundleStaticFileServer`、Monaco 静态资源、`Web/` 下的网页源码及其网页验收脚本都已不在仓库里，应用不再依赖 Node 构建链。差异显示效果由真实窗口验收与 `NativeWorkspaceTests` 承担，不再有网页黑盒验收。

### 2.9 状态管理规范

- 所有 store（含 `RepositoryDiffStore`）均使用 `@MainActor + @Observable`；视图用 `@State` 持有，任务/缓存用 `@ObservationIgnored` 排除无关重绘。
- 后台任务用 `Task.detached(priority: .userInitiated)`；不要在新代码里用 `DispatchQueue.global().async`。唯一例外是原生差异的小文档快速路径：只有同时满足 256 行与 64,000 字节上限才允许同步准备，大文件不得搬回 MainActor。

### 2.10 仓库扫描约束

`GitRepositoryScanner`：
- 从 `FileManager.default.homeDirectoryForCurrentUser` 开始，递归深度 **6 层**。
- 跳过：`.Trash`、`.cache`、`.gradle`、`.m2`、`node_modules`、`vendor`、`Pods`、`.Xcode`、`DerivedData` 等常见缓存和依赖目录。
- 并发度：`TaskGroup` 并行子目录，无额外限制。

### 2.11 应用内更新与签名发布约束（2026-10 引入）

更新入口：`NeatGitApp/Services/AppUpdater.swift`（`@MainActor + @Observable`，`SPUStandardUpdaterController` 温和提醒模式：后台发现更新不抢焦点，只有主动检查才弹窗）。菜单 `NeatGit → 检查更新…`（`NeatGitApp.swift`）与设置页“更新”分组（`LLMSettingsView.swift`）只观察 `canCheckForUpdates` 等桥接状态，不直接碰 Sparkle 对象。

- `Info.plist` 的 `SUFeedURL`（`https://raw.githubusercontent.com/x0c/NeatGit/master/appcast.xml`，注意默认分支是 `master`）与 `SUPublicEDKey`（与 NeatEditor/NeatPaste 共用同一 `caozc.top` EdDSA 密钥）配套，缺任一项时不要 `startingUpdater: true`。
- `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 双写于 `project.yml`，分别映射 `CFBundleShortVersionString` / `CFBundleVersion`；内部构建号必须严格递增，否则 Sparkle 永远判定“已是最新”。
- Release 配置：Manual + `Developer ID Application` + `ENABLE_HARDENED_RUNTIME=YES` + `--timestamp` + `INJECT_BASE_ENTITLEMENTS=NO`；Debug 保持自动签名。发版一律走 `scripts/publish-release.sh`（archive + developer-id 导出，路线 A），禁止 build 后手签。
- `appcast.xml` 随仓库发布，`CHANGELOG.md` 当版条目是发行说明来源；发布纪律见 `RELEASING.md` R1–R7。

---

## 三、AI 易错点

1. **修改 diff 功能前**，注意 `RepositoryPreviewPane.swift` 故意用了朴素的 `task(id:)` 刷新方式，原因见第 10 条（Xcode 26.3 / Swift 6.2 编译器崩溃，另见 AGENTS.md §3.1）。
2. **新增 Git 命令**，必须走 `GitCommandRunner`，不要直接用 `Process`。
3. **处理路径含空格的文件**，必须通过 `--pathspec-from-file=- --pathspec-file-nul` 传入并加 `:(literal)` 前缀（见 2.6），不要在参数数组里直接拼路径字符串。
4. **扩展提交流程**，注意 index 同步逻辑：如果只 stage 增量文件而不 unstage 已排除的暂存文件，会导致意外提交。
5. **装配原生差异面板**，必须先换自定义裁剪视图、再挂文档视图，文本容器高度用有限值（见 2.8）；顺序或高度不对分别表现为内容区整片空白、改尺寸时崩溃。
6. **Swift 6 并发隔离**：改动 Store、Binding、异步任务捕获时，先按 actor 边界思考，再动手，不要等编译器报错后再补 `@Sendable` 标注。
7. **扩展二进制 diff 时**，注意当前 null byte 检测（`isBinaryData` → `data.contains(0)`）位于 `GitRepositoryDiffLoader.makeDocument` 内、文件大小检查之后、文本解码之前。如果改为基于文件扩展名或 `git diff --stat` 的 `-Binary` 标记来检测，需要同时调整这个守卫的位置和逻辑，否则会出现大文件先被 size guard 拦截、小二进制文件仍走 null byte 检测的不一致路径。另外，UTF-16 等含 null byte 的非 UTF-8 纯文本会被误判为二进制，扩展时需考虑是否引入编码嗅探。
8. **仓库级变动列表**只在 `RepositoryPreviewPane` 聚合文件行，不聚合并发加载多个文档。展开文件仍复用单文件 `CacheKey` 与选择链路；折叠行不得触发 diff 加载。`NativeDiffView` 必须给有界高度，且它是内部滚动的文本视图，不要把多个全文高度直接塞进外层 `ScrollView`。
9. **修改原生差异视图的输入时**，内容只认加载好的 `RepositoryDiffDocument`，渲染侧按 `renderingID` 比较版本，不比较两侧全文。只看变更、布局与展开状态走渲染侧的独立通道，都不要混进 `RepositoryDiffStore` 的文档缓存键——混进去的代价是每次切开关都重新读 git。
10. **修改 diff 预览刷新机制时**，`RepositoryPreviewPane` 用 `task(id: selectionSignature)` 和 `task(id: hoverPrefetchSignature)` 两条独立链路驱动刷新，而非 `onChange`。这是有意为之——Xcode 26.3 / Swift 6.2 下该视图叠加复杂 `onChange` / `Binding` 会触发编译器崩溃。模式切换由小型 `Binding` 直接调用 store 的 `selectMode`；其他选择刷新仍扩展签名，不堆叠复杂 `onChange`。主窗口也把三栏、工具栏和状态监听拆成独立属性，避免 Xcode 26.3 的类型检查超时。

---

## 四、验证路径

- **本地构建**：`xcodegen generate && xcodebuild -scheme NeatGit -configuration Debug` 或直接用 Xcode 打开 `NeatGit.xcodeproj`。
- **工程配置变更**（新增/删除/移动 Swift 文件）：必须先改 `project.yml`，再 `xcodegen generate`，不要只手改 xcodeproj。
- **回归**：`NeatGitTests` 覆盖原生控件、差异 store、原生差异渲染构建（`NativeDiffRenderTests`：只看变更折叠、展开恢复、并排两栏行数一致）、提交安全（`CommitSafetyTests`：冲突判定、路径字面匹配）和行级 / 行内差异计算（`TextDiffCalculatorTests`）；`NeatGitUITests` 覆盖窗口点击路径。运行命令与锁屏限制见 [Operations 指南](OPERATIONS_GUIDE.md)。
- **后台端到端验收**：`./Tests/E2E/run_e2e.sh`（pytest，见下节 2.12）。构建产物在 `.build/e2e-derived/Build/Products/Debug/NeatGit.app`，`Tests/E2E/e2e.json` 用 `app_path` 指向它、`build: false`：harness 自带的 xcodebuild 路径对 xcodegen 工程不带 `-scheme`，会直接报错。

### 2.12 后台端到端验收（Tests/E2E，2026-11）

窗口级截图 + AX 交互的 pytest 套件，全程不抢前台、不移动光标；每次运行都在 `/tmp/neatgit-e2e` 重建一次性仓库（`Tests/E2E/fixture_repo.py`），不碰本人主目录。

- **扫描根目录**：`--repository-root <path>` 启动参数把 `GitRepositoryScanner` 的根从用户主目录换成指定目录（深度上限 3）。不传参数时行为完全不变，因此仓库列表仍然来自主目录扫描；端到端用例靠这个参数打开临时仓库，不经过任何系统面板。
- **窗口呈现**：`--e2e-testing` 下由 `E2ETestWindowController`（`NeatGitApp/Services/E2ETestWindow.swift`）自建 AppKit 窗口并 `orderBack(nil)`。macOS 26 上 `WindowGroup` 在 `open -g` 后台启动时不创建任何 NSWindow（进程健康、零窗口），只有被激活才 ordering；这条路径是截图能拿到窗口的前提，生产路径不传该参数就不走。窗口尺寸取 `--e2e-window-size WxH`（默认 1400x860），并用 `NSScreen.screens.first` 的可见区域收敛——`NSScreen.main` 会随键盘焦点在多屏之间漂移，导致基线尺寸抖动。
- **像素基线**：`Tests/E2E/baselines/main-window.png` 是 1400x912 pt 窗口（含标题栏）的整窗图，`max_diff_ratio=0.0`；`capture` 步记录 `occlusion_ratio`（窗口被完全遮挡时仍是 1.0，靠窗口缓冲截图，属预期）。首次运行报 `baseline_created`，之后必须报 `match`；改窗口尺寸或改 UI 用 `E2E_UPDATE_BASELINES=1` 重冻。
- **光标守卫**：默认 `MACOS_E2E_GUARD=all`，会因本人真实移动鼠标而 `FocusViolation`；本人正在用机器时用 `MACOS_E2E_GUARD=frontmost`（只跳过光标比较，仍验证 App 没有被激活）。
- **已知断言盲区**：文件行（`RepositoryFilePanel`）的 `file-<item.id>` identifier 被外层 section 的 identifier 吞掉，AX 只能按行文本（值）定位，且行没有 `AXPress`，用例改为按 role+frame 从 driver 快照取 token 后后台点击。行 identifier 恢复后可直接 `driver.press(identifier="file-changed:<path>")`。
- **UI 边界**：产品没有分支列表和提交历史列表，二者无法用 AX 断言；端到端覆盖仓库扫描、三段文件分组、提交区、全部变动折叠列表、单文件展开与二进制拒绝说明（2.3）。`diff-file-<item.id>` 暴露“已展开 / 已折叠”，每条用例前还会强制校准整窗尺寸，避免系统布局时机造成像素基线漂移。

---

## 五、关联文档

- [`docs/AI_COMMIT_GUIDE.md`](AI_COMMIT_GUIDE.md)：AI commit 生成链路与真实提交流程接入。
- [`docs/OPERATIONS_GUIDE.md`](OPERATIONS_GUIDE.md)：构建、启动验证、常见阻碍排查。
- [`docs/LIGHTWEIGHT_RESEARCH.md`](LIGHTWEIGHT_RESEARCH.md)：差异展示技术路线的调研结论、原生方案的最终决策、把关结果与遗留问题。

<!-- 该文档整理/压缩于 2026-10-21 -->