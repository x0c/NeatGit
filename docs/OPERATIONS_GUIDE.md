# Operations 指南

> 覆盖范围：本地构建步骤、Monaco 前端构建、运行时验证路径、常见阻碍排查。

---

## 一、环境前提

| 项目 | 要求 |
|------|------|
| macOS | 26.0+ |
| Xcode | 26+（验证工具链：Xcode 26.3，`/Applications/Xcode.app`） |
| Swift | 6.0 |
| XcodeGen | 需安装（`brew install xcodegen`） |
| Node.js | 首次构建或修改 Monaco 前端时需要 |

---

## 二、构建步骤

### 2.1 首次或工程结构变更后

```bash
# 项目根目录
xcodegen generate
open NeatGit.xcodeproj
```

**何时必须重新 xcodegen**：新增、删除、移动任意 Swift 文件或资源文件后。
`project.yml` 是工程配置源；`NeatGit.xcodeproj` 是生成产物，不要只手改 xcodeproj。

### 2.2 日常构建

直接在 Xcode 中 `⌘B`（Build）或 `⌘R`（Run）。

命令行构建：
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project NeatGit.xcodeproj -scheme NeatGit -configuration Debug -derivedDataPath .build-xcode build
```

---

## 三、Monaco 前端构建

修改 `Web/MonacoDiff/src/` 下任意文件后需要重新构建：

```bash
cd Web/MonacoDiff
npm ci            # 首次或依赖变更后
npm run build
# Vite 直接写入 NeatGitApp/Resources/MonacoDiff/
cd ../..
xcodegen generate # hash 文件名变化后更新 Xcode 资源引用
```

不要从 dist 复制：`vite.config.js` 的 outDir 已指向应用资源。生成产物被 Git 忽略，干净检出必须先构建网页。跳过 `xcodegen generate` 会让 Xcode 引用被清理掉的旧 hash 文件，报资源不存在。

---

## 四、运行时验证路径

### 4.1 仓库扫描

启动 App 后左侧栏自动扫描 Home 目录（约 1-3 秒），出现仓库列表说明扫描链路正常。

### 4.2 文件状态读取

选中左栏任意仓库 → 中间面板出现文件列表（changed / skipped / ignored 分组）说明 `GitRepositoryStatusLoader` 正常工作。

### 4.3 Diff 预览

点击中间面板任意 changed 文件 → 右侧 Monaco Diff 预览出现（侧边模式或 inline 模式取决于窗口宽度）。
若预览空白，检查：
- 加载/更新失败是否出现中文错误和重试按钮（加载 15 秒、更新 10 秒超时）。
- `NeatGitApp/Resources/MonacoDiff/` 是否有构建产物，且工程已重新生成。
- `MonacoDiffController` 是否等 `WebPage.load` 的 `.finished`、JS 两个入口验证成功；不要恢复旧的消息回调方案。

### 4.4 AI commit message 生成

1. 用 `⌘,` 打开设置，填写兼容 OpenAI 接口的服务地址、模型和密钥。
2. 选择有可提交更改的仓库 → 点击底部 AI 生成 → 提交说明框自动填入；文件行选择仅控制预览。
3. 如生成失败，打开 `Window → AI 调试`（或通过 `AICommitDebugWindowView`）查看 prompt 和 error 详情。

### 4.5 自动化回归与验证边界

先完成 §三网页构建和工程生成，然后运行：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project NeatGit.xcodeproj -scheme NeatGit -configuration Debug \
  -derivedDataPath .build-xcode -destination 'platform=macOS' \
  -only-testing:NeatGitTests test

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project NeatGit.xcodeproj -scheme NeatGit -configuration Debug \
  -derivedDataPath .build-xcode -destination 'platform=macOS' \
  -only-testing:NeatGitUITests -parallel-testing-enabled NO test
```

- `RepositoryDiffStoreTests`：隔离临时仓库，覆盖 Observation、暂存/工作区切换、快速切换、刷新失效、多选与不支持状态；只建临时索引，不创建提交。
- `NativeControlsTests`：实际挂载系统窗口，验证原生侧栏选择、文件多选、多行输入与文本控件撤销、安全输入框、浅深色渲染；PNG 写入系统临时目录 `NeatGit-界面验证/`，同时作为测试附件保留。
- `MonacoWebViewTests`：运行真实 WebView、bundle 静态资源与 Swift/JS 数据传入，验证连续切换不导航、外观同步、注入失败和重试恢复。测试注入钩子只记录真实 `setDiff` 成功调用，不替换业务渲染。
- `NativeWorkspaceTests`：桌面点击仓库/文件、编辑与 ⌘Z、打开/关闭调试和设置窗口；不执行提交、推送或收费 AI 请求。
- 锁屏/系统认证时，XCUITest 可能在测试代码执行前失败，WebKit 可运行 JS 但暂停可见文本绘制。组件内截图与桥接断言不能替代完整桌面点击验收；报告此限制，不关闭锁屏安全策略。键盘撤销的窗口路由/绑定回写仍由 XCUITest 验证，组件直接操作 UndoManager 仅证明文本控件可撤销。
- 环境改进待办：为桌面回归准备已解锁并获系统自动化授权的受控会话；未经授权不修改锁屏或隐私权限设置。

验证基线：macOS 26.7 / Xcode 26.3 下，12 项组件、差异状态与真实 WebView 测试通过；浅深色组件截图和 Chrome 差异显示、只读交互均已核验。完整桌面 XCUITest 因系统认证阻止初始化，未完成窗口点击与快捷键端到端验收，不能将其计入通过项。

构建成功后按根 `AGENTS.md` §8 安装并启动 `/Applications/NeatGit.app`，核验进程路径和 PID。构建失败时不替换安装包。

---

## 五、常见阻碍

| 现象 | 排查方向 |
|------|---------|
| `xcodebuild` 编译报 sendability 错误 | 可能是 Swift 6.2 工具链变化引入的，先确认是否工具链升级导致 |
| Monaco Diff 空白 | 检查网页构建与 bundle 资源、导航/JS 初始化错误；锁屏状态下的网页绘制不作为视觉验收 |
| 仓库扫描超时 / 卡死 | 检查 Home 目录下是否存在超深嵌套或超大 node_modules（扫描深度上限 6，但部分目录未被排除规则覆盖） |
| AI 生成请求失败 | 在 AI 调试窗口查看 errorMessage；检查设置中的地址、模型和本地保存的密钥 |
| 应用内设置（如 LLM 配置）丢失需重填 | 2026-10-21 应用标识为开源脱敏统一变更为 `io.github.x0c.neatgit`，本地偏好与钥匙串随新标识域重新开始，属一次性影响，重填即可 |
| xcodegen generate 报文件找不到 | 确认 `project.yml` 中 sources 路径与实际文件路径一致 |
| SwiftUI 类型检查超时 | 把三栏、工具栏、状态监听、弹窗拆成独立属性，勿继续堆一个超长 View 表达式 |
| XCUITest 初始化报 `System authentication is running` | 系统认证/锁屏阻止桌面自动化；不能通过加延时或换坐标解决，需要解锁并允许系统测试授权 |

<!-- 该文档整理/压缩于 2026-10-21 -->
