# 原生 diff 视图可行性调研（tech-native-render）

> 调研性质：只读。标记说明：「已验证」= 有官方文档、SDK 接口文件或本机实测支撑；「未验证假设」= 需写原型确认。代码量均为「估算」。

## 1. 结论

- **一句话结论（已验证 + 估算）**：用系统原生控件做专业 diff 视图在 macOS 26 / Swift 6 下可行，但 Apple 没有现成的「代码视图 / diff 视图」组件，可行的是「AppKit 文本视图 + 自己画行号栏和行底色」这条路；macOS 26 的新文本能力（富文本编辑器）帮不上 diff 场景。
- **首选**：NSTextView（TextKit 2）只读可选 + 自绘行号栏 + 文本着色，用系统包装放进 SwiftUI，不引入任何第三方依赖。
- **备选**：现成第三方文本视图组件 STTextView（功能最贴，但许可证是 GPL-3.0 或商业授权，需先拍板）。
- **不建议**：SwiftUI 新富文本编辑器（只能编辑、无行号、无整行底色）；纯 SwiftUI 逐行渲染（跨行选择复制做不了）；CodeEditSourceEditor（作者自述未到生产可用）。

## 2. 本机环境（已验证，`sw_vers` 与 `xcodebuild -version` 实测）

| 项 | 实测值 | 共享上下文 / 项目文档所写 |
|---|---|---|
| macOS | 26.7 | 部署目标 26.0，一致 |
| Xcode | 27.2（SDK 为 macOS 27.2） | 文档写 Xcode 26，**不一致** |
| Swift 编译器 | 6.4 | 文档写 Swift 6.0（语言模式），不矛盾但需知悉 |

**发现**：本机实际工具链已是 Xcode 27.2。本文所有「SDK 接口核对」基于 macOS 27.2 SDK，可用性下限以标注的系统版本为准；用 Xcode 26 构建时的行为未核对。

## 3. macOS 26 新文本能力清单

| API 确切名称 | 框架 | 最低版本 | 官方来源 | 核对方式 |
|---|---|---|---|---|
| `TextEditor.init(text:selection:)`（参数为 `Binding<AttributedString>` 与可选 `Binding<AttributedTextSelection>`） | SwiftUI | macOS 26.0 | https://developer.apple.com/documentation/swiftui/texteditor/init(text:selection:) | 文档直取 + SDK 接口文件 |
| `AttributedTextSelection` | SwiftUI | macOS 26.0 | https://developer.apple.com/documentation/swiftui/attributedtextselection | 文档直取 |
| `AttributedTextFormattingDefinition`（协议） | SwiftUI | macOS 26.0 | https://developer.apple.com/documentation/swiftui/attributedtextformattingdefinition | 文档直取 |
| `AttributedTextValueConstraint`（协议） | SwiftUI | macOS 26.0 | https://developer.apple.com/documentation/swiftui/attributedtextvalueconstraint | 文档直取 |
| `textInputFormattingControlVisibility(_:for:)` | SwiftUI | 未核对下限 | 见 TextEditor 文档页 | SDK 接口文件 |
| `textSelectionAffinity(_:)` | SwiftUI | 未核对下限 | 见 AttributedTextSelection 文档页 | SDK 接口文件 |
| AttributedString 属性 `alignment`、`lineHeight`（SwiftUI 属性作用域新增） | SwiftUI / CoreText | macOS 26.0 | https://developer.apple.com/videos/play/wwdc2025/280 | SDK 接口文件 + WWDC25 代码讲解文字稿 |
| AppKit 文本新增仅 `includesTextListMarkers`、`resolvesNaturalAlignmentWithBaseWritingDirection` | AppKit | macOS 26.0 | 无独立文档页 | SDK 头文件 |

WWDC25 代码讲解（https://developer.apple.com/videos/play/wwdc2025/280）列出新编辑器支持的属性：粗体、斜体、下划线、删除线、字号、前景与背景色、字距、基线偏移、Genmoji、行高、对齐、书写方向。（已验证，取自文字稿）

**全局检索结论（已验证）**：在本机 SDK 全部 Swift 接口文件与 AppKit 头文件中检索「行号」「语法高亮」相关符号，除辅助功能常量与 XML 解析器外零命中。即 **Apple 没有公开的行号栏或语法高亮 API**，macOS 26 也没有新增。

### 四项能力确认（针对 SwiftUI 新富文本编辑器）

| 能力 | 结论 | 依据 |
|---|---|---|
| 能否只读 | **无只读开关**（已验证）。该视图在 SDK 接口中只有构造器与主体，文档定位是「让用户输入和编辑」；用禁用态或常量绑定模拟只读后的观感与可复制性：未验证假设 | SDK 接口文件、文档直取 |
| 能否按行设置底色 | **只能按字符区间设置背景色，不能整行铺满**（背景色属性存在：已验证；不铺满：未验证假设，需原型确认） | SDK 接口文件属性清单 |
| 能否并排 | 无并排能力，只能外部摆两个；两栏滚动同步无现成接口：未验证假设 | SDK 接口文件 |
| 能否对齐行号栏 | 无行号栏 API（已验证）；自行叠加对齐：未验证假设 | 全局检索零命中 |

**补充（已验证）**：WWDC26「Elevate your app's text experience with TextKit」（https://developer.apple.com/videos/play/wwdc2026/370）给出了系统文本视图加行号栏的官方做法，所用钩子 `textViewportLayoutController(_:configureRenderingSurfaceForTextLayoutFragment:)`、`textViewportLayoutControllerWillLayout:`、`textViewportLayoutControllerDidLayout:`、`viewportBoundsForTextViewportLayoutController:` 在 SDK 头文件中标注 macOS 27.0 起可用，**本项目部署目标 macOS 26 用不上**。

## 4. 传统路线：NSTextView（TextKit 1 / 2）

- **承载方式（已验证）**：用 SwiftUI 的 `NSViewRepresentable` 把 NSTextView 包进 SwiftUI。WWDC26 文字稿明确「用 ViewRepresentable 把这些文本视图带进 SwiftUI 应用」。这也是项目 AGENTS.md「优先原生」的方向。
- **选择与复制（已验证）**：`isEditable` 设为否、`isSelectable` 设为是即可只读可选，选择、复制、查找、辅助功能全部由系统接管。官方文档：https://developer.apple.com/documentation/appkit/nstextview/isselectable 、https://developer.apple.com/documentation/appkit/nstextview （文档另注明：不可选会连带不可编辑）。
- **排版引擎（已验证）**：TextKit 2 自 macOS 12 起按可视区域惰性排版。`NSTextLayoutManager`：https://developer.apple.com/documentation/appkit/nstextlayoutmanager ；`NSTextViewportLayoutController`：https://developer.apple.com/documentation/appkit/nstextviewportlayoutcontroller 。
- **行号栏（已验证无现成 API；做法未验证）**：需自画一个行号栏视图。可用接口：`enumerateTextSegments(in:type:options:using:)` 取行位置、`NSTextLayoutFragment` 的 `layoutFragmentFrame`（https://developer.apple.com/documentation/appkit/nstextlayoutfragment ）。macOS 27 才有官方钩子，macOS 26 上须自己监听滚动与排版变化：未验证假设。
- **整行底色（未验证假设）**：背景色属性只覆盖文字区间，铺满整行需自定义绘制。可用接口：`NSTextLayoutManagerDelegate.textLayoutManager(_:textLayoutFragmentFor:in:)` 提供自定义排版片段（https://developer.apple.com/documentation/appkit/nstextlayoutmanagerdelegate ），片段的绘制入口是 `draw(at:in:)`。注意 AppKit 这一层**没有**单独的「画背景」方法（文档主题列表已核对）。
- **着色方式（已验证接口存在）**：`renderingAttributesValidator`、`setRenderingAttributes(_:for:)`、`invalidateRenderingAttributes(for:)` 可按区间设置渲染属性而不改文本内容。

## 5. 纯 SwiftUI 路线（逐行渲染）

- **虚拟化方式（已验证）**：`ScrollView` + `LazyVStack`，官方说明「仅在需要上屏时才创建子视图」（https://developer.apple.com/documentation/swiftui/lazyvstack 、https://developer.apple.com/documentation/swiftui/creating-performant-scrollable-stacks ）。
- **选择复制（已验证接口 + 未验证行为）**：`textSelection(_:)` 可让单个 `Text` 可选（https://developer.apple.com/documentation/swiftui/view/textselection(_:) ）。**跨多行连续选择、拖拽选择**：无公开接口支持，判断为做不到或体验很差——未验证假设。
- **性能风险（未验证假设）**：每行是一个独立视图，万行意味着万级视图身份参与差异计算；滚动时逐行创建有掉帧风险。Apple 未给公开基准，本轮也未做 SwiftUI 实测：**无证据**。
- **结论**：适合做「只看变更」这类短列表或摘要，不适合做专业 diff 主体（未验证假设，但跨行选择这一条已足以否决）。

## 6. 语法高亮可选方案

| 方案 | 许可证 | 维护状态（GitHub 实查） | 体积增量 | Swift 6 严格并发 | 结论 |
|---|---|---|---|---|---|
| Apple 官方高亮能力 | — | SDK 全量检索零命中（已验证） | — | — | **不存在**，不适用 |
| 不做语法高亮，只做 diff 着色 | — | 无依赖 | 0 | 无影响 | 首选的第一步 |
| Highlightr | MIT | 2.3.0（2025-06-18），仓库 2026-02 仍有提交 | 未查到公开数据 | 包清单工具版本 5.3，未声明严格并发：未验证 | 底层仍是 highlight.js 跑在系统脚本引擎里，**并没有摆脱 JS**，与「去 Web 化」目标只去掉一半 |
| Splash | MIT | 最新 0.16.0（2021-06-14），仓库 2024-05 后无提交 | 未查到公开数据 | 未核对 | 只支持 Swift 一种语言，基本停更，不建议 |
| swift-tree-sitter（已迁入 tree-sitter 官方组织） | BSD-3 | 0.10.0（2026-03-18） | 核心库本机实测约 +554 KB（见第 7 节），不含任何语言语法 | 包清单显式开启严格并发实验特性（已验证）；在 Swift 6 语言模式下编译通过（已验证） | 可行，但每种语言语法要单独接入 |
| CodeEditLanguages（打包全部语言的二进制） | MIT | 0.1.20（2024-11-20） | 语言包压缩后 **32.7 MB**（已验证，仓库文件大小） | 未核对 | 比现在内嵌的网页资源 12 MB 还大，否决 |

**接入阻力（已验证，本机实测）**：直接以源码方式依赖 Swift 语法包 tree-sitter-swift 0.7.4，两种构建系统下均失败，报「找不到 `tree_sitter/parser.h`」与「`src/parser.c` 不存在」；其自述文件也写明应通过 Rust 包或 npm 包使用。即语法文件需自行生成或找预编译产物，接入成本明显高于预期。tree-sitter 本体仓库已转为 Rust 语言，最新版是否仍提供 Swift 包清单：未核对。

## 7. 性能证据

| 来源 | 内容 | 性质 |
|---|---|---|
| 本机实测（本文） | 见下方「测量方式」 | 一手实测，仅 CPU 侧 |
| CodeEditSourceEditor 公开 issue #358（2025-11-17，未关闭） | 「滚动卡顿、语法高亮刷新慢」，任意较长文件即可复现 | https://github.com/CodeEditApp/CodeEditSourceEditor/issues/358 |
| 同仓库 issue #360（2025-12-31，未关闭） | 「滚动时严重闪烁」 | https://github.com/CodeEditApp/CodeEditSourceEditor/issues/360 |
| 同仓库 issue #184（已关闭） | 「大文件滚动时滚动条抖动」 | https://github.com/CodeEditApp/CodeEditSourceEditor/issues/184 |
| CodeEditTextView 自述 | 「首屏排版极快、支持大文档」，同时声明只在特定场景可替代系统文本视图 | https://github.com/CodeEditApp/CodeEditTextView |
| STTextView 自述 | 「长内容平滑滚动」，无数字 | https://github.com/krzyzanowskim/STTextView |
| Highlightr 自述 | 「iPhone 6s 上处理 500 行约 50 毫秒」（多年前旧机型，仅供参考） | https://github.com/raspu/Highlightr |
| 万行级滚动帧率、SwiftUI 逐行渲染基准 | **无证据**（检索配额用尽，未查到公开数据） | — |

**本机实测一：排版耗时（已验证）**

测量方式：命令行程序、无窗口无绘制、12pt 等宽系统字体、容器宽 900pt、每行约 95 字符、每 5 行有 2 行带背景色区间；预热后测「构造着色文本 + 强制全文排版」的耗时，各档只跑一次。TextKit 1 用 `ensureLayout(for:)`，TextKit 2 用遍历全部排版片段强制排版。

| 行数 | 字符数 | 着色构建 | TextKit 1 全文排版 | TextKit 2 全文排版 |
|---|---|---|---|---|
| 1,000 | 约 9.4 万 | 约 22 ms（含预热） | 15 ms | 19 ms |
| 10,000 | 约 95 万 | 约 1 ms | 144 ms | 196 ms |
| 50,000 | 约 479 万 | 约 4 ms | 731 ms | 1,053 ms |

解读：万行级全文排版约 0.2 秒，放主线程会有一次可感知卡顿，需移出主线程或只排可视区（未验证假设）。TextKit 2 的可视区惰性排版「首屏耗时」本轮**没测出来**（计时为 0，方法无效）。滚动帧率、绘制耗时、内存占用均**无证据**。

**本机实测二：tree-sitter 体积（已验证）**

测量方式：两个空壳可执行程序对比，均 release 构建、arm64 静态链接；一个什么都不依赖（52,232 字节），一个只链接 tree-sitter 0.25.10 核心库与 swift-tree-sitter 0.10.0 包装层（606,112 字节）。增量约 554 KB，**不含任何语言语法**。单个语言语法编译后的体积：未核对（实测接入失败，见第 6 节）。

## 8. 六个难点逐项结论

| 难点 | 结论 | 依据 |
|---|---|---|
| 并排行对齐 | 可解但要做工作（未验证假设）。左右各一个文本视图，关掉自动换行、统一行高，再同步滚动位置。现有网页方案默认并排且可切「内联」模式，原生要自己实现两种布局 | 现有前端配置实查 |
| 行内（词级）高亮 | 易解（未验证假设）。词级差异区间叠加更深的底色即可，属于同一种着色机制；难点在词级差异算法本身，不在渲染 | 机制推断 |
| 超长行横向滚动 | 传统路线可解（未验证假设）：容器宽度不随视图变化即可横向滚动，具体属性名未核对。并排时左右两栏横向滚动是否联动需定规则。纯 SwiftUI 路线需整块内容横向滚动，两栏联动更难 | 机制推断 |
| 跨行选择复制 | 传统路线系统自带（已验证接口）；纯 SwiftUI 逐行渲染做不到（未验证假设，但无公开接口）；新富文本编辑器只读后能否选择复制未验证 | 见第 3、4 节 |
| 暗色模式增删底色 | 未验证假设。用随外观变化的系统语义色加透明度即可，风险低；但要同时满足「高对比度」外观，需在原型里对照现有三套主题验收 | 现有前端有三套主题 |
| 万行级滚动 | 无直接证据。间接证据是第三方同类组件有多个滚动卡顿与闪烁的未关闭 issue（见第 7 节），说明「原生 = 自动流畅」不成立，必须写原型实测 | 第 7 节 |

另有两项现有能力原生侧需重做（已验证其存在于现有前端配置）：隐藏未变更区域、按文件类型切换语法高亮（查不到对应语言时回退纯文本）。

## 9. 候选方案对比

代码量为「估算」，按现有 Swift 代码风格与测试习惯推算，含测试。

| 方案 | 体积增量 | 预计代码量 | 性能 | 原生观感 | 风险 | 长期维护成本 |
|---|---|---|---|---|---|---|
| **A. NSTextView（TextKit 2）+ 自绘行号栏与行底色，零依赖** | 0 | 800–1,200 行 | 万行全文排版约 0.2 秒（本机实测），滚动帧率无证据 | 最好：选择、复制、查找、滚动条、辅助功能全是系统的 | 整行底色与行号栏要自己画；并排同步要自己做；macOS 27 才有的官方钩子暂时用不上 | 中：系统组件长期稳定，自有代码需自己维护 |
| B. 第三方 STTextView | 未查到公开数据 | 300–500 行（只做接入与着色） | 自述长内容平滑，无数字 | 好：基于 TextKit 2，自带行号栏、区间高亮、SwiftUI 包装 | **GPL-3.0 或商业授权**；要求 macOS 14+ 与 Xcode 26+；仓库根目录目前没有许可证文件（已验证），采用即需对整个应用做许可证决策 | 中：依赖单一维护者 |
| C. 第三方 CodeEditSourceEditor | 未查到公开数据（其全语言包 32.7 MB） | 300–500 行 | 有滚动卡顿、闪烁的未关闭 issue | 好，类 Xcode | 作者自述「仍在开发、未到生产可用」（已验证）；依赖多个子包 | 高 |
| D. SwiftUI 新富文本编辑器 | 0 | 200–400 行 | 无证据 | 好 | 无只读开关、无行号栏、不能整行铺底色、面向富文本编辑而非代码 | 低但功能缺口无法弥补 |
| E. 纯 SwiftUI 逐行渲染 | 0 | 500–800 行 | 无证据，结构性最弱 | 好 | 跨行选择复制做不到 | 中 |
| F. 维持现状（内嵌网页编辑器） | 12 MB 资源 | 0 | 现状 | 与系统有割裂感 | 与本轮「轻量化」目标相反 | 低 |

**首选：A**。理由（已验证 + 估算）：零依赖、体积增量为 0、系统接管选择复制、与项目「原生优先」一致；现有承载点只有一处 327 行的视图文件，替换范围可控。建议分两步：先只做 diff 着色不做语法高亮，语法高亮作为第二步单独评估。

**备选：B**，前提是接受 GPL-3.0 或购买商业授权。

**现有交互需求清单（已验证，取自现有前端配置与承载视图）**：并排且可切内联、词级差异算法、只读、行前增删标记、隐藏未变更区域、按文件类型高亮或回退纯文本、等宽字体、浅色 / 深色 / 高对比三套外观、「只看变更」开关、加载失败可重试。原生方案需逐项对齐或明确放弃。

## 10. 必须写验证原型才能确认的未验证点

1. 整行铺满的增删底色：自定义排版片段绘制是否与选择高亮、系统查找条正确叠放。
2. 行号栏与正文逐行对齐：关闭自动换行后行高是否处处一致；空行、超长行、emoji 与中文混排是否错位。
3. 并排两栏滚动同步：纵向必同步、横向如何联动；切换内联模式时的布局重建成本。
4. 万行级滚动帧率与内存：需在真实窗口里实测，本文只测了无绘制的排版耗时。
5. TextKit 2 可视区惰性排版的首屏耗时（本文未测出）。
6. 超长行（数千字符）横向滚动的流畅度。
7. 暗色与高对比外观下增删底色的可辨识度，对照现有三套主题验收。
8. 系统包装进 SwiftUI 后的焦点、键盘、尺寸变化、窗口分栏拖动表现；项目文档提示本仓库预览区在复杂 SwiftUI 写法下易触发编译器崩溃，需确认包装层不引入同类问题。
9. Swift 6 严格并发：文本视图只能在主线程操作，解析与着色需在后台算好再回主线程套用，验证无数据竞争告警。
10. 词级差异结果的着色叠加效果。
11. 语法高亮若要做：单个语言语法的接入方式与体积（本文接入 Swift 语法失败）；tree-sitter 新版本是否仍提供 Swift 包清单。
12. 用 Xcode 26（而非本机 Xcode 27.2）构建时的行为差异。

## 11. 外部依据来源说明

| 来源类型 | 内容 |
|---|---|
| Apple 官方文档页直取（开发者文档数据接口，逐页读取） | 新富文本编辑器构造器与类型、格式化定义与值约束协议、`NSTextLayoutManager`、`NSTextViewportLayoutController`、`NSTextLayoutFragment`、`NSTextLayoutManagerDelegate` 的声明与可用版本 |
| Apple 官方会话页直取（文字稿） | WWDC25 代码讲解 280（富文本编辑器支持的属性清单）、WWDC26 会话 370（系统文本视图加行号栏的官方做法） |
| 本机 SDK 接口文件与头文件直查 | 全部 Swift 接口文件与 AppKit 头文件的行号 / 语法高亮符号检索；macOS 26 AppKit 文本新增项；WWDC26 所述钩子的可用版本为 macOS 27.0；新属性 `alignment`、`lineHeight` |
| Context7（Apple 文档镜像） | `isEditable` / `isSelectable` 语义、可视区排版控制器说明、`LazyVStack` 与 `textSelection(_:)` 用法（均与上面的官方页一致） |
| 网页检索（仅成功 1 次，其余因小时配额用尽失败） | 命中 STTextView 与 WWDC26 会话 370，随后均改为直取原页面核对 |
| GitHub 仓库与 issue 直取 | 第 6、7、9 节的版本、日期、许可证、issue 标题、自述内容 |
| 本机实测 | 第 7 节两项测量，方法已在该节写明；实测程序放在系统临时目录，未改动仓库 |
| **未能核对** | 万行级滚动帧率与 SwiftUI 性能的公开基准或文章；Highlightr、Splash、STTextView、CodeEditSourceEditor 的二进制体积增量；这些包在 Swift 6 语言模式下的编译情况（swift-tree-sitter 除外）；`textInputFormattingControlVisibility(_:for:)` 与 `textSelectionAffinity(_:)` 的最低系统版本；横向滚动相关属性的确切名称；CodeEditSourceEditor 自带「文本差异」功能的范围 |
