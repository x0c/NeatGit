# NeatGit 核心知识库

> 覆盖范围：NeatGit 核心功能（仓库扫描、文件状态、Diff、提交流程、Monaco 渲染、状态管理）的业务规则、代码入口、隐性约束与验证路径。

---

## 产品北极星

NeatGit 是面向 macOS 的原生 Git 客户端（SwiftUI 构建）。核心循环：扫描本地 Git 仓库 → 查看文件状态与 diff → 填写 commit message（可 AI 生成）→ 提交/推送。目标用户是 macOS 开发者，优先覆盖高频 Git 操作，不做臃肿全能客户端。

---

## 一、目录结构与领域划分

```
NeatGitApp/
├── Domain/           # 纯数据模型，无 I/O
│   ├── GitRepository.swift          # 仓库实体（路径/名称/ID）
│   ├── RepositoryFileModels.swift   # 文件状态模型（FileSection / FileItem / FileState）
│   ├── RepositoryDiffModels.swift   # Diff 相关模型（DiffMode / DiffDocument / DiffHunk）
│   ├── RepositoryGroup.swift       # 左侧栏分组模型
│   ├── ChangeKind.swift            # 文件分类枚举 + 权重
│   ├── DiffLineStat.swift          # diff 行统计 + numstat 解析
│   ├── CommitMessageCandidate.swift # 结构化输出模型 + JSON 解码
│   ├── LLMProviderConfiguration.swift # LLM 配置值对象
│   ├── CommitExclusion.swift       # .gitignore 硬排除逻辑（共享）
│   └── CommitGenerationStrategy.swift # 生成策略枚举 + 阈值
├── Services/         # 纯副作用层，不持有状态
│   ├── GitCommandSupport.swift      # Git 进程执行基础设施（核心）
│   ├── GitRepositoryScanner.swift   # 扫描 Home 目录下的 Git 仓库
│   ├── GitRepositoryStatusLoader.swift  # 读取仓库 git status
│   ├── GitRepositoryDiffLoader.swift    # 加载并解析文件 diff
│   ├── GitRepositoryCommitService.swift # 提交 / 推送
│   ├── GitIgnoreWriter.swift            # 写 .gitignore
│   ├── CommitMessageGenerationService.swift  # AI commit 协调层（策略选择 + 编排）
│   ├── CommitDiffAnalyzer.swift      # diff 分析、摘要、symbol 提取
│   ├── CommitPromptBuilder.swift     # prompt 构建 + 摘要/guidance/signals
│   ├── LLMChatService.swift          # OpenAI 兼容 API 调用 + response_format
│   ├── BundleStaticFileServer.swift     # 本地 HTTP 服务（Monaco 静态资源）
│   └── KeychainSecretStore.swift        # Keychain 读写（LLM API Key）
├── Stores/           # @Observable 状态容器，运行在 @MainActor
│   ├── RepositoryStore.swift        # 全局仓库列表 + 扫描状态 + 星标
│   ├── RepositoryStatusStore.swift  # 当前仓库文件状态快照
│   ├── RepositoryDiffStore.swift    # 当前选中文件 diff（含预取缓存）
│   ├── LLMSettingsStore.swift       # LLM 配置（持久化到 UserDefaults）
│   └── AICommitDebugStore.swift     # AI 生成调试日志（含策略标记）
├── Views/            # SwiftUI 视图层
│   ├── Sidebar/      # 左栏：仓库列表与分组
│   ├── RepositoryStatus/ # 中栏：文件状态面板 + 右栏：预览/diff
│   ├── Diff/         # MonacoDiffView（WKWebView 封装）
│   ├── Commit/       # 底部提交栏 + AI 调试窗口
│   └── Settings/     # LLM 配置设置页
├── ContentView.swift # 主窗口骨架（NavigationSplitView + HSplitView）
└── NeatGitApp.swift  # App 入口，Window Group + WindowScene 配置

Web/MonacoDiff/       # Vite + Monaco 前端，构建产物内嵌到 Bundle
└── src/main.js       # Monaco Diff Editor 初始化 + window.neatGit.setDiff() 协议
```

---

## 二、核心业务规则与隐性约束

### 2.1 Git 命令执行基础设施

**唯一入口**：`GitCommandRunner`（`NeatGitApp/Services/GitCommandSupport.swift`）。

- 所有 Git 子命令必须通过 `GitCommandRunner.run(in:arguments:standardInputData:)` 执行，不要在新 Service 里复制粘贴 `Process + Pipe + terminationStatus` 模板。
- `GitCommandError.describe(_:)` 是唯一的 Git 错误格式化方法；UI 层展示 Git 错误时统一调用它。
- 错误信息字符串均为中文，新增时保持一致。

### 2.2 文件状态模型

`RepositoryFileSection`（枚举，3 种）：

| case | 含义 | 提交逻辑 |
|------|------|---------|
| `changed` | 有变更的 tracked/untracked 文件 | 默认参与提交（除 .gitignore 文件） |
| `skipped` | skip-worktree 文件 | 不参与提交 |
| `ignored` | .gitignore 忽略的文件 | 不参与提交 |

**`RepositoryFileItem.isCheckableForCommit`**：只有 `section == .changed && !hasConflict` 的文件才能被加入提交。

**gitStatusCode**：两字符字符串（`XY`），`indexStatusCode = X`（暂存区状态），`workTreeStatusCode = Y`（工作区状态）。重命名/复制文件的原路径记在 `previousPath`。

### 2.3 Diff 当前边界（2026-06）

**单文件文本 diff 完整约束**：

- 只支持单文件、文本内容。
- 最大文件大小：750 KB（`maxTextBytes = 750_000`，`GitRepositoryDiffLoader`）。判断时机在 `loadOriginalData` / `loadModifiedData` 之后、`isBinaryData` 检测之前，取 `max(originalData.count, modifiedData.count) > maxTextBytes`，超过则抛出 `GitCommandError`（"文件过大，第一版暂不展示超过 750 KB 的文本 diff。"）。
- 前置守卫顺序（`makeDocument` 方法内）：① `section == .changed` 检查 → ② `hasConflict` 检查 → ③ `availableDiffModes.contains(mode)` 检查 → ④ 文件大小检查 → ⑤ 二进制检测。任一不满足立即 throw，不会继续执行后续步骤。

**二进制文件处理**：

- 检测方式：`isBinaryData(_:)` 方法检查 `Data` 中是否包含 null byte（`data.contains(0)`）。对 original 和 modified 两侧数据分别检测，任一侧命中即判定为二进制。
- 返回结果：抛出 `GitCommandError`（"当前只支持文本 diff，二进制文件稍后再接。"），由 `RepositoryDiffStore.applyFailure(_:)` 格式化后展示在 UI 占位区域。
- UI 展示：`ContentUnavailableView` 显示错误标题和 `GitCommandError.describe(_:)` 格式化后的中文消息。
- 注意：null byte 检测是简单启发式，不依赖 `git diff --stat` 的 `-Binary` 标记，也不检查文件扩展名。UTF-8 编码的纯文本不会包含 null byte，但某些特殊编码（如 UTF-16）的文本文件会被误判为二进制。

**冲突文件处理**：

- 检测方式：`item.hasConflict == true` 时，在 `makeDocument` 最前面的 guard 阶段拦截（第 25–27 行）。
- 拒绝原因：冲突文件的内容中包含 conflict markers（`<<<<<<<` / `=======` / `>>>>>>>`），Monaco 侧-by-side diff 会将这些 marker 当作普通文本渲染，无法表达三方合并语义，容易误导用户。当前选择直接拒绝展示，而非展示带 marker 的原始文本。
- 返回结果：抛出 `GitCommandError`（"冲突文件的可视化 diff 还没接入。"）。

**多文件汇总 diff**：

- 尚未实现。`RepositoryDiffStore.select()` 在 `selectedFiles.count != 1` 时会显示占位提示（"暂不支持多文件对照" / "当前已选中 N 个文件。第一版先聚焦单文件 diff。"）。
- 扩展时的设计约束：
  - `RepositoryDiffDocument` 当前是单文件模型（一个 `filePath` + 一组 `originalText/modifiedText`），多文件汇总需要新模型（例如 `RepositoryDiffDocumentCollection` 或在现有模型上增加文件索引），或改变 `displayedDocument` 的语义。
  - `MonacoDiffPayload` 也是单文件协议，多文件需要考虑：一次注入多个 diff 还是切换 tab 逐个注入；Monaco DiffEditor 实例是否支持同时展示多文件。
  - `cachedDocuments` 的 `CacheKey` 已按 `(repositoryID, itemID, mode)` 三元组索引，多文件汇总的缓存 key 需要额外设计（例如基于选中文件集合的 fingerprint）。

**Monaco 渲染约束**：

- 响应式布局：宽度 < 960px（`INLINE_DIFF_BREAKPOINT`，`main.js:33`）时自动切换 inline mode（`renderSideBySide: false` + `experimental.useTrueInlineView: true`），通过 `ResizeObserver` 监听容器宽度变化。
- WebView 就绪回调机制：`main.js` 末尾通过 `window.webkit.messageHandlers.neatGitReady.postMessage({ ready: true })` 向 Swift 端发送就绪信号；Swift 端 `Coordinator` 注册 `WKScriptMessageHandler`（handler name = `"neatGitReady"`），收到后设置 `isReady = true`，此后 `renderIfPossible()` 才会执行 `evaluateJavaScript("window.neatGit.setDiff(...)")`。`isReady == false` 时，payload 会暂存在 `pendingPayload`，等就绪后再渲染。
- 去重机制：`Coordinator` 维护 `lastRenderedPayload`，与 `pendingPayload` 做 `Equatable` 比较，相同则跳过注入，避免 WebView 重复渲染。
- `useInlineViewWhenSpaceIsLimited` 初始设为 `false`，响应式切换由 `applyResponsiveLayout()` 自行控制，不依赖 Monaco 内置的自动切换。

### 2.4 Diff 加载流程

```
RepositoryDiffStore.loadDiff(for:in:)
  └─ GitRepositoryDiffLoader.loadDiff(for:in:mode:)
       ├─ loadOriginalData()    # HEAD blob 或 index blob（git show / git cat-file）
       ├─ loadModifiedData()    # 工作区文件 或 index blob
       └─ loadHunks()           # git diff 解析 @@ 行
           └─ MonacoDiffView.setDiff()  # JS 注入 window.neatGit.setDiff(payload)
```

`RepositoryDiffStore` 有预取缓存（最多 12 条，60ms 悬停延迟触发），减少 hover 时的加载感。

### 2.5 提交流程（index 同步机制）

`GitRepositoryCommitService.perform(_:)` 提交前会自动同步 index：

1. 把**不在提交列表但已暂存**的文件 `restore --staged`（取消暂存）。
2. 把**在提交列表但未暂存**的 untracked / 有未暂存变更文件 `add -A`（暂存）。
3. 最后 `commit -m <message>`。

路径通过 stdin 传入（`--pathspec-from-file=- --pathspec-file-nul`），避免路径含空格的问题。

**隐性约束**：`.gitignore` 文件被 `shouldExcludeFromDefaultCommit` 硬排除，不会默认加入提交。

### 2.6 AI commit message 生成

调用链：`CommitComposerBar` → `CommitMessageGenerationService`（协调层）

- LLM 调用参数来自 `LLMSettingsStore`：`baseURL` / `apiKey` / `model`，全部持久化到 `UserDefaults`。
- `CommitMessageGenerationService` 是薄协调层，编排 `CommitDiffAnalyzer`（diff 分析）、`CommitPromptBuilder`（prompt 构建）和 `LLMChatService`（API 调用）。
- 支持两种生成策略（`CommitGenerationStrategy`）：
  - `.singlePass`：单次调用，适用于小 diff
  - `.twoStepMapReduce`：Map（每文件并行摘要）+ Reduce（汇总生成），适用于大 diff（文件数 > 15 或 diff 行数 > 500）
- 结构化输出：`CommitMessageCandidate` 解码 LLM JSON 响应（`type`/`scope`/`subject`/`body`），通过 `composedMessage` 组装为完整 commit message（含 body）。
- `ChangeKind` 分类逻辑已移到 `Domain/ChangeKind.swift`（public），权重影响 prompt 详略。
- `.gitignore` 排除逻辑统一到 `CommitExclusion.shouldExcludeFromDefaultCommit`，`CommitDiffAnalyzer` 和 `GitRepositoryCommitService` 共用。
- 调试日志通过 `AICommitDebugStore` 记录（含策略标记），可在 `AICommitDebugWindowView` 中查看。

### 2.7 Monaco Diff 渲染链路

```
BundleStaticFileServer（本地 NWListener HTTP 服务）
   └─ 提供 Web/MonacoDiff/dist/ 静态资源
MonacoDiffView（WKWebView）
   └─ 加载 http://127.0.0.1:<port>/index.html
   └─ JS 注入 window.neatGit.setDiff(payload)
       └─ main.js: originalModel / modifiedModel 更新
       └─ 响应式布局：宽度 < 960px 切换 inline mode
WKScriptMessage（neatGitReady）
   └─ WebView 就绪后 Swift 端收到回调
```

**注意**：`BundleStaticFileServer` 是单例（`shared`），随 App 启动时初始化，必须在 MonacoDiffView 访问之前完成启动。端口号随机，WebView URL 来自 `BundleStaticFileServer.baseURL`。

### 2.8 状态管理规范

- `RepositoryStore`、`RepositoryStatusStore`、`LLMSettingsStore` 使用 `@MainActor + @Observable`，在 View 中用 `@State` 持有。
- `RepositoryDiffStore` 目前仍用 `ObservableObject + @Published`（待迁移）。
- 后台任务用 `Task.detached(priority: .userInitiated)`；不要在新代码里用 `DispatchQueue.global().async`。

### 2.9 仓库扫描约束

`GitRepositoryScanner`：
- 从 `FileManager.default.homeDirectoryForCurrentUser` 开始，递归深度 **6 层**。
- 跳过：`.Trash`、`.cache`、`.gradle`、`.m2`、`node_modules`、`vendor`、`Pods`、`.Xcode`、`DerivedData` 等常见缓存和依赖目录。
- 并发度：`TaskGroup` 并行子目录，无额外限制。

---

## 三、AI 易错点

1. **修改 diff 功能前**，注意 `RepositoryPreviewPane.swift` 故意用了朴素的 `task(id:)` 刷新方式，原因是 Xcode 26.3 / Swift 6.2 下复杂 `onChange` / `Binding` 会触发编译器崩溃（见 AGENTS.md §3.1）。
2. **新增 Git 命令**，必须走 `GitCommandRunner`，不要直接用 `Process`。
3. **处理路径含空格的文件**，必须通过 `--pathspec-from-file=- --pathspec-file-nul` 传入，不要在参数数组里直接拼路径字符串。
4. **扩展提交流程**，注意 index 同步逻辑：如果只 stage 增量文件而不 unstage 已排除的暂存文件，会导致意外提交。
5. **Monaco WebView**，不要在 `BundleStaticFileServer` 尚未就绪时访问 `baseURL`，否则 WebView 加载空白页。
6. **Swift 6 并发隔离**：改动 Store、Binding、异步任务捕获时，先按 actor 边界思考，再动手，不要等编译器报错后再补 `@Sendable` 标注。
7. **扩展二进制 diff 时**，注意当前 null byte 检测（`isBinaryData` → `data.contains(0)`）位于 `GitRepositoryDiffLoader.makeDocument` 内、文件大小检查之后、文本解码之前。如果改为基于文件扩展名或 `git diff --stat` 的 `-Binary` 标记来检测，需要同时调整这个守卫的位置和逻辑，否则会出现大文件先被 size guard 拦截、小二进制文件仍走 null byte 检测的不一致路径。另外，UTF-16 等含 null byte 的非 UTF-8 纯文本会被误判为二进制，扩展时需考虑是否引入编码嗅探。
8. **多文件 diff 扩展时**，`RepositoryDiffStore` 的整个缓存模型是单文件语义——`CacheKey` 由 `(repositoryID, itemID, mode)` 三元组构成，`displayedDocument` 和 `document` 都是单个 `RepositoryDiffDocument?`。如果直接在 `select()` 里拼多个文件的内容塞进同一个 `RepositoryDiffDocument`，会导致 `filePath` 语义丢失、缓存 key 冲突、`languageHint` 只能取一种语言。正确做法是先设计多文件聚合模型（或在 `RepositoryDiffDocument` 上增加文件索引层），再同步改造 `CacheKey`、`MonacoDiffPayload` 和 `MonacoDiffView` 的注入协议。
9. **修改 Monaco 注入协议时**，`window.neatGit.setDiff()` 是 Swift 端（`MonacoDiffView.Coordinator.renderIfPossible()`）与 JS 端（`main.js` `window.neatGit.setDiff`）之间的唯一数据通道。增加新字段（如冲突标记、二进制标识、多文件索引）时，必须同步更新三处：① `MonacoDiffPayload`（Swift 侧 `Encodable` 结构体）② `main.js` 中的 `setDiff(payload)` 函数体 ③ `MonacoDiffView.Coordinator` 中的 `evaluateJavaScript` 调用。漏改任何一处都会导致新字段静默丢失，不会报编译错误。
10. **修改 diff 预览刷新机制时**，`RepositoryPreviewPane` 用 `task(id: selectionSignature)` 和 `task(id: hoverPrefetchSignature)` 两条独立链路驱动刷新，而非 `onChange`。这是有意为之——Xcode 26.3 / Swift 6.2 下该视图叠加复杂 `onChange` / `Binding` 会触发编译器崩溃。如果需要增加新的刷新触发条件（如 diff mode 切换按钮），优先扩展 `selectionSignature` 的计算逻辑，不要引入额外的 `onChange`。

---

## 四、验证路径

- **本地构建**：`xcodegen generate && xcodebuild -scheme NeatGit -configuration Debug` 或直接用 Xcode 打开 `NeatGit.xcodeproj`。
- **工程配置变更**（新增/删除/移动 Swift 文件）：必须先改 `project.yml`，再 `xcodegen generate`，不要只手改 xcodeproj。
- **Monaco 前端变更**：`cd Web/MonacoDiff && npm run build`，构建产物复制到 `NeatGitApp/Resources/MonacoDiff/`。

---

## 五、关联文档

- [`docs/AI_COMMIT_GUIDE.md`](AI_COMMIT_GUIDE.md)：AI commit 生成链路与真实提交流程接入。
- [`docs/OPERATIONS_GUIDE.md`](OPERATIONS_GUIDE.md)：构建、启动验证、常见阻碍排查。
