# AGENTS.md

本文件面向会在本仓库内工作的代码代理（LLM / Coding Agent）。

## 1. 项目定位

NeatGit 是一个面向 macOS 的原生 Git 客户端，使用 SwiftUI 从 0 到 1 构建。

项目当前的核心愿景来自 `README.md`：

- 做一个现代、简洁、好用的桌面工具。
- 围绕本地 Git 项目的日常管理流程设计，而不是做成臃肿的全能型客户端。
- 优先覆盖高频操作：项目发现、变更查看、提交、推送。
- 在合适场景引入 AI，减少重复输入和机械操作。

## 2. 产品与设计原则

所有改动都必须尽量贴合下面这些原则：

- 简洁优先：避免堆砌面板、复杂交互和过度装饰。
- 原生优先：优先使用 SwiftUI 与 macOS 原生能力，保持系统感。
- 效率优先：尽量减少 Git 高频操作的点击数和思维切换成本。
- 可扩展优先：为后续增加仓库详情、忽略规则管理、AI commit 等能力预留结构。

如果需求与这些原则冲突，优先保护产品方向，不要为了“看起来功能更多”而引入复杂度。

## 3. 当前阶段认知

当前项目仍处于基础搭建阶段，代码实现应与这个阶段保持一致：

- 已有方向：本机 Git 仓库扫描、左侧项目列表、基础导航框架。
- 后续方向：仓库详情与文件状态展示、`.gitignore` / `skip-worktree` 图形化管理、AI commit 工作流。
- 若新增能力超出当前阶段，应先保证结构可演进，不要一次性做成重系统。

## 4. 代码修改要求

- 改动前先阅读相关文件，基于现有结构扩展，不要凭空重写。
- 不要覆盖或回退你未创建的用户改动。
- 优先做小步、清晰、可验证的修改。
- UI 代码保持 macOS 原生桌面应用语义，不要写成 iOS 风格页面。
- 若引入新结构，命名应直接表达 Git 领域语义。
- 除非需求明确要求，否则不要加入与项目愿景无关的能力。

## 5. 改动完成后的强制动作

只要你改动了仓库中的代码文件，就必须在结束前执行一次“杀掉旧进程 -> 构建 -> 拉起新应用 -> 校验进程”的完整流程，供人直接查看结果。

### 5.1 Xcode 环境检查

先确认完整 Xcode 是否存在：

```bash
ls -d /Applications/Xcode.app
```

然后优先检查当前终端实际会使用的开发者目录：

```bash
echo "${DEVELOPER_DIR:-<empty>}"
xcode-select -p
```

说明：

- 如果 `DEVELOPER_DIR` 已经是 `/Applications/Xcode.app/Contents/Developer`，直接继续。
- 如果 `xcode-select -p` 指向 `/Library/Developer/CommandLineTools`，不要立刻判定为阻塞；本项目允许显式指定 `DEVELOPER_DIR` 来构建。
- 只有当 `/Applications/Xcode.app` 不存在，或者显式指定 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 后 `xcodebuild` 仍不可用，才算真正阻塞。

可用性验证命令：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -version
```

如果这条命令失败，必须明确报告阻塞原因：当前环境无法构建 macOS App，不能假装已经验证成功。

### 5.2 固定构建命令

在仓库根目录执行，必须显式指定完整 Xcode：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project NeatGit.xcodeproj -scheme NeatGit -configuration Debug -derivedDataPath .build-xcode build
```

要求：

- 构建失败时，停止后续启动流程。
- 构建失败时，要输出失败结论，并说明没有启动新版本应用。
- 不要在构建失败后继续保留“可预览”的错误表述。
- 构建产物固定使用 `.build-xcode/Build/Products/Debug/NeatGit.app`，不要换成临时路径。

### 5.3 固定重启流程

构建成功后，必须先关闭旧进程，再启动新构建出的应用：

```bash
pkill -x NeatGit || true
open ~/Swift/NeatGit/.build-xcode/Build/Products/Debug/NeatGit.app
```

启动后必须补一条检查，确认新进程真的起来了：

```bash
pgrep -fal '~/Swift/NeatGit/.build-xcode/Build/Products/Debug/NeatGit.app/Contents/MacOS/NeatGit|NeatGit.app/Contents/MacOS/NeatGit'
```

要求：

- 先停旧进程，再开新进程。
- 不要跳过关闭旧进程这一步，否则预览结果可能不是最新版本。
- 必须启动 `.build-xcode/Build/Products/Debug/NeatGit.app`，不要启动未知路径下的历史包。
- 如果 `open` 成功但进程没有起来，必须继续排查，不能直接声称“已经启动”。

### 5.4 推荐的一次性完整命令顺序

在仓库根目录推荐按下面顺序执行：

```bash
pkill -x NeatGit || true
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project NeatGit.xcodeproj -scheme NeatGit -configuration Debug -derivedDataPath .build-xcode build
open ~/Swift/NeatGit/.build-xcode/Build/Products/Debug/NeatGit.app
pgrep -fal '~/Swift/NeatGit/.build-xcode/Build/Products/Debug/NeatGit.app/Contents/MacOS/NeatGit|NeatGit.app/Contents/MacOS/NeatGit'
```

执行语义：

- 第 1 步确保旧预览进程被清理。
- 第 2 步只要失败，就不能执行第 3 步和第 4 步。
- 第 3 步负责拉起最新构建产物。
- 第 4 步用于向用户证明当前看到的是新版本进程。

### 5.5 最终汇报要求

在最终回复中明确说明：

- 改了什么。
- 是否执行了构建。
- 是否成功关闭旧进程并启动新进程。
- 是否验证到新进程 PID 或产物路径。
- 如果没做到，阻塞点是什么。

## 6. 决策准则

遇到不确定情况时，按以下优先级决策：

1. 与 `README.md` 中的项目愿景保持一致。
2. 保持 macOS 原生、简洁、高频 Git 工作流导向。
3. 选择最小但完整、可运行、可验证的实现。
4. 改完后必须尝试按固定流程构建、杀旧进程并重启预览；如果环境阻塞，必须如实报告。
