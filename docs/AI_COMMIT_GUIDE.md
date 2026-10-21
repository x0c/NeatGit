# AI Commit Message 生成指南

> 覆盖范围：AI commit message 生成链路（CommitMessageGenerationService、CommitDiffAnalyzer、LLM 配置、ChangeKind 分类、结构化输出、调试窗口）及真实提交流程接入指引。

---

## 一、当前实现状态（2026-06）

| 功能 | 状态 |
|------|------|
| AI 生成 commit message（调用 LLM） | 已实现 |
| 结构化 JSON 输出（type/scope/subject/body） | 已实现（`CommitMessageCandidate` + `response_format: json_object`） |
| 真实 Git 提交（`git commit`） | 已实现（`GitRepositoryCommitService.run(_:)`） |
| 真实 Git 推送（`git push`） | 已实现（同上，`action == .commitAndPush` 时执行） |
| AI 调试窗口（查看 prompt / response） | 已实现 |

---

## 二、调用链

```
CommitComposerBar（视图）
  └─ 触发 AI 生成 → CommitMessageGenerationService.generateMessage(for:)
       ├─ 读取 RepositoryStatusStore.snapshot（文件列表）
       ├─ CommitDiffAnalyzer.analyze() → CommitAnalysisContext
       │    ├─ 过滤 committableItems（CommitExclusion.shouldExcludeFromDefaultCommit）
       │    ├─ 加载 diff stats（git diff --numstat）
       │    ├─ 选择详细分析项（按 FileAnalysis.score 排序）
       │    ├─ 加载 diff snippets（git diff / diff --cached）
       │    ├─ 提取 symbol hints
       │    └─ 构建 summary/guidance/signals（委托 CommitPromptBuilder）
       ├─ CommitPromptBuilder.buildUserPrompt()
       ├─ LLMChatService.complete(responseFormat: .jsonObject)
       └─ CommitMessageCandidate.decode() → composedMessage
       └─ 写入 AICommitDebugStore（调试日志）

CommitComposerBar（视图）
  └─ 触发提交 → ContentView.runCommitAction(_:)
       ├─ 构建 GitCommitRequest（repository + message + snapshot.changedFiles + action）
       ├─ 调用 GitRepositoryCommitService.run(_:)（Task.detached, .userInitiated 优先级）
       │    ├─ 1. 校验 message 非空
       │    ├─ 2. 过滤 committableItems（isCheckableForCommit && !CommitExclusion.shouldExcludeFromDefaultCommit）
       │    ├─ 3. synchronizeIndex — 先 unstage 再 stage（详见§八）
       │    ├─ 4. ensureCommitHasStagedChanges
       │    ├─ 5. git commit -m <message>
       │    └─ 6. 若 action == .commitAndPush → git push（失败不回滚 commit）
       ├─ 成功：清空 commitMessage + statusStore.refreshCurrentRepository()
       └─ 失败：展示 CommitAlert
```

---

## 三、代码结构

| 文件 | 职责 |
|------|------|
| `Domain/ChangeKind.swift` | 文件分类枚举 + 权重（public） |
| `Domain/DiffLineStat.swift` | diff 行统计 + numstat 解析（public） |
| `Domain/CommitMessageCandidate.swift` | 结构化输出模型 + JSON 解码 + composedMessage（public） |
| `Domain/LLMProviderConfiguration.swift` | LLM 配置值对象（public） |
| `Domain/CommitExclusion.swift` | .gitignore 硬排除逻辑（共享） |
| `Services/LLMChatService.swift` | OpenAI 兼容 API 调用 + response_format 支持 |
| `Services/CommitDiffAnalyzer.swift` | diff 加载、condensation、symbol 提取、FileAnalysis 评分 |
| `Services/CommitPromptBuilder.swift` | prompt 构建 + 摘要/guidance/signals 计算 |
| `Services/CommitMessageGenerationService.swift` | 薄协调层：分析 → 构建 prompt → 单次 LLM 调用 |
| `Stores/AICommitDebugStore.swift` | 调试日志存储 |

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

## 五、结构化输出

### JSON Schema

```json
{
  "type": "feat | fix | refactor | docs | chore | test | null（默认 system prompt 限定六类；解码接受任意字符串）",
  "scope": "短模块名 | null",
  "subject": "单行摘要，≤72 字符",
  "body": ["0-3 条要点"],
  "confidence": 0.0,
  "reasons": ["1-2 条依据"]
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

JSON 解析失败时：响应以 `{` 开头 → 抛错「AI 返回了不完整或无法解析的 JSON」（常见于截断）；非 JSON 纯文本 → 退回首行文本（与旧逻辑兼容）。

---

## 六、ChangeKind 分类与文件评分

`ChangeKind.classify(for:)`（`Domain/ChangeKind.swift`）将变更文件分为 6 类：

| ChangeKind | 匹配规则 | analysisWeight | detailWeight |
|-----------|---------|---------------|-------------|
| `sourceCode` | 非测试/配置/文档/资源的代码文件 | +48 | +40 |
| `testCode` | 测试目录/测试文件名 | -22 | -18 |
| `configuration` | 配置文件（*.json, *.yml, *.plist 等） | +18 | +14 |
| `documentation` | *.md, *.txt 等 | -36 | -32 |
| `resource` | 图片、字体、静态资源 | -18 | -14 |
| `other` | 其他 | 0 | 0 |

`FileAnalysis.score` 综合 diffStat、ChangeKind.analysisWeight、moduleWeight、statusWeight、symbolHints、snippet 是否存在等因素，决定文件在 prompt 中的排列顺序与是否被选入详细分析。

---

## 七、AI 调试窗口

`AICommitDebugWindowView` 展示每次 AI 生成的：
- 每轮请求的标题、systemPrompt、userPrompt、rawResponse、errorMessage
- 最终结果或错误信息

---

## 八、扩展真实提交流程的注意事项

1. **必须调用 `GitRepositoryCommitService.run(_:)`**，不要绕过它直接调 `git commit`。
2. **index 同步机制的顺序不可颠倒**：`synchronizeIndex` 先 `git restore --staged`，再 `git add -A`。
3. **文件路径相关的 Git 命令（含新增命令）必须使用 `--pathspec-from-file=- --pathspec-file-nul`**，正确处理路径含空格的文件。
4. **`.gitignore` 文件的硬排除**：统一使用 `CommitExclusion.shouldExcludeFromDefaultCommit(_:)`（`Domain/CommitExclusion.swift`），不要在各处重复实现。
5. **push 失败不回滚 commit**。
6. **提交后 UI 状态刷新**：commit 成功后必须 `statusStore.refreshCurrentRepository()`。
7. **`GitCommitRequest.changedItems` 传入完整 `snapshot.changedFiles`**：不要在 View 层预过滤。

---

## 九、AI 易错点

1. **apiKey 持久化统一走 `LLMSettingsStore`**（UserDefaults `llm.apiKey`）；不要在 View 层直接读写 UserDefaults，也不要迁回 `KeychainSecretStore`（遗留代码，LLM 设置已不再读取 Keychain）。
2. **LLM baseURL 必须包含 scheme**（`https://`），`LLMChatService` 不会自动补全。
3. **扩展 ChangeKind 分类**时，注意 weight 的数值对 prompt token 预算有直接影响。
4. **`response_format: json_object` 不是所有 LLM 都支持**：如果遇到不支持该参数的 API，LLMChatService 会在请求体中附带该字段，API 端忽略即可，不会报错；但如果 API 端严格校验导致 400，需要在 LLMChatService 层做兼容。
5. **DeepSeek V4（`deepseek-v4-flash` / `deepseek-v4-pro`）默认开启 thinking**：`reasoning_content` 与最终 `content` 共享 `max_tokens`。若不关闭 thinking，复杂 diff 下常见 `finish_reason=length`，表现为半截 JSON 或空 content，UI 会报「空内容 / 无法解析的 JSON」。`LLMChatService` 对 DeepSeek host/model 会自动附带 `thinking: { type: "disabled" }`；commit 生成路径还会显式 `disableThinking: true` 与 `maxTokens: 1024`。

<!-- 该文档整理/压缩于 2026-10-21 -->
