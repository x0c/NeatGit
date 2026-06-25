# LLM 生成 Git Commit Message 行业调研

> 调研时间：2026-06 · 来源：GitHub 394 个相关仓库 + 主流 IDE 内置方案
> 目的：了解业界实现模式，为 NeatGit AI commit 功能演进提供参考

---

## 一、主流开源项目概览

| 项目 | Stars | 语言 | 核心特点 |
|------|-------|------|---------|
| **[opencommit](https://github.com/di-sukharev/opencommit)** | 7.3k | JS/TS | 功能最丰富，支持多 LLM provider + Ollama + GitHub Action |
| **[gptcommit](https://github.com/zurawiki/gptcommit)** | 2.4k | Rust | git hook 方式，多步 prompt 流水线 |
| **[gcop](https://github.com/Undertone0809/gcop)** | 196 | Python | 学习项目 commit 风格，20+ git 快捷命令 |
| **[llm-git](https://github.com/can1357/llm-git)** | 40 | Rust | map-reduce 分析、compose 拆分提交、history rewrite |
| **[aider](https://github.com/Aider-AI/aider)** | 30k+ | Python | AI pair programming 工具，自动生成 commit message |

---

## 二、三种核心实现架构

### 架构 1：单次调用（opencommit）

```
git diff --staged → 拼成一个 prompt → 一次 LLM 调用 → 完整 commit message
```

**Prompt 结构**（`src/prompts.ts`）：

```
System: You are to act as an author of a commit message in git.
        Your mission is to create clean and comprehensive commit messages
        as per the Conventional Commit Convention / GitMoji.
        I'll send you an output of 'git diff --staged' command...
        Use the present tense. Lines must not be longer than 74 characters.

User:   <示例 diff>

Assistant: <示例 commit message，如 fix: ... / feat: ...>
```

**优点**：简单直接，延迟低（1 次 API 调用）

**缺点**：大 diff 可能超 token 限制；一次性处理所有内容，对复杂变更容易遗漏或混淆

---

### 架构 2：多步流水线（gptcommit）

```
对每个变更文件:
  summarize_file_diff → "该文件改了什么"（≤5 条 bullet）

title_commit           → 汇总文件摘要 → commit title（≤50 字符）
summarize_commit       → 汇总文件摘要 → commit body（≤5 条 bullet）
conventional_commit    → 根据摘要 → 判断 commit type（feat/fix/refactor...）
```

**关键 Prompt 示例**：

**文件摘要**（`summarize_file_diff.tera`）：

```
You are an expert programmer summarizing the following git diff.
Produce concise bullet points describing the key changes.
List at most five points for brevity.
Use the imperative mood and start each line with `-`.
Exclude file names, diff markers and code snippets.
```

**标题生成**（`title_commit.tera`）：

```
You are an expert programmer generating a concise commit title.
Summarize the change in a single short sentence using the imperative mood.
Ignore file names and diff details.
Write only one line, no more than 50 characters.
```

**类型分类**（`conventional_commit.tera`）：

```
You are an expert programmer determining the best conventional commit label.
Choose one of the following labels:
- build / chore / ci / docs / feat / fix / perf / refactor / style / test
Respond with only the label best describing this change.
```

**优点**：分而治之，每个文件独立摘要，避免大 diff 截断；单文件摘要更精准

**缺点**：API 调用次数多（N+2 次），成本高；流水线延迟累加

---

### 架构 3：Map-Reduce（llm-git）

```
小 diff → fast 模式（单次调用，tool calling 输出结构化 JSON）

大 diff → map-reduce 模式:
  map 阶段:    每个文件并行分析 → 提取 observations（0-5 条/文件）
  reduce 阶段: 汇总所有 observations → 生成 type/scope/summary/details
```

**Map 阶段 Prompt**（`prompts/map/default.md`）：

```
<role>Expert code analyst extracting grounded observations from file diffs.</role>

<instructions>
Extract only factual observations supported by each current file diff.
For each file: Return 0-5 observations, past-tense verb + specific target.
Cover meaningful changes; omit formatting, comment-only, import-order changes.
</instructions>

<output_format>
Return exactly one `create_file_observations` payload with a `files` array.
Each item must use `path` exactly as shown in input, `observations` as string array.
</output_format>
```

**Reduce 阶段 Prompt**（`prompts/reduce/default.md`）：

```
You are a senior engineer synthesizing map-phase observations into one conventional commit analysis.

Determine: TYPE, SCOPE, SUMMARY, DETAILS, ISSUE_REFS, CHANGELOG.
Base the answer only on the provided observations — do not invent.

<scope_rules>
- Use scope_candidates as primary source.
- Use null when changes span multiple components or speculative.
- Valid scopes are short component names, ideally one word.
</scope_rules>

<synthesis_rules>
- Produce 3-4 strong grouped details when possible.
- Synthesize repeated file observations into shared behavior.
- Prefer broader, evidence-backed details over enumerating files.
</synthesis_rules>
```

**Fast 模式 Prompt**（`prompts/fast/default.md`）：

```
You are a senior engineer writing a conventional commit message.
Produce exactly one `create_fast_commit` call with `type`, optional `scope`, `summary`, and `details`.

Rules:
- type: best conventional commit type for dominant change
- scope: narrow lowercase module only when diff clearly supports it, null otherwise
- summary: specific past-tense phrase, no type prefix, no trailing period, ≤72 characters
- details: 0-3 past-tense sentences, each ending with a period
- Do not invent behavior not visible in the diff
```

**额外高级功能**：

- **Compose 模式**：大变更自动拆分为多个原子 commit
  - `compose-intent` 阶段：规划如何拆分
  - `compose-bind` 阶段：将文件/hunk 绑定到各 commit
- **Rewrite 模式**：批量重写 git 历史的 commit message（自动备份）
- **自动 CHANGELOG**：commit 后自动维护 CHANGELOG.md（支持 monorepo）

**优点**：最精准，结构化输出（tool calling），大 diff 处理优雅

**缺点**：实现复杂度高；依赖模型 tool calling 能力

---

## 三、关键技术决策对比

| 维度 | opencommit | gptcommit | llm-git | NeatGit（当前） |
|------|-----------|-----------|---------|---------------|
| **输入** | `git diff --staged` 整体 | 按文件拆分 diff | 按文件拆分 + git stat | 按文件拆分 + ChangeKind 权重 |
| **Prompt 策略** | 单次 end-to-end | N+2 步流水线 | map-reduce + tool calling | 单次调用 + 权重差异化 |
| **输出格式** | 纯文本 | 纯文本 | 结构化 JSON（tool calling） | 纯文本 |
| **大 diff 处理** | 截断到 max_tokens | 逐文件摘要 | map-reduce 并行分析 | 截断 + weight 压缩 |
| **Commit 规范** | Conventional / GitMoji / commitlint | Conventional | Conventional（可自定义 type） | Conventional |
| **本地模型** | Ollama / llama.cpp | 无 | LiteLLM proxy | 无 |
| **集成方式** | CLI / git hook / GitHub Action | git prepare-commit-msg hook | CLI | GUI 内嵌 |
| **语言支持** | 18+ 语言 i18n | en/zh-cn/zh-tw/ja | 跟随模型能力 | 跟随模型能力 |
| **风格学习** | 无 | 无 | 无 | 无 |

---

## 四、Prompt 设计的共同模式

所有成熟项目在 prompt 设计上遵循以下共同约束：

### 4.1 角色设定

```
You are an expert programmer / senior engineer ...
```

### 4.2 输入来源

- `git diff --staged`（最常见）
- `git diff`（unstaged 变更）
- `git stat`（文件变更统计）
- `git log`（历史 commit 风格参考）

### 4.3 核心约束

| 约束 | 出现频率 | 示例 |
|------|---------|------|
| 语气要求 | 100% | 祈使语气 (imperative) 或过去时 (past-tense) |
| 长度限制 | 100% | summary ≤ 50-72 字符，body ≤ 3-6 条 |
| 不编造 | 100% | "Do not invent behavior not visible in the diff" |
| 输出格式 | 100% | Conventional Commits 或 GitMoji |
| 排除噪声 | 80% | 排除 import 排序、格式化、纯注释变更 |

### 4.4 Few-shot 示例

大部分项目提供 1-2 个 diff → commit message 的示例，帮助模型理解期望格式：

```
// opencommit 的示例 diff
-const port = 7799;
+const PORT = 7799;
-app.listen(port, () => {
+app.listen(process.env.PORT || PORT, () => {

// 对应示例输出
fix(server): use environment variable for port configuration
```

### 4.5 可定制项

| 可定制项 | opencommit | gptcommit | llm-git |
|---------|-----------|-----------|---------|
| Commit 规范 | Conventional / GitMoji / commitlint | Conventional | 可自定义 type 描述 |
| 语言 | i18n 18+ 语言 | 4 种 | 跟随模型 |
| Emoji | 开关 + 完整 GitMoji | 无 | 无 |
| Scope | 可关闭 | 有 | 可自定义 scope 候选 |
| 描述 | 开关 + 3 句 WHY | 无 | 0-3 句 details |
| 模板 | `$msg` 占位符 | Tera 模板 | TOML 配置 |
| 忽略文件 | `.opencommitignore` | `file_ignore` 配置 | 无 |

---

## 五、主流 IDE / 工具内置方案

| 工具 | 实现方式 | 特点 |
|------|---------|------|
| **GitHub Copilot** | VS Code 内置，读取 staged diff | 一键生成，可编辑后提交 |
| **Cursor** | Source Control 面板内 AI 生成 | 与编辑器深度集成 |
| **Claude Code** | `claude commit` 命令 | 基于 Claude 分析 diff，支持自然语言上下文 |
| **JetBrains AI** | IDE 内置 commit message 生成 | 结合项目上下文和 VCS 集成 |
| **aider** | 自动 commit | AI pair programming 中自动生成并提交 |

闭源方案 prompt 不可见，但原理相同：读取 diff → LLM 生成 message。

---

## 六、对 NeatGit 的启示

### 6.1 当前实现的优势

NeatGit 当前的实现已有一些业界没有的独特设计：

- **ChangeKind 权重系统**：根据文件类型（sourceCode/testCode/configuration/documentation/resource）调整 prompt 详略，这比纯截断更优雅
- **GUI 内嵌**：作为原生 macOS Git 客户端内嵌功能，体验比 CLI 工具更自然
- **调试窗口**：可以查看 prompt/response，方便调优

### 6.2 可借鉴的演进方向

| 优先级 | 方向 | 参考来源 | 说明 |
|--------|------|---------|------|
| P0 | **结构化输出** | llm-git | 用 tool calling / JSON schema 代替纯文本解析，避免 LLM 输出格式不稳定 |
| P0 | **"不编造"约束** | 所有项目 | 在 system prompt 中明确要求"不编造 diff 中没有的内容" |
| P1 | **多步流水线** | gptcommit | 大 diff 时按文件拆分摘要再汇总，避免截断丢失信息 |
| P1 | **用户上下文** | opencommit | 允许用户输入额外上下文（如 issue 号、修改原因），融入 prompt |
| P2 | **Commit 规范可定制** | opencommit / llm-git | 支持 GitMoji、commitlint 等不同规范 |
| P2 | **风格学习** | gcop | 从仓库历史 commit 学习团队风格，生成风格一致的 message |
| P3 | **Compose 拆分** | llm-git | 大变更建议拆分为多个原子 commit |
| P3 | **自动 CHANGELOG** | llm-git | commit 后自动维护 CHANGELOG.md |

### 6.3 推荐的 Prompt 优化方向

基于调研，建议在现有 prompt 基础上增加以下约束：

```
1. 明确"不编造"：Do not invent changes, behavior, or reasons not visible in the diff.
2. 祈使语气：Use the imperative mood (e.g., "add feature" not "added feature").
3. 长度硬约束：Subject line ≤ 72 characters, body bullets ≤ 5 items.
4. 排除噪声：Skip import reordering, whitespace-only changes, and comment-only changes
   unless they are the primary change.
5. 结构化输出：要求 LLM 以 JSON 格式返回 { type, scope, subject, body }，
   避免解析纯文本的不稳定性。
```

---

## 七、附录：各项目 Prompt 全文

### 7.1 opencommit — 完整 prompt（`src/prompts.ts`）

核心 system prompt：

```
You are to act as an author of a commit message in git.
Your mission is to create clean and comprehensive commit messages as per the
Conventional Commit Convention and explain WHAT were the changes and mainly WHY
the changes were done.

I'll send you an output of 'git diff --staged' command, and you are to convert
it into a commit message.

Do not preface the commit with anything, except for the conventional commit
keywords: fix, feat, build, chore, ci, docs, style, refactor, perf, test.

Don't add any descriptions to the commit, only commit message.
Use the present tense. Lines must not be longer than 74 characters.
Use English for the commit message.
```

GitMoji 模式下额外增加 emoji 映射表（10 个常用 / 完整 60+ 个）。

### 7.2 gptcommit — 模板文件

**文件摘要**（`summarize_file_diff.tera`）：

```
You are an expert programmer summarizing the following git diff.
Produce concise bullet points describing the key changes.
List at most five points for brevity.
Use the imperative mood and start each line with `-`.
Exclude file names, diff markers and code snippets.
Keep the summary short and easy to read.

THE GIT DIFF TO BE SUMMARIZED:
```
{{ file_diff }}
```

THE SUMMARY:
```

**标题生成**（`title_commit.tera`）：

```
You are an expert programmer generating a concise commit title.
Summarize the change in a single short sentence using the imperative mood.
Ignore file names and diff details.

EXAMPLE SUMMARY COMMENTS:
- Raise the amount of returned recordings
- Switch to internal API for completions
- Lower numeric tolerance for test files

THE FILE SUMMARIES:
```
{{ summary_points }}
```

Write only one line, no more than 50 characters.
Respond with just the title text.
```

### 7.3 llm-git — Map-Reduce prompt

见第二章"架构 3"中的完整 prompt 引用。

---

## 八、参考链接

- https://github.com/di-sukharev/opencommit
- https://github.com/zurawiki/gptcommit
- https://github.com/Undertone0809/gcop
- https://github.com/can1357/llm-git
- https://www.conventionalcommits.org
- https://gitmoji.dev
