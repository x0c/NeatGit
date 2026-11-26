# 审计：AI 提交链路与视图 / 状态层是否过重（audit-ai-commit-ui）

> 只读审计，未改仓库。行号基于当前工作区（HEAD `1781139`）。路径相对仓库根。

## 一、结论

1. **点一次「AI 生成」= 1 次模型请求、1 个候选**，没有多候选打分或重试。请求本身不重。
2. **重的是「喂什么」**：450 行分析器里有两套文件评分、四条人工导读、一套符号提取，其中模块权重是按 NeatGit 自己的目录名写死的，换个仓库全部失效。这部分属于**纯内部复杂度**。
3. **调试窗口随正式包一起发布**，且有两处入口；约 330 行。注意：本机日常用的是 Debug 构建，`#if DEBUG` 挡不住，要用独立编译条件。
4. **密钥明文存在 UserDefaults**，Apple 文档明确说这是不加密的、敏感信息应放 Keychain。仓库里已有一份 Keychain 读写代码但零调用（死代码）。
5. **视图 / 状态层不重**：选择态只有一个来源，没有重复状态源，刷新没有定时器。可删的只有设计系统里没人用的常量，以及侧栏悬停预取缺少防抖。
6. 纯死代码合计约 **220 行**，删掉不改变任何行为；再加调试窗口约 330 行、启发式约 250 行。四项产品能力（发现仓库 / 查看变更 / 提交推送 / AI 生成）都不受影响。

## 二、范围 A：AI 提交链路现状（已验证，读代码）

| 问题 | 答案 | 证据 |
|---|---|---|
| 几次请求 | 1 次 HTTP POST，无重试 | `Services/CommitMessageGenerationService.swift:72-84` |
| 几次 Git 子进程 | 2 次行数统计 + 每个详析文件最多 2 次 diff；详析文件 6–15 个，串行，合计 8–32 次 | `CommitDiffAnalyzer.swift:234-243,253-287` |
| 送多少 | 代码片段上限 6×600 / 10×550 / 15×500 字符（按文件数分档）；文件摘要 18/30/48 行；外加 4 条导读 | `CommitDiffAnalyzer.swift:11-24`，`CommitPromptBuilder.swift:5-6,19-21` |
| 几个候选 | 1 个 | `CommitMessageGenerationService.swift:54` |
| 评分做什么用 | `rankingScore` 决定哪些文件进详析；`FileAnalysis.score` **只决定提示词里的排列顺序** | `CommitDiffAnalyzer.swift:148,177-205` 对比 `:35-41` |
| 输出上限 | max_tokens 1024，要求输出 confidence / reasons | `CommitMessageGenerationService.swift:79`，`CommitPromptBuilder.swift:35` |

粗估每次提示词 4K–15K 字符（未实测 token 数：代码解析了用量字段但没有任何地方读取，`LLMChatService.swift:27-33,100-105`）。

外部行为已核对官方文档（见第五节）：DeepSeek 思考模式默认开启、关闭参数就是代码里发的 `thinking.type=disabled`；JSON 模式要求提示词含 "json" 并合理设 max_tokens，代码都满足。这两处是真需求。

## 三、问题清单（按「删减收益 / 风险」排序）

| # | 问题 | 证据 | 性质 | 预计可删 | 风险 |
|---|---|---|---|---|---|
| 1 | `KeychainSecretStore` 零调用；同时密钥明文落 UserDefaults | `Services/KeychainSecretStore.swift` 全文无引用；`Stores/LLMSettingsStore.swift:32-35,53`；`Views/Settings/LLMSettingsView.swift:30` | 纯内部复杂度 + 安全 | 删死代码 87 行（或改为启用它） | 删死代码零风险；是否改用 Keychain 需用户拍板 |
| 2 | 设计系统 38 个常量只有 11 个被用到；视图里另有 26 处直接写死字号 | `Views/Design/DesignSystem.swift`（未用：Spacing 5/6、Radius 3/3、RowHeight 3/3、Palette 8/16、Font 3/5、动画）；`Views/Sidebar/RepositorySidebar.swift:84,94,118,128` | 纯内部复杂度 | 约 58 行 | 无 |
| 3 | 设置页「保存失败」弹窗永远不会出现 | `LLMSettingsStore.swift:44,110`（只被置空）；`LLMSettingsView.swift:52-71` | 纯内部复杂度 | 21 行 | 无 |
| 4 | 空枚举 `CommitGenerationStrategy`、未用的 `LLMResponseFormat.text`、未被读取的 token 用量结构、思考开关重复判两次 | `Domain/CommitGenerationStrategy.swift`；`LLMChatService.swift:31-33,100-105,135`；`CommitMessageGenerationService.swift:81` + `LLMChatService.swift:112-117` | 纯内部复杂度 | 27 行 | 无 |
| 5 | 新增文件的「取 diff」分支永远失败后回退读正文 | `CommitDiffAnalyzer.swift:290-298`；`git diff --no-index` 有差异时退出码为 1，`:440-446` 遇非 0 即抛错（已在临时目录实测） | 纯内部复杂度（隐性缺陷） | 12 行 | 无：删掉后行为与现在实际行为一致 |
| 6 | 调试窗口与调试状态随正式包发布，两处入口 | `NeatGitApp.swift:6,21-25`；`Stores/AICommitDebugStore.swift`；`Views/Commit/AICommitDebugWindowView.swift`；`CommitMessageGenerationService.swift:7-17,127-171`；`ContentView.swift:140-141,199-201`；`CommitComposerBar.swift:51-58`；`NeatGitUITests/NativeWorkspaceTests.swift:49-52` | 开发者诊断，不属于四项产品能力 | 整删约 330 行；或加独立编译条件，正式包 0 行、源码仅多十几行 | 低。**不能用 `#if DEBUG`**：日常安装的就是 Debug 构建。UI 回归需同步改 |
| 7 | 输出里的 confidence / reasons 要求模型写、却无人读取 | `Domain/CommitMessageCandidate.swift:8-9,46,58-67`；`CommitPromptBuilder.swift:35` | 纯内部复杂度，白花输出 token | 14 行 + 每次请求更省 | 无 |
| 8 | 两套文件评分；模块权重按本项目目录名（Services/Stores/Domain/Views）写死，别的仓库一律落入默认档 | `CommitDiffAnalyzer.swift:35-41,62-93,430-440`；`Domain/ChangeKind.swift:28-60` | 纯内部复杂度 | 约 110 行 | 低–中：只影响哪些文件进提示词，生成质量变化未验证 |
| 9 | 提示词里四条人工导读（模块分布 / 改动概览 / 生成侧重点 / 业务线索） | `CommitPromptBuilder.swift:55-142` | 纯内部复杂度（用规则替模型判断主次） | 约 85 行 | 中：把「以代码为主」类规则并进系统提示词即可，但对质量的影响未验证 |
| 10 | 符号提示只认 Swift 关键字，其余语言退到标识符猜 | `CommitDiffAnalyzer.swift:366-427` | 纯内部复杂度 | 约 60 行（与 8/9 有重叠） | 中：未验证 |
| 11 | JSON 解析失败后的「取首行」回退；官方说明 JSON 模式下非 JSON 会被替换成空格 | `CommitMessageGenerationService.swift:104-116`；`CommitMessageCandidate.swift:96-149` | 纯内部复杂度 | 35 行 | 低–中：换不支持 JSON 模式的服务商时才用得上 |
| 12 | 侧栏悬停即预取仓库状态，没有防抖；扫过列表会连发子进程（每次 2 个 Git 进程，只缓存 10 个仓库） | `RepositorySidebar.swift:141-146`；`Stores/RepositoryStatusStore.swift:86-104` | 用户可感知（切仓库零等待），但代价是鼠标划过就跑 Git | 不删，建议加几行防抖 | 低 |
| 13 | 「同时只展开一组」的约束带来一整套校正逻辑 | `Stores/WorkspaceSelectionStore.swift:15,29,33-35,48-58`；`Views/Sidebar/RepositorySidebar.swift:60-69` | 用户可感知的交互选择 | 约 20 行 | 需用户拍板是否允许多组同时展开 |
| 14 | 提交栏把 10 个参数逐个透传；两个忙碌标记可合并为一个状态 | `ContentView.swift:161-182`；`CommitComposerBar.swift:3-12`；`CommitWorkflowStore.swift:27-33` | 纯内部复杂度 | 约 10 行 | 无，收益小 |

第 5、8、9、10 项都落在同一个文件，行数不可简单相加；分析器加提示词构建器共 593 行，瘦身后估计 300 行上下（估计值，未验证）。

## 四、用户可感知能力 vs 纯内部复杂度

**用户可感知、建议保留（属于产品方向）**

- 一键生成、结果直接进输入框：`CommitWorkflowStore.swift:76-125`。
- 可改的系统提示词、可换服务商和模型：`LLMSettingsView.swift:8-46`。对开源工具是真需求。
- 关闭思考模式、JSON 输出、片段按文件数分档截断：经官方文档核对为真需求。
- 新增文件读正文节选：新增文件是高频场景，保留（第 5 项只删失败的那条分支）。
- 生成失败时的错误弹窗、AI 未配置时引导去设置：`CommitWorkflowStore.swift:96-103,116-119`。
- 侧栏星标、悬停预取、刷新：保留，补防抖。

**纯内部复杂度（删了用户看不出区别）**

- 第 1–5、7 项：约 220 行死代码，零行为变化。
- 第 8–11 项：约 250 行启发式，用户唯一可能感觉到的是生成质量的细微差别，目前没有任何对照数据。
- 第 14 项：样板。

**需用户拍板**

- 第 1 项后半：密钥是否迁到 Keychain。`docs/AI_COMMIT_GUIDE.md:158` 记录过「不要迁回 Keychain」，但没写理由；设置页 `LLMSettingsView.swift:30` 如实告知用户密钥存本地设置。
- 第 6 项：调试窗口整删，还是用独立编译条件默认不编入。
- 第 13 项：是否允许侧栏多组同时展开。

## 五、范围 B：选择态、状态源、刷新

- **选择态传递**：只有 `WorkspaceSelectionStore` 一个来源（选中仓库 / 展开组 / 文件多选 / 悬停），主视图每次从 ID 反查对象，不另存副本：`WorkspaceSelectionStore.swift:14-17,86-106`，`ContentView.swift:71-79`。文件面板的分区展开是面板私有的 `@State`：`RepositoryFilePanel.swift:17`。**未发现重复状态源。**
- **刷新触发**共 5 处，无定时器、无文件系统监听：切仓库、回到前台、手动刷新、提交后、文件操作后（`ContentView.swift:51-63,105-109,208,226`）。每次是 2 个 Git 进程（`GitRepositoryStatusLoader.swift:9,17`）。密度不算过密；唯一偏密的是第 12 项的悬停预取。
- **右侧预览**用「仓库 + 版本号 + 文件」拼成的签名驱动，悬停预取已有 60ms 延迟：`RepositoryPreviewPane.swift:17-28,119-125`，`RepositoryDiffStore.swift:7`。这是项目文档里写明为规避编译器崩溃刻意保留的写法，不建议动。
- 文件状态样式 `RepositoryFileStatusStyle.swift` 结构简单、只有一个使用点（`RepositoryFilePanel.swift:204`），仅 `showsUnstagedIndicator` 无人调用（`:126-129`，4 行）。

## 六、外部依据

本轮 `tavily_search` / `tavily_extract` 真实调用均返回 429（小时配额用尽），无法检索。以下为直接抓取官方文档页面所得：

- Apple `UserDefaults` 文档：「以不加密格式存盘；不要存个人或敏感信息，敏感信息放 Keychain」。https://developer.apple.com/documentation/foundation/userdefaults
- DeepSeek 思考模式文档：「默认开启」；OpenAI 格式下用 `{"thinking":{"type":"enabled/disabled"}}` 关闭；思考模式下 temperature 无效（代码发的 0.1 无害）。https://api-docs.deepseek.com/guides/thinking_mode
- DeepSeek JSON 输出文档：需 `response_format` 为 `json_object`、提示词含 "json"、合理设置 `max_tokens`；输出无法识别为 JSON 时会被替换为空格。https://api-docs.deepseek.com/guides/json_mode
- OpenAI 结构化输出文档未取到（同一原因），代码对该接口的行为未做外部核对。

## 七、未验证假设

- 瘦身第 8–11 项后生成质量的变化：没有对照样本，需要拿真实仓库各生成一轮比较。
- 「不迁回 Keychain」的原委：文档没写。一种可能是自动签名每次重打包后钥匙串会重新弹授权，但这只是猜测，没有证据。
- 提示词的 token 数是按字符上限粗估的。
