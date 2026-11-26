# 主流 Git 客户端：diff 视图「做轻 / 做重」的真实做法

任务 key：`competitors-mainstream` · 调研日期：2026-11-26 · 只读调研，未改仓库

## 一、结论（先看这里）

1. **【已验证】专业级 diff 不需要内嵌代码编辑器。** 10 个对象里，明确把 Monaco 代码打进安装包的只有 GitKraken（它本来就是 Electron 应用）；GitHub Desktop 同为 Electron，却只用 CodeMirror 的「分词器」在后台线程算高亮 token，diff 行是自己画的，没有编辑器控件；GitButler 是 Tauri 网页壳，diff 也是自绘组件 + shiki 分词，没有编辑器控件。原生派（Fork、Tower、Sourcetree、Sublime Merge）全部用系统文本栈或自绘引擎，「语法高亮」靠的是一个**只负责分词的高亮库**，而不是编辑器。
2. **【已验证】轻量派的做法 = 原生文本布局 + 独立分词器 + 自己排 diff 行。** Tower 包里带的是 highlight.js v11.8.0（约 1MB 的纯 JS），由原生文本控件着色；Fork 里有「关闭语法高亮」开关和 Split/SideBySide 一整套原生 diff 视图类，没有任何 diff 相关 JS；Sourcetree 的 diff 是原生表格视图类（STDiffTableView 等），包内连高亮库都没有；Sublime Merge 干脆用 C++ 自绘（作者自述，见下）。Lazygit、Magit 则直接省掉语法高亮，只给行级红绿。
3. **【已验证】重量派之所以重，不是因为 diff，而是整个壳。** 下载包：GitKraken 218MB（解包 691MB）、GitHub Desktop 513MB、GitFiend 96MB——三者都是 Electron。diff 编辑器只是这个壳里顺带的一个模块。
4. **【已验证，但只是「包体」层面】原生 ≠ 自动小。** Tower 解包 192MB、Sourcetree 172MB，比 GitButler（111MB，Tauri）还大——重在自带 git / git-lfs / 一堆业务框架。真正又小又全的是 Fork：下载 31MB、解包 107MB，Swift + AppKit，功能覆盖并排、语法高亮、图片对比。对照 NeatGit 已安装 17MB（其中 Monaco 资源 12MB），Fork 说明「全原生 + 完整 diff」可以落在 30MB 下载量级。
5. **【未验证假设】Monaco 带来的那部分能力，主流客户端里没有一个是靠「编辑器控件」获得的。** 行内词级高亮、并排/统一、跳转上/下一处，在 GitKraken、GitHub Desktop、GitButler、Tower、Fork、Lazygit、Magit 中各自用的是 diff 算法库、自绘行或原生控件。依据见第四节逐项证据；「Monaco 的 diff 编辑器是否在 GitKraken 的 diff 页面被实际调用」我只能确认代码在包里，没能运行时确认。

## 二、证据来源说明（按主控要求）

| 代号 | 含义 |
|---|---|
| A | 一手页面直取：官网 / 官方文档 / 官方 GitHub 仓库源码与依赖清单（curl、git 浅克隆、GitHub API 只读） |
| B | 本人实测：从官方下载地址取安装包，`Content-Length` 量下载体积；在临时目录解包后用 `otool -L`、`strings` 做静态检查，**未启动任何应用**，临时文件已删除 |
| C | 检索服务返回的片段（本轮配额两度用尽，只有 1 次检索成功，见第五节） |

未做：内存占用、启动速度——**未查到公开数据**（检索配额用尽，且本人按约束未启动第三方应用）。

## 三、对比表

### 3.1 技术栈与 diff 渲染方式

| 客户端 | 技术栈 | diff 视图怎么画 | 语法高亮靠什么 | 证据 |
|---|---|---|---|---|
| Fork (2.70.2) | Swift + AppKit（二进制链接 Swift 运行时；主程序含 NSLayoutManager、WKWebView；界面为 .nib） | 原生文本视图：`TextDiffView` / `SplitTextDiffView` / `SideBySideTextDiffView` / `BinaryDiffView` 等类；Resources 里无 diff 相关 JS（JS 仅 Chart.js、moment.js 用于统计页） | 包内有「disableSyntaxHighlighting」开关；引擎未识别（未命中 Highlightr / Splash / tree-sitter / highlight.js） | B；作者主页自述两人技术栈为 Swift/Cocoa 与 .NET/WPF（A，https://fork.dev/about ）——Windows 版为 WPF 属**推断** |
| Tower (18.5) | Objective-C + Swift 混编，原生 AppKit（主程序含 NSLayoutManager，无 WKWebView） | 原生：`GTFileDiffViewController`、`FNGitDiffChunk`、`GitInlineDiff`、`LargeDiffWarningCellView` | 随包带 highlight.js v11.8.0（`Highlighter_Highlighter.bundle`，约 1MB）+ 语言映射表；运行在哪个 JS 引擎上**未核对** | B |
| Sourcetree for Mac (4.2.21) | Objective-C + Swift 混编，原生（链接 WebKit，含 WKWebView） | 原生：`STDiffView` / `STDiffTableView` / `STDiffHunkViewController`；Resources 无 diff 相关 JS/HTML | 包内未发现任何高亮库（无 hljs / monaco / codemirror） | B；Windows 版技术栈**未查到** |
| Sublime Merge (build 2136) | C++ 自研跨平台 UI 库 + OpenGL；链接 CoreText / OpenGL，无 WebView、无 Electron、无 NSLayoutManager | 自绘 | 复用 Sublime Text 语法引擎 | B + 官网 https://www.sublimemerge.com/ （A）；作者原话（HN，C→A 二次取回）https://news.ycombinator.com/item?id=23324083 ：「自定义 UI 库，自己做控件、事件、渲染；原生 UI 只用于菜单、文件选择框、标题栏；用系统字体排版 API 保证文字观感一致」 |
| GitKraken (12.7.0) | Electron 41.10.7（Chromium 146），asar 357MB | 网页渲染；官方文档称内置 diff 查看器 | 包内打包了 monaco-editor 代码（含 diff editor 相关符号） | B + 官方帮助 https://help.gitkraken.com/gitkraken-desktop/diff （A） |
| GitHub Desktop (3.7.0) | Electron 44 + React + TypeScript（README 自述） | **自绘 diff 行**（`side-by-side-diff.tsx`、`diff-explorer.ts`，虚拟滚动），不是编辑器控件 | 仅借 CodeMirror 的 mode 分词器，在 Web Worker 中算 token（`lib/highlighter/worker.ts`），单文件超 1MB 不再高亮 | A：https://github.com/desktop/desktop （`package.json`、`app/src/lib/highlighter/`、`app/src/ui/diff/`）；https://github.com/desktop/desktop/issues/329 中维护者写道「Monaco 最有希望但也最重，自带 inline 和 side-by-side」 |
| GitButler (0.23.5) | Tauri 2.11.4 + wry 0.55（系统 WKWebView）+ Rust 后端 + SvelteKit | 自绘：`UnifiedDiffView.svelte`、`MultiDiffView.svelte`、`HunkDiff*.svelte`；词级用 diff-match-patch | shiki（只分词的高亮库） | A：https://github.com/gitbutlerapp/gitbutler ；B。仓库 master 另有一个**实验性** GPUI 原生客户端（`crates/but-gpui`，README 自称 "experimental native client on GPUI"），说明其自身也在往更轻的壳走——是否已随正式版发布**未验证** |
| Lazygit (v0.66.3) | Go + tcell v3 终端 UI（go.mod） | 终端纯文本着色；并排视图只能靠外部渲染器（如 delta） | 源码中无语法高亮（无 chroma 等依赖） | A：https://github.com/jesseduffield/lazygit （`go.mod`、`docs/Config.md`、`docs/Custom_DiffRenderers.md`、`docs/keybindings/Keybindings_en.md` ） |
| Magit (手册 4.7.2) | Emacs Lisp，运行在 Emacs 内 | Emacs buffer（`magit-diff-mode`）；词级细化是可开关的 refinement | 无专门语法高亮 | A：https://github.com/magit/magit （`docs/magit.org`） |
| GitFiend (0.45.3) | Electron 39 + Rust 核心 + 自研 TypeScript UI 库（非 Flutter） | **未查到**（客户端源码未公开，shell 仓库称 client 代码仅含压缩产物） | 未查到 | A：https://github.com/GitFiend/gitfiend-shell 、https://github.com/GitFiend/gitfiend-core |

### 3.2 体积（下载包为 B 实测；解包体积为 B 实测）

| 客户端 | 下载包 | 解包后 | 备注 |
|---|---|---|---|
| Fork | 31.4 MB | 107 MB | 官方地址 https://cdn.fork.dev/mac/Fork-2.70.2.dmg |
| Sublime Merge | 40.0 MB | 124 MB | https://download.sublimetext.com/sublime_merge_build_2136_mac.zip |
| GitButler | 46.8 MB | 111 MB | https://releases.gitbutler.com/releases/release/0.23.5-3373/macos/aarch64/GitButler.app.tar.gz |
| Sourcetree | 68.6 MB | 172 MB | https://product-downloads.atlassian.com/software/sourcetree/ga/Sourcetree_4.2.21_326.zip |
| Tower | 86.2 MB | 192 MB | https://www.git-tower.com/apps/tower3-mac/568-1befb557/Tower-18.5-568.zip |
| GitFiend | 95.5 MB | 未测 | https://github.com/GitFiend/Support/releases/download/v0.45.3/GitFiend-0.45.3-arm64.dmg |
| GitKraken | 217.9 MB | 691 MB | https://api.gitkraken.dev/releases/production/darwin/arm64/12.7.0/GitKraken-v12.7.0.zip |
| GitHub Desktop | 513.3 MB（arm64 zip） | 未测 | GitHub release 3.7.0 资产，https://github.com/desktop/desktop/releases |
| Lazygit | 6.6 MB | — | release v0.66.3 darwin_arm64 压缩包，https://github.com/jesseduffield/lazygit/releases |
| Magit | 未测 | — | 随 Emacs，不以独立安装包分发 |
| **NeatGit（对照）** | — | 17 MB | 主控提供的数据 |

内存占用、启动速度：全部**未查到公开数据**。

### 3.3 许可与商业模式（仅背景）

Fork：$59.99，可免费评估（https://fork.dev/ ）。Sublime Merge：商业收费，价格未核对。Tower、GitKraken：商业软件，价格未核对。Sourcetree：未核对。GitHub Desktop：MIT（GitHub API）。Lazygit：MIT。Magit：GPL-3.0。GitButler：FSL-1.1-MIT（两年后转 MIT，README 自述）。GitFiend：shell 与 UI 库 MIT / Apache-2.0，核心闭源。

### 3.4 刚需清单逐项对照

图例：✔ 有证据支持 · ✘ 有证据表明没有 · ？未核对

| 能力 | Fork | Tower | Sourcetree | Sublime Merge | GitKraken | GitHub Desktop | GitButler | Lazygit | Magit |
|---|---|---|---|---|---|---|---|---|---|
| 行号 | ？ | ？ | ？ | ？ | ？ | ✔（`lineNumbers`） | ？ | ✘（源码未见行号渲染） | ？ |
| 行内（词级）高亮 | ？ | ✔（`GitInlineDiff`） | ？ | ✔（官网 "Character Diffs"） | ✔（官方文档 "Word diffing"） | ✔（`changed-range`） | ✔（diff-match-patch） | ✘（未发现） | ✔（refinement，默认可开关） |
| 并排 / 统一切换 | ✔（Split/SideBySide 类） | ？ | ？ | ✔（官网 "Side by Side Diffs"；统一视图未核对） | ✔（Hunk / Inline / Split） | ✔（side-by-side 源码） | ？（仅确认统一视图组件） | ✘（需外部渲染器） | ✘ |
| 语法高亮 | ✔（有开关） | ✔（highlight.js） | ✘（包内未发现） | ✔ | ✔ | ✔（1MB 上限） | ✔（shiki） | ✘ | ✘ |
| 大文件处理 | ？ | ✔（大 diff 警告单元） | ？ | ？ | ？ | ✔（超限提示 + 1MB 停高亮） | ？ | ？ | ？ |
| 选择复制 | ？（文本视图，推断可） | ？ | ？ | ？ | ？ | ？ | ？ | ✔（`diff_copy.go`） | ？（Emacs 缓冲区，推断可） |
| 上一个 / 下一处变更 | ？ | ？ | ？ | ？ | ✔（官方文档 "Arrows to navigate"） | ？ | ？ | ✔（j/k 上下 hunk） | ✔（手册 n/p） |

读法：**没有哪一项是 9 家全部具备的**；「并排 + 词级 + 语法高亮 + 跳转」四项齐全、且有公开证据的只有 GitKraken 一家（最重的那个）。语法高亮是唯一接近「共识」的一项（6/9 有、3/9 明确没有）；行号与跳转在多数客户端**查不到公开说明**，不能当成既定刚需。Lazygit、Magit 两个最轻的对象不约而同砍掉语法高亮与并排，说明这两项是最容易被「轻量派」放弃的。

## 四、业界轻量派怎么做 diff、重量派为什么重

**轻量派（Fork / Tower / Sourcetree / Sublime Merge）**：diff 是「只读的着色文本」。行内容由 diff 算法算好，排版交给系统文本栈（或自绘引擎），语法高亮拆成一个只输出 token 的库（highlight.js、Sublime 语法引擎），再由原生控件上色。整条链路里没有可编辑控件、没有 DOM、没有一整套语言的 worker。代价是要自己写并排/统一两套布局和滚动同步（Fork、Tower 都各有一组原生类）。终端派（Lazygit、Magit）更极端：直接放弃语法高亮和并排。

**网页壳派（GitKraken / GitHub Desktop / GitButler / GitFiend）**：重的根因是壳——Electron 自带一整个 Chromium（GitHub Desktop 513MB、GitKraken 解包 691MB）。但在这个壳里，GitHub Desktop 与 GitButler 仍然**没有**用编辑器控件做 diff：前者只借分词器、自己画行，后者用 shiki 分词 + 自绘。只有 GitKraken 把 Monaco 打进了包。换言之，即使在网页技术栈内部，「用编辑器做只读 diff」也不是主流选择。

**对 NeatGit 的含义（仅陈述事实，不替决策）**：NeatGit 当前是「原生壳 + 一个只读 diff 用 WebView 承载 Monaco 全量包」。上表没有一个同类产品是这个组合；最接近的参照是 Tower / Fork——原生壳、原生 diff、一个轻量分词器做高亮。

## 五、未验证清单

1. GitKraken 的 diff 页面是否真的调用 Monaco 的 diff 编辑器（仅确认 monaco 代码在 asar 内，未做运行时确认）。
2. Fork 语法高亮引擎、WKWebView 在 Fork / Sourcetree 中的具体用途（静态检查无法定位到功能）。
3. Tower 的 highlight.js 运行在哪个 JS 引擎上。
4. GitButler 的 GPUI 原生客户端是否已进入正式发行版。
5. GitFiend 的 diff 渲染方式；Sourcetree Windows 版、Fork Windows 版技术栈。
6. 所有对象的内存占用与启动速度（未查到公开数据）。
7. 3.4 表中所有「？」格。
8. 检索服务本轮两次 429（小时配额被并行任务用尽），仅 1 次检索成功（结果 C：Sublime Merge 的 HN 讨论、GitKraken 帮助页、desktop/desktop#329）；其余全部为一手页面直取或本人实测。未使用任何其他搜索工具。
