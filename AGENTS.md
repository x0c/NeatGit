# AGENTS.md

本文件面向会在本仓库内工作的代码代理（LLM / Coding Agent）。

## 1. 项目定位

NeatGit 是一个面向 macOS 的原生 Git 客户端，使用 SwiftUI 构建。

当前代码已经实现了一个可运行的原型，核心方向仍然来自 `README.md`：

- 做一个现代、简洁、好用的桌面工具。
- 围绕本地 Git 项目的日常管理流程设计，而不是做成臃肿的全能型客户端。
- 优先覆盖高频操作：项目发现、变更查看、提交、推送。
- 在合适场景引入 AI，减少重复输入和机械操作。

## 2. 产品与设计原则

所有改动都必须尽量贴合下面这些原则：

- 简洁优先：避免堆砌面板、复杂交互和过度装饰。
- 原生优先：优先使用 SwiftUI 与 macOS 原生能力，保持系统感。
- 效率优先：尽量减少 Git 高频操作的点击数和思维切换成本。
- 可扩展优先：为后续增加仓库详情、忽略规则管理、AI commit 等 能力预留结构。

如果需求与这些原则冲突，优先保护产品方向，不要为了“看起来功能更多”而引入复杂度。

## 3. 当前技术栈与工程约定

在动手前，先把下面这些“当前默认前提”当成事实：

- 最低部署版本当前是 `macOS 15.0`。
- Swift 语言版本当前是 `Swift 6.0`。
- UI 主体仍然以 `SwiftUI` 为主，应用入口使用 `SwiftUI App` 生命周期。
- 主窗口骨架基于 `NavigationSplitView + HSplitView`，保持典型 macOS 桌面分栏语义。
- 状态管理已经开始迁移到 Observation：
  - `RepositoryStore`、`RepositoryStatusStore` 使用 `@MainActor + @Observable`。
  - 在 `View` 中持有这类 store 时，优先使用 `@State`，不要继 续默认写成 `@StateObject`。
- 后台任务优先使用 Swift Concurrency：
  - 新代码优先考虑 `Task`、`Task.detached`、`async/await`。
  - 不要在新增逻辑里继续优先写 `DispatchQueue.global().async` 风格，除非有明确理由。
- 工程由 `XcodeGen` 管理：
  - `project.yml` 是工程配置源。
  - `NeatGit.xcodeproj` 是生成产物，不是唯一事实来源。
  - 只要新增、删除或重组源码/资源文件，优先修改 `project.yml` 后执行 `xcodegen generate`，不要只手改 `xcodeproj`。
- 当前仓库已经接入 `WebKit + Monaco` 用于右侧文本 diff 预览，后续做 diff 能力时应优先沿现有模型扩展，而不是另起一套完全不 同的预览栈。

### 3.1 对后续开发有价值的额外信息

- 当前本机验证环境已经可用完整 Xcode 构建，且最近一次验证通过的是 `/Applications/Xcode.app/Contents/Developer`。
- Swift 6 会比以前更严格地检查并发隔离与 sendability；如果改 动 store、`Binding`、异步任务捕获，优先按 actor 边界思考，而 不是等编译器报错后再补。
- 当前已把通用 Git 进程执行统一收口到 `NeatGitApp/Services/GitCommandSupport.swift`：
  - 需要执行 Git 子命令时，优先复用 `GitCommandRunner` 与 `GitCommandError.describe(_:)`。
  - 不要在新的 service 里继续复制粘贴 `Process + Pipe + terminationStatus` 模板。
- `RepositoryPreviewPane.swift` 当前故意使用了相对朴素的 `task(id:) + selectionSignature` 刷新方式。
  - 原因不是“写不出更炫的 SwiftUI”，而是 Xcode 26.3 / Swift 6.2 下，这块视图如果叠太多 `onChange`、复杂 `Binding` 或更激进的并发标注，容易触发编译器崩溃。
  - 如果后续想再做“纯写法优化”，先以可构建为第一优先级，不要 为了清理样式把稳定版本改回不稳定形态。
- 目前最近一次完整构建已通过，没有保留必须立刻处理的 Swift warning；如果后续看到新的 sendability warning，优先确认是不是工具链变化引入的。

## 4. 当前代码现状

当前仓库不是空壳，已经有明确的实现边界。改动前应先理解这些事 实：

- 已实现应用入口：`NeatGitApp/NeatGitApp.swift` 使用 SwiftUI `App` 生命周期启动窗口。
- 已实现主界面骨架：`NeatGitApp/ContentView.swift` 使用 `NavigationSplitView` 构建左右分栏桌面布局。
- 已实现仓库扫描：应用首次进入界面时会自动扫描当前用户 Home  目录下的 Git 仓库。
- 已实现扫描约束：当前递归深度为 6，且会跳过常见隐藏目录、缓 存目录与大体量依赖目录。
- 已实现仓库分组：左侧列表按父目录分组，分组标题会自动压缩为 尽量短且可区分的路径名。
- 已实现基础选择态：支持展开/折叠分组、选择仓库、同步当前展开组。
- 已实现文件状态读取：中间面板已经接入当前仓库的 `changed / skip-worktree / ignored` 文件列表。
- 已实现文件列表交互：支持分组折叠、文件选择、多选态同步、勾 选框和手动刷新。
- 已实现 `.gitignore` 追加入口：对 untracked 文件可直接忽略文件名或上级目录，并在写入失败时展示错误。
- 已实现右侧 diff 预览第一版：单文件文本 diff 已经接入，支持 在“未暂存 / 已暂存”之间切换。
- 当前 diff 仍有明确边界：只支持单文件、文本内容、约 750 KB  以内文件；冲突文件、二进制文件和多文件汇总仍未完成。
- 已实现 Monaco Web 预览链路：右侧 diff 依赖 `NeatGitApp/Resources/MonacoDiff/` 下的静态资源和 `MonacoDiffView.swift` 的 JS 注入协议。
- 已实现底部提交栏骨架：已有 commit message 输入框、AI 按钮、提交按钮和“提交但不推送”菜单项。
- 尚未实现真实 Git 提交流程：当前 AI 生成、提交、提交并推送仍为空实现。

## 5. 代码结构认知

当前项目已经不再是单文件原型，扩展时应沿着现有目录结构演进， 而不是重新揉回一个超大 View：

- `NeatGitApp/NeatGitApp.swift`：应用入口与窗口默认尺寸。
- `NeatGitApp/ContentView.swift`：主界面编排、跨面板选择态和 提交栏入口。
- `NeatGitApp/Domain/`：Git 仓库、文件状态、diff 模式、分组等领域模型。
- `NeatGitApp/Services/`：Git 命令调用、仓库扫描、状态读取、diff 读取、`.gitignore` 写入等服务。
- `NeatGitApp/Stores/`：界面状态容器；当前是混合结构：
  - `RepositoryStore`、`RepositoryStatusStore` 已迁到 Observation。
  - `RepositoryDiffStore` 仍是 `ObservableObject`，因为它当前由右侧预览面板通过 `@StateObject` 持有。
- `NeatGitApp/Views/Sidebar/`：左侧仓库列表与 sidebar 控件。
- `NeatGitApp/Views/RepositoryStatus/`：文件状态列表、右侧预 览面板、占位态视图。
- `NeatGitApp/Views/Diff/`：Monaco diff 相关视图。
- `NeatGitApp/Views/Commit/`：底部提交栏。
- `project.yml`：XcodeGen 配置源。
- `NeatGit.xcodeproj`：由 `project.yml` 生成的工程文件。

如果新增文件：

- 命名要直接表达 Git 领域语义。
- 优先把“扫描 / 仓库模型 / 详情视图 / 提交工作流”拆成清晰类型，而不是继续堆在一个超大 View 里。
- 若修改工程结构，先维护 `project.yml`，再执行 `xcodegen generate` 同步工程。
- 如果只是因为 Xcode 工程里“看不到文件”就手工修 `pbxproj`，大概率是在绕开正确维护方式。
- 如果新增 diff 相关资源，记得同时检查 `NeatGitApp/Resources/MonacoDiff/index.html`、`MonacoDiffView.swift` 和 bundle 内资源路径是否仍匹配。

## 6. 修改要求

- 改动前先阅读相关文件，基于现有结构扩展，不要凭空重写。
- 不要覆盖或回退你未创建的用户改动。
- 优先做小步、清晰、可验证的修改。
- UI 代码保持 macOS 原生桌面应用语义，不要写成 iOS 风格页面。
- 优先复用现有 `GitRepository`、`RepositoryGroup`、`RepositoryStore` 这些语义，而不是引入重复抽象。
- 新增状态容器时，优先延续 Observation 写法；只有在确有必要时再继续扩大 `ObservableObject` 的使用面。
- 新增异步逻辑时，优先复用现有 Git service / store 分层，不要把 `Process` 调用直接塞回 View。
- 新增 Git 命令时，优先放进 `Services/`，并先判断能否复用 `GitCommandRunner`、`GitCommandError`、已有 domain model，而不是临时在 view/store 中拼字符串命令。
- 如果接入真实 Git 能力，先保证本地仓库选择、状态读取、错误展示链路清晰，再补自动化与 AI。
- 如果扩展 diff 能力，优先沿 `RepositoryDiffMode / RepositoryDiffDocument / RepositoryDiffStore / MonacoDiffView` 这一条链路演进。
- 如果修改右侧 diff 预览刷新机制，优先保持“仓库切换 + 文件切 换 + mode 切换”三条状态链路可单独验证，避免一次把 View、Store、WebKit 注入协议同时重写。
- 除非需求明确要求，否则不要加入与项目愿景无关的能力。

## 7. 当前阶段建议

现阶段更适合优先推进这些方向：

- 仓库详情补完，例如分支、最近提交、远端信息、仓库级摘要。
- 扫描结果的可解释性和刷新体验。
- commit 工作流从占位按钮变成真实能力，包括 staged/checked 文件和真实提交链路。
- `.gitignore` / `skip-worktree` 图形化管理。
- diff 预览的稳健性增强，例如二进制态提示、冲突态提示、目录/ 多文件说明和性能边界处理。

现阶段不建议直接做成重型客户端，例如：

- 一次性接入大量低频 Git 子命令。
- 堆叠复杂多面板布局。
- 在没有仓库详情基础前先做过多 AI 自动化。

## 8. 改动完成后的强制动作

只要你改动了仓库中的代码文件，就必须在结束前执行一次“杀掉旧进程 -> 构建 -> 移动到 Applications -> 拉起 /Applications 里面的新应用 -> 校验进程”的完整流程，供人直接查看结果。

说明：

- “代码文件”指会影响应用行为的文件，例如 `swift`、工程配置、 资源等。
- 如果只修改文档文件（例如 `README.md`、`AGENTS.md`），不要求执行这套流程。

### 8.1 Xcode 环境检查

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

### 8.2 固定构建命令

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

### 8.3 固定重启流程

构建成功后，必须先关闭旧进程，再将应用移动/替换到 `/Applications` 里面，最后启动 `/Applications` 里面的新 app：

```bash
pkill -x NeatGit || true
rm -rf /Applications/NeatGit.app
cp -R ~/Swift/NeatGit/.build-xcode/Build/Products/Debug/NeatGit.app /Applications/
open /Applications/NeatGit.app
```

启动后必须补一条检查，确认新进程真的起来了：

```bash
pgrep -fal '/Applications/NeatGit.app/Contents/MacOS/NeatGit'
```

要求：

- 先停旧进程，再开新进程。
- 必须先把编译好的 app 移动/替换到 `/Applications` 里面。
- 必须启动 `/Applications/NeatGit.app`，不要启动其他路径下的历史包。
- 如果 `open` 成功但进程没有起来，必须继续排查，不能直接声称“已经启动”。

### 8.4 推荐的一次性完整命令顺序

在仓库根目录推荐按下面顺序执行：

```bash
pkill -x NeatGit || true
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project NeatGit.xcodeproj -scheme NeatGit -configuration Debug -derivedDataPath .build-xcode build
rm -rf /Applications/NeatGit.app
cp -R ~/Swift/NeatGit/.build-xcode/Build/Products/Debug/NeatGit.app /Applications/
open /Applications/NeatGit.app
pgrep -fal '/Applications/NeatGit.app/Contents/MacOS/NeatGit'
```

执行语义：

- 第 1 步确保旧预览进程被清理。
- 第 2 步只要失败，就不能执行后续步骤。
- 第 3、4 步负责将最新构建产物替换到 /Applications。
- 第 5 步负责拉起 /Applications 里面的新应用。
- 第 6 步用于向用户证明当前看到的是新版本进程。

### 8.5 最终汇报要求

在最终回复中明确说明：

- 改了什么。
- 是否执行了构建。
- 是否成功移动并拉起 /Applications 里面的新进程。
- 是否验证到新进程 PID 或产物路径。
- 如果没做到，阻塞点是什么。

## 9. 决策准则

遇到不确定情况时，按以下优先级决策：

1. 与 `README.md` 中的项目愿景保持一致。
2. 保持 macOS 原生、简洁、高频 Git 工作流导向。
3. 选择 minimal 但完整、可运行、可验证的实现。
4. 代码改动完成后必须尝试按固定流程构建、杀旧进程并重启预览；如果环境阻塞，必须如实报告。
