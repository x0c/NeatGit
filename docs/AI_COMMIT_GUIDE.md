# AI Commit Message 生成指南

> 覆盖范围：AI commit message 生成链路（CommitMessageGenerationService、二阶段 Map-Reduce 策略、LLM 配置、ChangeKind 分类、结构化输出、调试窗口）及真实提交流程接入指引。

---

## 一、当前实现状态（2026-06）

| 功能 | 状态 |
|------|------|
| AI 生成 commit message（调用 LLM） | 已实现 |
| 结构化 JSON 输出（type/scope/subject/body） | **已实现**（`CommitMessageCandidate` + `response_format: json_object`） |
| 二阶段 Map-Reduce（大 diff 自动升级） | **已实现**（`CommitGenerationStrategy.twoStepMapReduce`） |
| 真实 Git 提交（`git commit`） | **已实现**（`GitRepositoryCommitService.run(_:)`） |
| 真实 Git 推送（`git push`） | **已实现**（同上，`action == .commitAndPush` 时执行） |
| AI 调试窗口（查看 prompt / response / 策略） | 已实现 |

> **扩展提交流程前必须阅读本文档**，避免忽略 index 同步机制导致意外提交内容。

---

## 二、调用链

```
CommitComposerBar（视图）
  └─ 触发 AI 生成 → CommitMessageGenerationService.generateMessage(for:)
       ├─ 读取 RepositoryStatusStore.snapshot（文件列表）
       ├─ CommitDiffAnalyzer.analyze() → CommitAnalysisContext
       │    ├─ 过滤 committableItems（CommitExclusion.shouldExcludeFromDefaultCommit）
       │    ├─ 加载 diff stats（git diff --numstat）
       │    ├─ 选择详细分析项（按 score 排序）
       │    ├─ 加载 diff snippets（git diff / diff --cached）
       │    ├─ 提取 symbol hints
       │    └─ 构建 summary/guidance/signals（委托 CommitPromptBuilder）
       ├─ 策略选择（resolveStrategy）
       │    ├─ 小 diff → .singlePass（单次调用）
       │    └─ 大 diff → .twoStepMapReduce（二阶段）
       ├─ 单次调用路径：
       │    ├─ CommitPromptBuilder.buildUserPrompt()
       │    ├─ LLMChatService.complete(responseFormat: .jsonObject)
       │    └─ CommitMessageCandidate.decode() → composedMessage
       ├─ 二阶段 Map-Reduce 路径：
       │    ├─ Map 阶段（TaskGroup 并行，每文件独立摘要）
       │    │    ├─ CommitPromptBuilder.buildMapPhasePrompt()
       │    │    └─ LLMChatService.complete(temperature: 0.1, maxTokens: 150)
       │    ├─ Reduce 阶段（汇总所有文件摘要）
       │    │    ├─ CommitPromptBuilder.buildReducePhasePrompt()
       │    │    └─ LLMChatService.complete(responseFormat: .jsonObject)
       │    └─ CommitMessageCandidate.decode() → composedMessage
       └─ 写入 AICommitDebugStore（调试日志，含策略标记）

CommitComposerBar（视图）
  └─ 触发提交 → ContentView.runCommitAction(_:)
       ├─ 构建 GitCommitRequest（repository + message + snapshot.changedFiles + action）
       ├─ 调用 GitRepositoryCommitService.run(_:)（Task.detached, .userInitiated 优先级）
       │    ├─ 1. 校验 message 非空
       │    ├─ 2. 过滤 committableItems（isCheckableForCommit && !CommitExclusion.shouldExcludeFromDefaultCommit）
       │    ├─ 3. synchronizeIndex — 先 unstage 再 stage（详见§七）
       │    ├─ 4. ensureCommitHasStagedChanges
       │    ├─ 5. git commit -m <message>
       │    └─ 6. 若 action == .commitAndPush → git push（失败不回滚 commit）
       ├─ 成功：清空 commitMessage + statusStore.refreshCurrentRepository()
       └─ 失败：展示 CommitAlert
```

---

## 三、代码结构（重构后）

| 文件 | 职责 |
|------|------|
| `Domain/ChangeKind.swift` | 文件分类枚举 + 权重（public） |
| `Domain/DiffLineStat.swift` | diff 行统计 + numstat 解析（public） |
| `Domain/CommitMessageCandidate.swift` | 结构化输出模型 + JSON 解码 + composedMessage（public） |
| `Domain/LLMProviderConfiguration.swift` | LLM 配置值对象（public） |
| `Domain/CommitExclusion.swift` | .gitignore 硬排除逻辑（共享） |
| `Domain/CommitGenerationStrategy.swift` | 生成策略枚举 + 阈值配置 |
| `Services/LLMChatService.swift` | OpenAI 兼容 API 调用 + response_format 支持 |
| `Services/CommitDiffAnalyzer.swift` | diff 加载、condensation、symbol 提取、FileAnalysis |
| `Services/CommitPromptBuilder.swift` | prompt 构建 + 摘要/guidance/signals 计算 |
| `Services/CommitMessageGenerationService.swift` | 薄协调层：策略选择 + 编排单次/Map-Reduce |
| `Stores/AICommitDebugStore.swift` | 调试日志存储（含策略标记） |

---

## 四、LLM 配置

`LLMSettingsStore`（`NeatGitApp/Stores/LLMSettingsStore.swift`）：

| 配置项 | 存储位置 | UserDefaults key |
|--------|----------|-----------------|
| `baseURL` | UserDefaults | `llm.baseURL` |
| `model` | UserDefaults | `llm.model` |
| `apiKey` | UserDefaults | `llm.apiKey` |
| `systemPrompt` | UserDefaults | `llm.systemPrompt` |

默认 system prompt 定义在 `CommitPromptBuilder.defaultSystemPrompt`，要求 LLM 输出包含 `type`/`scope`/`subject`/`body` 的 JSON。

---

## 五、二阶段 Map-Reduce 策略

### 触发条件

`CommitGenerationStrategyThreshold.default`：文件数 > 15 或总 diff 行数 > 500 时自动升级。

### 流程

| 阶段 | 输入 | 输出 | 并发 | API 调用 |
|------|------|------|------|---------|
| Map | 每个文件的 diff snippet | 3-5 条要点摘要 | TaskGroup 并行 | N 次（每文件 1 次） |
| Reduce | 所有文件摘要汇总 | 最终 commit message JSON | 单次 | 1 次 |

### 降级

- Map 阶段单文件失败 → 跳过该文件，不重试
- 所有 Map 均失败 → 退回 singlePass 模式

### 扩展点

- `CommitGenerationStrategyThreshold` 可配置阈值
- 新增策略时扩展 `CommitGenerationStrategy` 枚举并在 `generateMessage` 中增加分派

---

## 六、结构化输出

### JSON Schema

```json
{
  "type": "feat | fix | refactor | docs | chore | test | style | perf | build | ci | null",
  "scope": "短模块名 | null",
  "subject": "单行摘要，≤72 字符",
  "body": ["0-5 条要点"],
  "confidence": 0.0,
  "reasons": ["1-3 条依据"]
}
```

### LLM 请求

通过 `LLMChatService.complete(responseFormat: .jsonObject)` 强制 LLM 输出合法 JSON，避免格式漂移。

### 解码与组装

`CommitMessageCandidate.decode(from:)` → `composedMessage` 属性组装为：
```
type(scope): subject

body[0]
body[1]
...
```

如果 JSON 解码失败，退回取首行文本（与旧逻辑兼容）。

---

## 七、ChangeKind 分类逻辑

`ChangeKind.classify(for:)`（`Domain/ChangeKind.swift`）将变更文件分为 6 类：

| ChangeKind | 匹配规则 | analysisWeight | detailWeight |
|-----------|---------|---------------|-------------|
| `sourceCode` | 非测试/配置/文档/资源的代码文件 | +48 | +40 |
| `testCode` | 测试目录/测试文件名 | -22 | -18 |
| `configuration` | 配置文件（*.json, *.yml, *.plist 等） | +18 | +14 |
| `documentation` | *.md, *.txt 等 | -36 | -32 |
| `resource` | 图片、字体、静态资源 | -18 | -14 |
| `other` | 其他 | 0 | 0 |

---

## 八、AI 调试窗口

`AICommitDebugWindowView` 展示每次 AI 生成的：
- 策略标签（单次调用 / 二阶段 Map-Reduce）
- 每轮请求的标题、systemPrompt、userPrompt、rawResponse、errorMessage
- 最终结果或错误信息

`AICommitDebugStore` 新增 `strategy` 字段，记录当次生成使用的策略。

---

## 九、扩展真实提交流程的注意事项

1. **必须调用 `GitRepositoryCommitService.run(_:)`**，不要绕过它直接调 `git commit`。
2. **index 同步机制的顺序不可颠倒**：`synchronizeIndex` 先 `git restore --staged`，再 `git add -A`。
3. **路径含空格文件的处理**：必须使用 `--pathspec-from-file=- --pathspec-file-nul`。
4. **`.gitignore` 文件的硬排除**：统一使用 `CommitExclusion.shouldExcludeFromDefaultCommit(_:)`（`Domain/CommitExclusion.swift`），不要在各处重复实现。
5. **push 失败不回滚 commit**。
6. **提交后 UI 状态刷新**：commit 成功后必须 `statusStore.refreshCurrentRepository()`。
7. **`GitCommitRequest.changedItems` 传入完整 `changedFiles`**：不要在 View 层预过滤。

---

## 十、AI 易错点

1. **不要在 View 层直接调 `KeychainSecretStore`**，统一通过 `LLMSettingsStore` 的写入方法持久化 apiKey。
2. **LLM baseURL 必须包含 scheme**（`https://`），`LLMChatService` 不会自动补全。
3. **扩展 ChangeKind 分类**时，注意 weight 的数值对 prompt token 预算有直接影响。
4. **Map-Reduce 阶段的 Map 是并行的**：修改 mapPhase 时注意并发安全，不要在 TaskGroup 内修改共享状态。
5. **`response_format: json_object` 不是所有 LLM 都支持**：如果遇到不支持该参数的 API，LLMChatService 会在请求体中附带该字段，API 端忽略即可，不会报错；但如果 API 端严格校验导致 400，需要在 LLMChatService 层做兼容。
6. **不要在 View 层预过滤 `changedItems`**：`GitCommitRequest.changedItems` 必须传入完整的 `snapshot.changedFiles`。
7. **新增文件路径相关的 Git 命令时必须使用 `--pathspec-from-file=- --pathspec-file-nul`**。
8. **CommitExclusion 统一到 Domain 层**：不要在 Service 或 View 层重新实现 `.gitignore` 排除逻辑。
