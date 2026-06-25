# .gitignore 管理领域知识库

> 覆盖范围：NeatGit 中 .gitignore 文件追写入功能的完整链路，包括 `GitIgnoreWriter` 服务、`GitIgnoreRuleTarget` 规则生成、`RepositoryFilePanel` 中 untracked 文件的右键菜单交互、`ContentView` 中的事件协调与错误展示。不覆盖 .gitignore 文件的解析、编辑或可视化能力。

## §1 业务背景与核心概念

NeatGit 作为桌面 Git 客户端，需要让用户在查看 untracked 文件时能快速将其加入 `.gitignore`，而无需手动编辑文件。当前实现了三种忽略粒度：

- **精确路径忽略**（`exactPath`）：忽略指定相对路径的文件或目录，生成 `/path/to/target` 格式规则，前导 `/` 锚定仓库根，目录后缀 `/`。
- **文件名忽略**（`fileName`）：忽略所有同名文件，生成不带 `/` 前缀的纯文件名规则。
- **目录忽略**（`directory`）：忽略指定相对路径下的整个目录，生成 `/path/to/dir/` 格式规则，前后均有路径分隔符。

核心模型：

| 类型 | 职责 |
|------|------|
| `GitIgnoreRuleTarget` | 枚举，描述忽略规则的目标（精确路径 / 文件名 / 目录），内置 `rule` 计算属性生成合法 .gitignore 规则字符串 |
| `GitIgnoreWriter` | 服务类，负责将规则追加写入仓库 `.gitignore` 文件；去重、尾部换行保证、原子写入 |
| `RepositoryFileItem` | 领域模型，携带 `relativePath`、`displayName`、`kind`、`isUntracked`、`directoryIgnoreOptions` 等属性，供 UI 层构造 `GitIgnoreRuleTarget` |
| `RepositoryIgnoreDirectoryOption` | 目录忽略选项模型，由 `RepositoryFileItem.directoryIgnoreOptions` 按路径逐级生成 |

## §2 核心业务流程 / 状态机

### 2.1 用户交互主流程

```
用户在文件列表中右键 untracked 文件
    → RepositoryFileInteractiveRow.contextMenu 展示忽略菜单
        → "忽略 {relativePath} 的版本管理" → onIgnorePath(item)
        → "忽略文件名为 {displayName} 的版本管理" → onIgnoreFileName(item)
        → "忽略所在文件夹的版本管理" → 展开子菜单 → onIgnoreDirectory(option, item)
    → ContentView 中对应函数构造 GitIgnoreRuleTarget
        → ignorePath → .exactPath(item.relativePath, isDirectory:)
        → ignoreFileName → .fileName(item.displayName)
        → ignoreDirectory → .directory(option.relativePath)
    → runIgnoreAction(target, for: item)
        → gitIgnoreWriter.append(target, to: repository)
            → Task.detached 切到后台线程
            → 构造 .gitignore 完整路径
            → 读取当前内容，按行 trim 后去重
            → 保证末尾换行，追加规则行 + 换行
            → 原子写入（atomically: true）
        → 成功 → statusStore.refreshCurrentRepository() 刷新文件列表
        → 失败 → 展示 RepositoryFileActionAlert（"更新 .gitignore 失败" + 错误描述）
```

### 2.2 规则生成逻辑

`GitIgnoreRuleTarget.rule` 的生成规则：

| 枚举成员 | 输入 | 输出规则 | 示例 |
|----------|------|----------|------|
| `.exactPath(path, isDirectory: false)` | 文件相对路径 | `/{path}` | `build/Output.o` → `/build/Output.o` |
| `.exactPath(path, isDirectory: true)` | 目录相对路径 | `/{path}/` | `build` → `/build/` |
| `.fileName(name)` | 纯文件名 | `{name}` | `.DS_Store` → `.DS_Store` |
| `.directory(path)` | 目录相对路径 | `/{path}/` | `node_modules` → `/node_modules/` |

转义规则（`escapeGitIgnoreRule`）：仅当值以 `#` 或 `!` 开头时，在首字符前加 `\` 前缀，避免被解析为注释或取反规则。

### 2.3 写入去重逻辑

1. 读取 `.gitignore` 全部内容，按换行符拆分。
2. 每行执行 `trimmingCharacters(in: .whitespacesAndNewlines)` 得到标准化行。
3. 如果标准化行中已包含即将写入的 `rule`，直接返回（不重复写入）。
4. 否则确保原文末尾有换行，追加 `rule` + 换行。

### 2.4 错误处理流程

- `.gitignore` 不存在：`String(contentsOf:)` 返回 nil，`?? ""` 回退为空内容，等同于首次创建。
- 写入失败：抛出 `GitCommandError(message: "写入 {path} 失败：{描述}")`，由 `ContentView.runIgnoreAction` 捕获后展示 `RepositoryFileActionAlert`。
- 读取权限问题：同样走 `String(contentsOf:)` 的 throws 路径，但当前用 `try?` 吞掉了读取错误——若读取权限不足，会以空内容覆盖写入，可能丢失原有规则。

## §3 本域代码入口索引

| 场景 | 入口 | 类/方法/配置 | 说明 |
|------|------|-------------|------|
| 构造忽略规则 | `GitIgnoreWriter.swift` | `GitIgnoreRuleTarget.rule` | 将枚举值转为 .gitignore 合法规则字符串 |
| 规则转义 | `GitIgnoreWriter.swift` | `GitIgnoreRuleTarget.escapeGitIgnoreRule(_:)` | 处理 `#` / `!` 开头的文件名 |
| 追加写入 .gitignore | `GitIgnoreWriter.swift` | `GitIgnoreWriter.append(_:to:)` | 对外入口，切后台线程执行写入 |
| 实际写入逻辑 | `GitIgnoreWriter.swift` | `GitIgnoreWriter.append(rule: to:)` | 读取 → 去重 → 追加 → 原子写入 |
| 精确路径忽略 | `ContentView.swift` | `ignorePath(for:)` | 构造 `.exactPath` 目标并调用写入 |
| 文件名忽略 | `ContentView.swift` | `ignoreFileName(for:)` | 构造 `.fileName` 目标并调用写入 |
| 目录忽略 | `ContentView.swift` | `ignoreDirectory(_:for:)` | 构造 `.directory` 目标并调用写入 |
| 写入协调与错误处理 | `ContentView.swift` | `runIgnoreAction(_:for:)` | 统一执行写入、成功刷新、失败弹窗 |
| 右键菜单展示 | `RepositoryFilePanel.swift` | `RepositoryFileInteractiveRow.contextMenu` | 仅 untracked 文件显示忽略菜单 |
| 目录忽略选项生成 | `RepositoryFileModels.swift` | `RepositoryFileItem.directoryIgnoreOptions` | 按路径逐级生成可选目录列表 |

## §4 本域表与字段入口索引

本域为纯桌面 Git 客户端，无数据库表，此节不适用。

## §5 本域流程 / 组件 / 任务 / MQ 入口索引

本域为纯桌面应用，无后台任务 / 消息队列 / 定时 Job，此节不适用。

## §6 核心业务规则与隐性约束

1. 【禁止】忽略菜单仅在 `item.isUntracked == true` 时展示（`RepositoryFileInteractiveRow` 中通过 `if item.isUntracked` 门控），tracked 文件即使有变更也不会出现忽略入口。
2. 【隐性依赖】`GitIgnoreWriter` 始终写入仓库根目录的 `.gitignore`，不处理子目录级 `.gitignore` 或全局/系统级 exclude 文件；若仓库使用子目录级忽略规则，当前功能无法覆盖。
3. 【隐性依赖】写入时用 `try?` 读取现有 `.gitignore`，读取失败时回退为空字符串——这意味着如果文件存在但因权限问题无法读取，后续原子写入会覆盖为仅含新规则的内容，**原有规则会丢失**。
4. 【消歧】`exactPath` 和 `directory` 两种枚举都生成带 `/` 前缀的规则，区别仅在于 `isDirectory: true` 时 `exactPath` 也加尾部 `/`，而 `directory` 始终加尾部 `/`；对于目录场景两者语义等价，但 UI 入口不同（"忽略路径" vs "忽略所在文件夹"）。
5. 【隐式语义】去重比较基于 `trimmingCharacters(in: .whitespacesAndNewlines)` 后的标准化行，如果原 .gitignore 中有缩进或尾部空格的规则行，标准化后可能与新规则匹配从而跳过写入——这可能导致用户认为"没写进去"。
6. 【消歧】`RepositoryFileItem.directoryIgnoreOptions` 按父路径逐级展开（如 `a` → `a/b` → `a/b/c`），根目录文件返回空数组，UI 层展示禁用的占位菜单项。
7. **【AI 易错点】** `escapeGitIgnoreRule` 仅转义以 `#` 或 `!` 开头的值，但 .gitignore 中 `{`、`*`、`?`、`[` 等字符也有 glob 语义；如果文件名包含这些字符（如 `file[1].txt`），当前不会转义，生成的规则可能匹配到非预期的文件集。AI 修改此逻辑时容易忽略 .gitignore 使用的是 glob 模式而非正则，也容易误加正则风格转义。

## §7 常见易忽略条件与验证路径

1. **去重逻辑验证**：在同一 untracked 文件上连续执行两次"忽略路径"操作，第二次应无任何效果（.gitignore 不应新增重复行）。验证方法：操作前记录 `.gitignore` 行数，第二次操作后确认行数未变。
2. **读取失败场景验证**：将仓库 `.gitignore` 权限设为 `000`，然后对 untracked 文件执行忽略操作。当前行为：`try?` 读取失败回退空串，原子写入会覆盖原有内容。验证方法：操作前记录 `.gitignore` 原有内容，操作后检查文件是否只剩新规则行。
3. **特殊文件名转义验证**：创建以 `#` 或 `!` 开头的 untracked 文件（如 `#notes.txt`），执行"忽略文件名"。验证方法：检查 `.gitignore` 中生成的规则是否为 `\#notes.txt` 而非 `#notes.txt`（后者会被解析为注释）。
4. **根目录文件目录忽略验证**：对仓库根目录下的 untracked 文件，右键菜单中"忽略所在文件夹"子菜单应展示禁用占位项。验证方法：确认 `directoryIgnoreOptions` 为空时 UI 展示不可点击的提示。

## §8 关联文档

- [`docs/NEATGIT_KNOWLEDGE_BASE.md`](NEATGIT_KNOWLEDGE_BASE.md)：核心功能业务规则、代码入口与隐性约束
- [`AGENTS.md`](../AGENTS.md)：项目整体约定与文档导航

## §9 覆盖度与待补充项

- 代码推断覆盖：`GitIgnoreWriter` 全量覆盖（58 行），`RepositoryFilePanel` 中忽略菜单交互全量覆盖，`ContentView` 中忽略协调逻辑全量覆盖。
- 领域语言统一：主称谓为".gitignore 管理"，对应服务类 `GitIgnoreWriter`，规则目标 `GitIgnoreRuleTarget`。
- 待补充：
  - 读取失败时的数据保护策略（当前 `try?` 吞掉错误可能丢失原有规则）。
  - 子目录级 `.gitignore` 写入支持的设计决策。
  - glob 特殊字符（`*`、`?`、`[`、`]`、`{`）的转义策略。
  - 写入后是否需要触发 `git status` 刷新而非依赖 `refreshCurrentRepository` 的实现细节。
