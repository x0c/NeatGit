# Operations 指南

> 覆盖范围：本地构建步骤、运行时验证路径、常见阻碍排查。差异预览是原生实现，没有网页前端构建步骤。

---

## 一、环境前提

| 项目 | 要求 |
|------|------|
| macOS | 26.0+ |
| Xcode | 26+; select a complete installed Xcode and record `xcodebuild -version` |
| Swift | 6.0 |
| XcodeGen | 需安装（`brew install xcodegen`） |

不需要 Node.js、npm 或任何前端工具链：差异预览由系统文本视图原生渲染，应用包内不再带网页资源。

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

## 三、差异预览无需前端构建

差异预览是纯原生实现（`NeatGitApp/Views/Diff/` 下的系统文本视图），没有网页源码，也没有需要预先构建再拷进应用包的资源。

- 干净检出后只需 `xcodegen generate` 即可构建，不存在“先构建网页”的前置步骤。
- 应用包内不再有 `Resources/MonacoDiff/` 之类的网页资源目录；如果在本机看到残留的旧构建产物，直接删除即可，不要提交。
- 历史说明：早期版本用 WebView 承载 Monaco 网页做差异预览，该方案已整体移除，调研与决策记录见 [`LIGHTWEIGHT_RESEARCH.md`](LIGHTWEIGHT_RESEARCH.md)。

---

## 四、运行时验证路径

### 4.1 仓库扫描

启动 App 后左侧栏自动扫描 Home 目录（约 1-3 秒），出现仓库列表说明扫描链路正常。

### 4.2 文件状态读取

选中左栏任意仓库 → 中间面板出现文件列表（changed / skipped / ignored 分组）说明 `GitRepositoryStatusLoader` 正常工作。

### 4.3 Diff 预览

点击中间面板任意 changed 文件 → 右侧出现原生差异预览：默认折叠长段未变更内容，可关闭“只看变更”看全文；“差异布局”可切并排（左原文、右改后）或单栏，由头部选择控制，不随窗口宽度自动切换。
若预览空白或没有内容，检查：
- 该文件行是否处于展开状态：右侧以全部变更文件的折叠列表呈现，只有展开的文件才加载差异。
- 文件是否超出当前边界：超过约 5 MB 的文本、二进制文件、冲突文件会显示中文说明而不是差异内容，属于预期行为。
- 加载失败时右侧是否给出中文错误说明，按提示核对仓库状态后手动刷新文件列表。
- 改过 `NeatGitApp/Views/Diff/` 后出现整片空白或改尺寸时崩溃：对照[核心知识库 2.8](NEATGIT_KNOWLEDGE_BASE.md#28-原生差异渲染链路)的装配顺序与容器高度约束，这是最常见的两个原因。

### 4.4 AI commit message 生成

1. 用 `⌘,` 打开设置，填写兼容 OpenAI 接口的服务地址、模型和密钥。
2. 选择有可提交更改的仓库 → 点击底部 AI 生成 → 提交说明框自动填入；文件行选择仅控制预览。
3. 如生成失败，打开 `Window → AI 调试`（或通过 `AICommitDebugWindowView`）查看 prompt 和 error 详情。

### 4.5 自动化回归与验证边界

先执行 `xcodegen generate` 生成工程（没有网页构建步骤），然后运行：

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
- `NativeDiffRenderTests`：只看变更折叠（前后各留 3 行上下文、行号保持真实值）、展开恢复、并排两栏行数一致、回车符不显示。
- `NativeDiffViewHostTests`：挂载真实原生差异视图，验证连续切换文件时旧结果不上屏、只看变更与展开只重排不重算差异；`NativeDiffFastPathTests` 验证小文档不再等待异步调度。
- `TextDiffCalculatorTests`：行级与行内差异计算。
- `NativeWorkspaceTests`：桌面点击仓库/文件、编辑与 ⌘Z、打开/关闭调试和设置窗口；不执行提交、推送或收费 AI 请求。
- 锁屏/系统认证时，XCUITest 可能在测试代码执行前失败。组件内截图与视图内部状态断言不能替代完整桌面点击验收；报告此限制，不关闭锁屏安全策略。键盘撤销的窗口路由/绑定回写仍由 XCUITest 验证，组件直接操作 UndoManager 仅证明文本控件可撤销。
- 环境改进待办：为桌面回归准备已解锁并获系统自动化授权的受控会话；未经授权不修改锁屏或隐私权限设置。

历史验证基线（2026-10，对应已移除的网页差异视图，仅作记录，不代表当前测试集）：macOS 26.7 / Xcode 26.3 下，12 项组件、差异状态与真实 WebView 测试通过；浅深色组件截图和 Chrome 差异显示、只读交互均已核验。完整桌面 XCUITest 因系统认证阻止初始化，未完成窗口点击与快捷键端到端验收，不能将其计入通过项。

After successful verification and a committed source snapshot, follow root `AGENTS.md` §8 and `RELEASING.md` for signed installation and launch of `/Applications/NeatGit.app`，核验进程路径和 PID。构建失败时不替换安装包。

### 4.6 交互性能采集

执行 `scripts/profile-interactions.sh /Applications/NeatGit.app 60s`，录制期间走一遍项目、文件、刷新与差异控件点击。脚本输出 Instruments trace、统一日志和 P50/P95/最大耗时摘要，不自动抢前台。指标口径、优化基线和未验证边界以 [交互性能指南](INTERACTION_PERFORMANCE.md) 为准；不要把后台 Git 耗时当成主线程点击耗时，也不要用加载指示器出现代替内容就绪。

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
| 签名归档报 `No signing certificate` | 先用 `security find-identity -v -p codesigning` 核对证书与私钥。2026-11-27 本次环境返回 0 个有效身份，Developer ID 安装因此阻断；`CODE_SIGNING_ALLOWED=NO` 只用于本地 Debug 构建/测试，不得用未签名或 Debug 产物替换 `/Applications/NeatGit.app` |
| 差异预览空白 | 先确认该文件行已展开（只有展开的文件才加载差异），再看是否属于超 5 MB / 二进制 / 冲突的预期说明；改过差异视图后整片空白或改尺寸崩溃，对照[核心知识库 2.8](NEATGIT_KNOWLEDGE_BASE.md#28-原生差异渲染链路)的装配顺序与容器高度约束 |
| 仓库扫描超时 / 卡死 | 检查 Home 目录下是否存在超深嵌套或超大 node_modules（扫描深度上限 6，但部分目录未被排除规则覆盖） |
| AI 生成请求失败 | 在 AI 调试窗口查看 errorMessage；检查设置中的地址、模型和本地保存的密钥 |
| 应用内设置（如 LLM 配置）丢失需重填 | 2026-10-21 应用标识为开源脱敏统一变更为 `io.github.x0c.neatgit`，本地偏好与钥匙串随新标识域重新开始，属一次性影响，重填即可 |
| xcodegen generate 报文件找不到 | 确认 `project.yml` 中 sources 路径与实际文件路径一致 |
| SwiftUI 类型检查超时 | 把三栏、工具栏、状态监听、弹窗拆成独立属性，勿继续堆一个超长 View 表达式 |
| XCUITest 初始化报 `System authentication is running` | 系统认证/锁屏阻止桌面自动化；不能通过加延时或换坐标解决，需要解锁并允许系统测试授权 |

<!-- 该文档整理/压缩于 2026-10-21 -->

## Settings rollout diagnostics (2026-10-22)

> 历史记录：以下为 2026-10-22 发布 0.1.1 当时的原始记录。其中的 Monaco / WebView 用例属于已整体移除的网页差异视图，不再对应当前测试集，保留只为追溯当时的结论。

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

### Final 0.1.1 delivery evidence

The GitHub release is public at `https://github.com/x0c/NeatGit/releases/tag/v0.1.1`. All three assets were downloaded anonymously in full and matched local bytes:

| Asset | Bytes | SHA-256 |
|---|---:|---|
| NeatGit-0.1.1.dmg | 5075341 | ab958dd2561385e3a2305af11822d24d9689ca7d35c3fdbbb4e7400690c9d11b |
| NeatGit-0.1.1.zip | 5073420 | a19b1446c94aa1bd4928745c1cd425ec1f592ed56fadaf29136b8377f957ce8b |
| SHA256SUMS.txt | 168 | b159ed54f79cee9357834ce4d00d9582309150e8fea1abcf3062baebb3c7e7f5 |

The installed executable matches the signed export. The normal public `SUFeedURL` now serves build 2; its embedded Ed25519 feed signature and the ZIP enclosure signature passed against the installed public key. The first raw-CDN response was the old empty feed; propagation was verified without replacing assets. A transient GitHub API EOF during draft publication was retried only at that step. Sparkle 2.10.0 was used consistently in Debug build/analyze, test builds and the signed export.

A `sign_update --verify` process stalled because the inspected tool loads a Keychain key pair even for verification. Only that owned stalled process was stopped, and verification completed with CryptoKit plus the installed public key. The shared signing guide owns the reusable procedure; no secret was exported or logged.

The current desktop UI regression was attempted after `build-for-testing`; XCUITest failed to initialize with `Timed out while enabling automation mode` before entering the test. This leaves prompt Cancel/Done, physical keyboard and VoiceOver unverified under the locked session. The 29/30 component result and the unchanged locked-WebKit visible-folded-lines failure remain explicit; no skipped or failed assertion is counted as passed. Light/dark component renders and installed Chinese/light Settings geometry passed. The existing lack of a product app-icon asset remains outside this visual settings change; the about row uses the actual system application icon without inventing a brand asset.

Preferences were compared through hashes, without dumping credentials. The API URL key changed from absent to the existing default when the native field initialized; its effective URL was unchanged. Model, API key and system-prompt keys were unchanged. No user repository commit/push or paid AI call was performed during UI acceptance. The user’s app was initially running and remains running; no temporary display or permanent appearance/power setting was introduced.
