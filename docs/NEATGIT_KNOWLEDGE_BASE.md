# NeatGit 核心知识库

> 覆盖范围：NeatGit 核心功能（仓库扫描、文件状态、Diff、提交流程、Monaco 渲染、状态管理）的业务规则、代码入口、隐性约束与验证路径。

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
  - 2.3 Diff 当前边界（750 KB / 二进制 / 冲突 / 多文件 / Monaco 渲染 / 只看变更）
  - 2.4 Diff 加载流程
  - 2.5 仓库切换与零加载（SWR）机制
  - 2.6 提交流程（index 同步机制）
  - 2.7 AI commit message 生成
  - 2.8 Monaco Diff 渲染链路
  - 2.9 状态管理规范
  - 2.10 仓库扫描约束
  - 2.11 应用内更新与签名发布约束
- 三、AI 易错点（10 条）
- 四、验证路径
- 五、关联文档

---

## 界面与系统版本约定

- 最低支持 **macOS 26.0**，以 Xcode 26 的系统 SDK 构建，不再保留旧系统的界面兼容分支。
- 窗口、三栏导航、列表选择、工具栏、输入框、设置与弹窗优先使用 SwiftUI 系统控件；不遍历窗口内部视图改标题颜色，不自绘系统已有的选择态与折叠控件。
- 系统负责 Liquid Glass、浅色/深色外观与辅助功能适配；玻璃用于导航和操作区域，代码与表单正文保持清晰，不叠加装饰性玻璃。
- 差异预览保留 Monaco 的代码高亮和差异计算，通过 macOS 26 的 `WebView` / `WebPage` 集成。这里是明确的非全原生边界，不用功能不完整的自制文本对比替换它。
- Git、AI 和本地配置的业务语义不因 UI API 升级而改变。

依据：[Apple 新设计迁移指南](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)、[WWDC25 SwiftUI 新设计](https://developer.apple.com/videos/play/wwdc2025/323/)、[WWDC25 WebKit for SwiftUI](https://developer.apple.com/videos/play/wwdc2025/231/)。接口可用性以本机 Xcode 26 SDK 声明和实际构建为准。

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
│   ├── RepositoryDiffModels.swift   # Diff 相关模型（DiffMode / DiffDocument / MonacoDiffPayload）
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
│   ├── AppUpdater.swift                     # Sparkle 应用内更新桥接（温和提醒）
│   ├── CommitDiffAnalyzer.swift      # diff 分析、摘要、symbol 提取
│   ├── CommitPromptBuilder.swift     # prompt 构建 + 摘要/guidance/signals
│   ├── LLMChatService.swift          # OpenAI 兼容 API 调用 + response_format
│   ├── BundleStaticFileServer.swift     # 本地 HTTP 服务（Monaco 静态资源）
│   └── KeychainSecretStore.swift        # Keychain 读写（LLM API Key）
├── Stores/           # @Observable 状态容器，运行在 @MainActor
│   ├── RepositoryStore.swift        # 全局仓库列表 + 扫描状态 + 星标
│   ├── RepositoryStatusStore.swift  # 当前仓库文件状态快照（跨仓库 SWR 缓存 + 悬停预取）
│   ├── RepositoryDiffStore.swift    # 当前选中文件 diff（含预取缓存）
│   ├── LLMSettingsStore.swift       # LLM 配置（持久化到 UserDefaults）
│   └── AICommitDebugStore.swift     # AI 生成调试日志（含策略标记）
├── Views/            # SwiftUI 视图层
│   ├── Sidebar/      # 左栏：仓库列表与分组
│   ├── RepositoryStatus/ # 中栏：文件状态面板 + 右栏：预览/diff
│   ├── Diff/         # MonacoDiffView（macOS 26 WebView / WebPage）
│   ├── Commit/       # 底部提交栏 + AI 调试窗口
│   └── Settings/     # LLM 配置设置页
├── ContentView.swift # 原生三栏 NavigationSplitView + safeAreaBar
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

**gitStatusCode**：两字符字符串（`XY`），`indexStatusCode = X`（暂存区状态），`workTreeStatusCode = Y`（工作区状态）。重命名/复制文件的原路径记在 `previousPath`。

### 2.3 Diff 当前边界（2026-06）

**单文件文本 diff 完整约束**：

- 只支持单文件、文本内容。
- 最大文件大小：750 KB（`maxTextBytes = 750_000`，`GitRepositoryDiffLoader`）。判断时机在 `loadOriginalData` / `loadModifiedData` 之后、`isBinaryData` 检测之前，取 `max(originalData.count, modifiedData.count) > maxTextBytes`，超过则抛出 `GitCommandError`（"文件过大，第一版暂不展示超过 750 KB 的文本 diff。"）。
- 前置守卫顺序（`makeDocument` 方法内）：① `section == .changed` 检查 → ② `hasConflict` 检查 → ③ `availableDiffModes.contains(mode)` 检查 → ④ 文件大小检查 → ⑤ 二进制检测。任一不满足立即 throw，不会继续执行后续步骤。

**二进制文件处理**：

- 检测方式：`isBinaryData(_:)` 检查 `Data` 是否含 null byte（`data.contains(0)`），original / modified 任一侧命中即判二进制。不依赖 `git diff --stat` 的 `-Binary` 标记，也不看扩展名。
- 返回结果：抛出 `GitCommandError`（"当前只支持文本 diff，二进制文件稍后再接。"），由 `RepositoryDiffStore.applyFailure(_:)` 格式化后经 `ContentUnavailableView` + `GitCommandError.describe(_:)` 展示中文错误。

**冲突文件处理**：

- 检测方式：`item.hasConflict == true` 时在 `makeDocument` 最前的 guard 阶段拦截。
- 拒绝原因：冲突内容包含 conflict markers（`<<<<<<<` / `=======` / `>>>>>>>`），Monaco side-by-side 会把 marker 当普通文本渲染，无法表达三方合并语义，容易误导用户，故直接拒绝展示而非展示带 marker 的原文。
- 返回结果：抛出 `GitCommandError`（"冲突文件的可视化 diff 还没接入。"）。

**多文件汇总 diff**：

- 尚未实现。`RepositoryDiffStore.select()` 在 `selectedFiles.count != 1` 时会显示占位提示（"暂不支持多文件对照" / "当前已选中 N 个文件。第一版先聚焦单文件 diff。"）。
- 扩展时的设计约束：
  - `RepositoryDiffDocument` 当前是单文件模型（一个 `filePath` + 一组 `originalText/modifiedText`），多文件汇总需要新模型（例如 `RepositoryDiffDocumentCollection` 或在现有模型上增加文件索引），或改变 `displayedDocument` 的语义。
  - `MonacoDiffPayload` 也是单文件协议，多文件需要考虑：一次注入多个 diff 还是切换 tab 逐个注入；Monaco DiffEditor 实例是否支持同时展示多文件。
  - `cachedDocuments` 的 `CacheKey` 已按 `(repositoryID, itemID, mode)` 三元组索引，多文件汇总的缓存 key 需要额外设计（例如基于选中文件集合的 fingerprint）。

**Monaco 渲染约束**：

- 响应式布局：容器宽度 < 960px（`INLINE_DIFF_BREAKPOINT`，`main.js`）时自动切换 inline mode（`renderSideBySide: false` + `experimental.useTrueInlineView: true`），由 `ResizeObserver` 监听容器宽度。
- 就绪机制：`MonacoDiffController` 等待 `WebPage.load` 导航序列的 `.finished`，再验证 `setDiff` / `setAppearance` / `setChangesOnly` 三个 JS 入口。未就绪时只保存最新 payload。
- 注入与去重：`callJavaScript(arguments:)` 传 JSON 字符串，页面 `JSON.parse` 后调用 `setDiff`，不拼接源码到脚本。单一消费者串行更新，只在成功后记住 `lastRenderedPayload`；快速切换最终以最新值为准，重试/取消通过独立页面与 generation 隔离旧回调。
- 外观：SwiftUI 的 `colorScheme` / `colorSchemeContrast` 通过 `setAppearance(appearance, highContrast)` 同步；浅深色定制主题和高对比主题均保留变更标记。网页非持久化存储，仅 Debug 开启检查器。
- `useInlineViewWhenSpaceIsLimited` 初始设为 `false`，响应式切换由 `applyResponsiveLayout()` 自行控制，不依赖 Monaco 内置的自动切换。

**「只看变更」的实现边界**：

- 由 Monaco 的 `hideUnchangedRegions` 承担，内容通道始终注入全文。这样变更前后保留 3 行上下文（`UNCHANGED_CONTEXT_LINE_COUNT`）、行号保持真实值，折叠块还能点击或拖动展开。不要回到在 Swift 侧按 hunk 裁剪文本（旧做法）：那会丢掉上下文与真实行号。
- 开启 `hideUnchangedRegions.enabled` 只是让未变更区域「可折叠」，区域初始仍是展开态；必须额外调 `collapseAllUnchangedRegions()` 才会真折起。切文件或重算差异后区域会重建，所以 `onDidUpdateDiff` 里还要补一次折叠。
- 开关走独立的 `setChangesOnly` 通道，不进 `MonacoDiffPayload`。摆回内容 payload 会让每次切换重新序列化并注入整份文件，大文件下直接可见卡顿。

### 2.4 Diff 加载流程

```
RepositoryDiffStore.select / selectMode → loadCurrentSelection
  └─ GitRepositoryDiffLoader.loadDiff(for:in:mode:)
       └─ loadContents()      # 先定两侧来源（空 / Git 对象 / 工作区文件）
            ├─ GitCommandRunner.readObjects()  # Git 对象合并成一次 cat-file --batch
            └─ readWorkingTreeFile()           # 工作区侧直读文件
                 └─ MonacoDiffView.setDiff()   # JS 注入 window.neatGit.setDiff(payload)
```

读内容时不再额外跑 `git diff` 解析 `@@` 行：只看变更改由 Monaco 自己算未变更区域，hunk 模型已废弃。单文件 diff 因此只启动 1 个 git 进程（旧实现是 4–5 个），本机实测 2000 行文件的读取中位数约 15ms。

`RepositoryDiffStore` 有预取缓存（最多 24 条，60ms 悬停延迟触发）。双状态文件通过原生分段选择器切换暂存区/工作区，只读允许的模式；有暂存内容时默认显示暂存区。刷新版本号变化会清理该仓库缓存。

### 2.5 仓库切换与零加载（SWR）机制

`RepositoryStatusStore` 的核心约束（2026-10 引入）：

- **跨仓库快照缓存**：LRU 上限 10 个仓库（`maxCachedSnapshots`）。`load(for:)` 命中缓存时**同步立即显示旧快照**（零等待），随后后台静默刷新。
- **版本号纪律**：`applySnapshot` 中新旧快照 `Equatable` 相等时**不递增 `snapshotRevision`**——这是右侧 diff 缓存和选中态不被误清的前提；只有数据真实变化才递增。`RepositoryFileSnapshot` 因此必须保持 `Equatable`，新增字段时注意保持该语义。
- **刷新失败保留内容**：已有内容时 `applyFailure` 不清空 snapshot，只设置 errorMessage；`RepositoryFilePanel` 中 snapshot 展示优先级高于 errorMessage，错误降级为顶部栏提示。
- **悬停预取**：侧栏仓库行 `onHover` 进入时触发 `prefetch(for:)`，只填缓存不动 UI；选中时 `fetchSnapshot` 复用进行中的预取任务，同一仓库不会跑两遍 git status。
- **并行加载**：`GitRepositoryStatusLoader.loadSnapshot` 中 `git status` 与 `git ls-files` 通过 `async let` 并行执行，首次加载耗时从两者之和降为最大值。
- 回归测试：`NeatGitTests/RepositoryStatusStoreTests.swift`（缓存命中立即显示 / 无变化版本号稳定 / 有变化递增 / 失败保留内容 / 预取命中）。

### 2.6 提交流程（index 同步机制）

`GitRepositoryCommitService.perform(_:)` 提交前会自动同步 index：

1. 把**不在提交列表但已暂存**的文件 `restore --staged`（取消暂存）。
2. 把**在提交列表但未暂存**的 untracked / 有未暂存变更文件 `add -A`（暂存）。
3. 最后 `commit -m <message>`。

路径通过 stdin 传入（`--pathspec-from-file=- --pathspec-file-nul`），避免路径含空格的问题。

**隐性约束**：`.gitignore` 文件被 `shouldExcludeFromDefaultCommit` 硬排除，不会默认加入提交。

### 2.7 AI commit message 生成

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

### 2.8 Monaco Diff 渲染链路

```
MonacoResourceLoader（actor，后台复用启动任务）
   └─ BundleStaticFileServer 提供 Bundle.main.resourceURL 下的静态资源
MonacoDiffView → MonacoDiffController → WebView(page)
   └─ WebPage.load(http://127.0.0.1:<随机端口>/index.html)
   └─ 导航完成 + JS 入口验证
   └─ callJavaScript(arguments:) → setDiff / setAppearance
       └─ main.js 更新 originalModel / modifiedModel、外观与自适应布局
```

加载超时 15 秒、单次更新超时 10 秒会显示中文错误和重试入口，不以白屏吞掉错误。重试保留最新内容/外观但重建网页，避免旧调用覆盖新页面。静态资源服务的同步启动不在主线程执行。

### 2.9 状态管理规范

- 所有 store（含 `RepositoryDiffStore`）均使用 `@MainActor + @Observable`；视图用 `@State` 持有，任务/缓存用 `@ObservationIgnored` 排除无关重绘。
- 后台任务用 `Task.detached(priority: .userInitiated)`；不要在新代码里用 `DispatchQueue.global().async`。

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
3. **处理路径含空格的文件**，必须通过 `--pathspec-from-file=- --pathspec-file-nul` 传入，不要在参数数组里直接拼路径字符串。
4. **扩展提交流程**，注意 index 同步逻辑：如果只 stage 增量文件而不 unstage 已排除的暂存文件，会导致意外提交。
5. **Monaco WebView**，必须通过 `MonacoResourceLoader` 等静态服务就绪并等待导航完成后注入，不直接启动并发渲染任务。
6. **Swift 6 并发隔离**：改动 Store、Binding、异步任务捕获时，先按 actor 边界思考，再动手，不要等编译器报错后再补 `@Sendable` 标注。
7. **扩展二进制 diff 时**，注意当前 null byte 检测（`isBinaryData` → `data.contains(0)`）位于 `GitRepositoryDiffLoader.makeDocument` 内、文件大小检查之后、文本解码之前。如果改为基于文件扩展名或 `git diff --stat` 的 `-Binary` 标记来检测，需要同时调整这个守卫的位置和逻辑，否则会出现大文件先被 size guard 拦截、小二进制文件仍走 null byte 检测的不一致路径。另外，UTF-16 等含 null byte 的非 UTF-8 纯文本会被误判为二进制，扩展时需考虑是否引入编码嗅探。
8. **多文件 diff 扩展时**，`RepositoryDiffStore` 的整个缓存模型是单文件语义——`CacheKey` 由 `(repositoryID, itemID, mode)` 三元组构成，`displayedDocument` 和 `document` 都是单个 `RepositoryDiffDocument?`。如果直接在 `select()` 里拼多个文件的内容塞进同一个 `RepositoryDiffDocument`，会导致 `filePath` 语义丢失、缓存 key 冲突、`languageHint` 只能取一种语言。正确做法是先设计多文件聚合模型（或在 `RepositoryDiffDocument` 上增加文件索引层），再同步改造 `CacheKey`、`MonacoDiffPayload` 和 `MonacoDiffView` 的注入协议。
9. **修改 Monaco 注入协议时**，内容通道为 `MonacoDiffPayload` → `MonacoDiffController` 参数传递 → `window.neatGit.setDiff`；这三处和桥接测试一起更新。外观走独立 `setAppearance`、只看变更走独立 `setChangesOnly`，都不要混进文件内容缓存键——混进去的代价是每次切开关都重传整份文件。
10. **修改 diff 预览刷新机制时**，`RepositoryPreviewPane` 用 `task(id: selectionSignature)` 和 `task(id: hoverPrefetchSignature)` 两条独立链路驱动刷新，而非 `onChange`。这是有意为之——Xcode 26.3 / Swift 6.2 下该视图叠加复杂 `onChange` / `Binding` 会触发编译器崩溃。模式切换由小型 `Binding` 直接调用 store 的 `selectMode`；其他选择刷新仍扩展签名，不堆叠复杂 `onChange`。主窗口也把三栏、工具栏和状态监听拆成独立属性，避免 Xcode 26.3 的类型检查超时。

---

## 四、验证路径

- **本地构建**：`xcodegen generate && xcodebuild -scheme NeatGit -configuration Debug` 或直接用 Xcode 打开 `NeatGit.xcodeproj`。
- **工程配置变更**（新增/删除/移动 Swift 文件）：必须先改 `project.yml`，再 `xcodegen generate`，不要只手改 xcodeproj。
- **Monaco 前端变更**：`cd Web/MonacoDiff && npm run build` 直接生成到 `NeatGitApp/Resources/MonacoDiff/`。文件 hash 会变化，之后需在仓库根执行 `xcodegen generate` 更新工程资源列表，不另复制 dist。
- **回归**：`NeatGitTests` 覆盖原生控件、差异 store 和真实 WebView 桥接；`NeatGitUITests` 覆盖窗口点击路径。运行命令与锁屏限制见 [Operations 指南](OPERATIONS_GUIDE.md)。

---

## 五、关联文档

- [`docs/AI_COMMIT_GUIDE.md`](AI_COMMIT_GUIDE.md)：AI commit 生成链路与真实提交流程接入。
- [`docs/OPERATIONS_GUIDE.md`](OPERATIONS_GUIDE.md)：构建、启动验证、常见阻碍排查。

<!-- 该文档整理/压缩于 2026-10-21 -->
