# NeatGit

NeatGit 是一个面向 macOS 的原生 Git 客户端，使用 SwiftUI 构建，目标是把本地仓库的高频日常操作做得更轻、更顺手。

它不是一个追求“所有 Git 子命令都能点出来”的重型客户端，而是围绕本地项目发现、文件变更查看、提交准备和后续 AI 辅助这些高频流程来设计。

[简体中文](README.zh-CN.md) · [下载安装包](https://github.com/x0c/NeatGit/releases/latest)

首次安装（macOS 26+，Apple silicon / Intel）：

```bash
curl -fL https://github.com/x0c/NeatGit/releases/download/v0.1.1/NeatGit-0.1.1.dmg -o /tmp/NeatGit.dmg && open /tmp/NeatGit.dmg
```

将 NeatGit.app 拖入 Applications 后打开应用；按 ⌘, 配置 AI 服务。Git 浏览不需要 AI 配置。

## 当前进度

项目已经不再是只有壳层的想法验证版，目前可以跑通一条比较完整的本地浏览链路：

- 启动后自动扫描当前用户 Home 目录下的 Git 仓库。
- 左侧按父目录分组浏览仓库，并自动生成尽量短且可区分的分组标题。
- 选中仓库后读取 Git 状态，并展示 `changed`、`skip-worktree`、`ignored` 三类文件。
- 支持原生文件多选、区块折叠和手动刷新；选择文件用于差异预览。
- 对 untracked 文件提供追加 `.gitignore` 规则的入口，可按文件名忽略，也可按上级目录忽略。
- 右侧已经接入单文件文本 diff 预览，支持在“未暂存 / 已暂存”之间切换。
- 底部支持多行提交说明、AI 生成、提交并推送和仅提交到本地。

## 已实现能力

### 1. 原生 macOS 三栏工作区

- 使用 SwiftUI `App` 生命周期启动。
- 最低支持 macOS 26，主窗口默认尺寸为 `1200 x 780`。
- 主界面采用系统三栏导航、原生工具栏和列表；支持系统侧栏开关、键盘选择和浅色/深色外观。
- 左侧是仓库列表，中间是文件状态列表，右侧是 diff 预览，底部是提交栏。

### 2. 本地仓库自动扫描

- 默认扫描当前用户的 Home 目录。
- 递归深度当前为 6 层。
- 会跳过隐藏目录和常见的大体量或无关目录，例如 `Library`、`Downloads`、`node_modules`、`Pods`、`DerivedData`、`build`、`dist` 等。
- 扫描过程会规避符号链接和 package descendants，并对结果做去重和排序。

### 3. 仓库分组与选择

- 仓库按父目录自动分组。
- 分组标题会根据路径后缀自动压缩，尽量做到短且不冲突。
- 支持展开 / 折叠单个分组。
- 当扫描结果变化时，会同步修正当前选中仓库和展开分组。

### 4. Git 文件状态面板

- 通过 `git status --porcelain=v2 --ignored=matching --untracked-files=all -z` 读取工作区状态。
- 通过 `git ls-files -t -z` 识别 `skip-worktree` 文件。
- 当前会把文件分成三组：
  - `待提交的文件更改`
  - `不提交的文件`
  - `忽略版本管理的文件`
- 已支持的状态摘要包括未暂存、已暂存、已暂存 + 未暂存、新增、删除、重命名、类型变更、冲突、未跟踪等。
- 文件列表支持区块折叠、列表选择、多选同步和手动刷新。

### 5. `.gitignore` 追加入口

- 仅对 untracked 文件开放右键忽略入口。
- 支持直接追加文件名规则。
- 支持逐级选择父目录并追加目录规则。
- 会避免重复写入同一条规则。
- 写入失败时会在界面内提示明确错误信息。

### 6. 单文件 diff 预览

- 右侧预览通过 macOS 26 原生 `WebView / WebPage` 集成 Monaco，保留代码高亮与变更标记。这是目前唯一保留的网页内容界面。
- 目前支持单个 changed 文件的左右对照文本 diff。
- 会根据文件状态自动提供可用模式：
  - `未暂存`：`Index -> Working Tree`
  - `已暂存`：`HEAD -> Index`
- 对 untracked 文件可直接展示空内容到工作区文件的对照。
- 已内置一批常见语言的 Monaco `language hint`，例如 Swift、TypeScript、JavaScript、JSON、Markdown、YAML、Shell、SQL 等。

### 7. 提交栏

- 使用系统多行文本编辑器填写提交说明，AI 生成与调试按钮独立排列，不遮挡文字。
- 主按钮执行“提交并推送”，菜单可选“仅提交到本地”。
- 提交范围为当前仓库符合条件的全部更改，自动排除 `.gitignore`、不提交文件和冲突文件；文件列表选择不改变提交范围。
- 未选择仓库、说明为空、正在提交或正在 AI 生成时不可提交。

### 8. 自动更新

- 通过 Sparkle 2 实现应用内自动更新：自动检查、后台下载安装。
- 更新清单带 EdDSA 签名，解包前验签；后台发现更新不抢焦点，只有主动“检查更新…”才弹窗。
- 入口：应用菜单 `NeatGit → 检查更新…`，或设置页底部的关于行；自动开关位于“更新”分组。
- 他人机器首次安装走 GitHub Releases 的 DMG（Developer ID 签名 + 苹果公证 + 装订票据）。

## 当前边界

下面这些能力在代码里已经有明确边界，README 也同步按现状说明：

- 右侧 diff 目前只支持单文件预览，不支持多文件汇总视图。
- 当前只支持文本 diff，不支持二进制文件预览。
- 冲突文件的可视化 diff 还没有接入。
- 超过约 `750 KB` 的文本文件暂不展示 diff。
- `skip-worktree` 和 `ignored` 文件当前先保留列表能力，右侧预览还未实现。
- 仓库详情信息（分支、最近提交、远端信息、摘要）还没有做出来。

## 技术栈

- Swift 6.0
- macOS 26.0+ / Xcode 26+
- SwiftUI
- Observation
- Swift Concurrency
- WebKit
- Monaco Editor
- XcodeGen

## 代码结构

```text
NeatGitApp/
  NeatGitApp.swift                # 应用入口
  ContentView.swift               # 主界面编排
  Domain/                         # 仓库、文件状态、diff 模型
  Services/                       # Git 扫描、状态读取、diff 读取、.gitignore 写入、AppUpdater
  Stores/                         # UI 状态容器
  Views/
    Sidebar/                      # 左侧仓库列表
    RepositoryStatus/             # 文件状态面板与预览容器
    Diff/                         # macOS 26 WebKit + Monaco
    Commit/                       # 底部提交栏
    Settings/                     # LLM 设置 + 更新开关
  Resources/MonacoDiff/           # 打包后的 Monaco 前端资源
Web/MonacoDiff/                   # Monaco diff 前端源码
appcast.xml                       # Sparkle 更新清单（随仓库发布）
scripts/publish-release.sh        # 签名 + 公证 + DMG + GitHub Release 发布器
project.yml                       # XcodeGen 配置源
```

## 构建

如果只是在 Xcode 中打开工程，建议优先把 `project.yml` 视为真实配置源；新增或重组源码后，应先重新生成工程。

### 1. 构建预览资源并生成工程

首次构建或修改预览网页后：

```bash
(cd Web/MonacoDiff && npm ci && npm run build)
xcodegen generate
```

前端构建直接写入应用资源目录；资源文件名变化后需重新生成工程。日常只改 Swift 时可以直接构建。

### 2. 命令行构建

```bash
xcodebuild -project NeatGit.xcodeproj -scheme NeatGit -configuration Debug -derivedDataPath .build-xcode build
```

测试与完整本地安装流程见 [Operations 指南](docs/OPERATIONS_GUIDE.md)。

构建产物位于：

```bash
.build-xcode/Build/Products/Debug/NeatGit.app
```

## 当前更适合继续推进的方向

- 补齐仓库详情：分支、最近提交、远端信息、仓库摘要。
- 增强提交与推送流程的可靠性和回归验证。
- 继续增强 diff 稳健性，例如冲突态、二进制态、目录态和多文件说明。
- 完善 `.gitignore` / `skip-worktree` 的图形化管理。

## 设计方向

- 简洁优先：少一点堆叠面板和低频功能。
- 原生优先：保持 SwiftUI 和 macOS 桌面应用语义。
- 效率优先：围绕高频 Git 操作减少点击和思维切换。
- 可扩展优先：为仓库详情、真实提交工作流和 AI 辅助预留清晰结构。
