# Operations 指南

> 覆盖范围：本地构建步骤、Monaco 前端构建、运行时验证路径、常见阻碍排查。

---

## 一、环境前提

| 项目 | 要求 |
|------|------|
| macOS | 26.0+ |
| Xcode | 26+; select a complete installed Xcode and record `xcodebuild -version` |
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
xcodebuild -project NeatGit.xcodeproj -scheme NeatGit -configuration Debug \
  -derivedDataPath .build-xcode -destination 'platform=macOS' \
  -only-testing:NeatGitTests test

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

After successful verification and a committed source snapshot, follow root `AGENTS.md` §8 and `RELEASING.md` for signed installation and launch of `/Applications/NeatGit.app`，核验进程路径和 PID。构建失败时不替换安装包。

---

## 六、发布（签名 DMG + 公证 + GitHub Releases）

> 权威流程见 [`RELEASING.md`](../RELEASING.md)。公开发布只走本机 `scripts/publish-release.sh`
>（Developer ID 签名 + 苹果公证 + 装订），tag CI（`.github/workflows/release.yml`）只做无签名校验，
>绝不创建或触碰公开 Release。

```bash
scripts/publish-release.sh --dry-run      # 只做前置检查，不写任何东西
scripts/publish-release.sh --local-only   # 本地出已公证 DMG + 更新 ZIP，不碰远端
scripts/publish-release.sh                # 后台完整发布（公证排队几十分钟，日志见 build/release-logs/）
```

硬性约束（与 NeatEditor 同源）：

- `CURRENT_PROJECT_VERSION` 是 Sparkle 判定新旧的唯一依据，**必须严格递增**；只改展示版本用户端永远收不到更新。
- 每个版本必须在 `CHANGELOG.md` 有对应条目（发行说明正文来源）。
- `Info.plist` 的 `SUFeedURL` / `SUPublicEDKey` 与钥匙串 EdDSA 密钥（`caozc.top`，各应用共用）配套，勿动。
- Release 产物固定三件：已公证 DMG + Sparkle 签名 ZIP + `SHA256SUMS.txt`，走草稿纪律（先草稿 → 逐个上传 → 字节验 → 再公开）。

---

## 七、常见阻碍

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

## Settings rollout diagnostics (2026-10-22)

Fresh Debug build and analysis completed on Xcode 27.2 / macOS 27.2 SDK. The first complete unit/component run executed 30 tests: 29 passed; Monaco's visible folded-line assertion timed out while the session was locked and its display slept. Bridge/state, secure-input and native-control tests passed. This is not a desktop-interaction pass. Retry the unchanged drawing assertion once with a bounded awake display; retain its outcome separately.

Two actionable test concurrency diagnostics came from mutable captures written by `Thread.detachNewThread`. Replace them with a `Synchronization.Mutex<Result<...>?>` handoff, retaining the timeout and object-count assertions. The installed SDK supplies Mutex (macOS 15+, below this app's macOS 26 target); [Apple Mutex](https://developer.apple.com/documentation/synchronization/mutex) documents exclusive state access. No unchecked conformance or warning suppression is warranted.

The AppIntents metadata warning originates in Xcode's automatic extraction for targets with no AppIntents dependency. NeatGit has no intents; retain this notice without adding a dummy dependency. Residual risk: none for Settings; revisit if intents are introduced.

The runtime's missing `folder.badge.arrow.up` image belongs to the Rescan Projects toolbar action. Keep the inspected native Rescan Projects `Button` in `ContentView` and change only its image to `arrow.clockwise` (verified with `NSImage(systemSymbolName:)` in the installed SDK/runtime); preserve scanning behavior. WebKit's sandbox/pasteboard, unavailable launch-services/AudioComponentRegistrar and process-suspension messages are platform-process diagnostics in the test host; do not add private entitlements or weaken its sandbox. Their visible-rendering limitation remains explicit above.

The bounded-awake retry still passed 29/30 tests and timed out on the unchanged Monaco visible-lines assertion; lock remained true. The two Swift concurrency warnings disappeared after the Mutex fix. The new prompt regression first assumed SwiftUI buttons were `NSButton` descendants, then tried public `NSAccessibilityProtocol`; neither exposed the button under the lock shield. Those in-process probing assumptions were removed. The actual Cancel/Done regression now lives in `NativeWorkspaceTests`, using XCUITest identifiers and preserving the saved prompt. Desktop execution remains unavailable under system authentication; do not count it as passed. Component secure-input/light/dark rendering continues to pass. Current Settings-window visual acceptance is recorded independently after installation.

## Published Settings artifact (0.1.1)

The signed universal archive/export was built from `98f1dc26b219ba041e41e087f721f52ec447f3de`. App notarization `f53770f7-4cb8-4e8c-aabf-9f7c96db89f0` and DMG notarization `7f39d7e0-0afc-497a-be2d-96823fd04148` were accepted and stapled. Do not rebuild or re-notarize these artifacts to recover a later publication failure.

The first tag push was blocked by leakgate's historical false positive on the API-key preference-name constant (fingerprint `31a7c96469c01cd4`): this literal is a UserDefaults key, not a credential. Add only that exact fingerprint to `.leakignore` after inspecting the historical source. Keep the gate enabled. Publication recovery reuses the checksummed signed ZIP/DMG, verifies the build-input diff against the source tag is empty, regenerates only the signed feed, and resumes the existing draft/upload/full-download validation flow.

Archive diagnostics: Xcode also reports that the target has no App Category. This comes from the pre-existing project/Info metadata, not the Settings code. Direct download currently has no category-dependent behavior; retain the notice in this bounded visual release. Residual risk: category metadata is absent in system catalogs; set Developer Tools before any store submission/metadata cleanup. No Swift compiler or analyzer warning remains in the current app or Mutex test code. The AppIntents extraction notices for the app/test targets remain assessed above.

Installed 0.1.1: the complete Chinese/light Settings window was inspected at 480×441, with all four connection/edit rows, both update switches and the app-actions row visible and aligned, without a settings scrollbar. Fresh installed pixels are in the temporary acceptance directory `neatgit-settings-20261022`; they are not a physical-keyboard or VoiceOver pass. The original app rejected an AX menu query while locked; exact-PID `NSRunningApplication.terminate()` subsequently exited normally and permitted atomic replacement. Native Quit does not require force termination. Opening the installed Settings scene succeeded independently despite a subsequent AX menu-enumeration error.
