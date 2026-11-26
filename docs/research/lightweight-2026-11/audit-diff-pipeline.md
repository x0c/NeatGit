# audit-diff-pipeline：diff 链路文件级审计

> 状态标签：**已验证** = 有 文件:行号 证据或一手页面；**未验证假设** = 检索配额用尽或需实测，未能核对。行号基于当前工作区。

## 0. 结论

1. diff 链路里「仅因 WebView 而存在」的部分：Swift 594 行（`MonacoDiffView.swift` 327 + `BundleStaticFileServer.swift` 267）、测试 251 行、模型 22 行，加 12.8MB 前端产物、约 400 行前端源、Node 构建链、一个常驻回环监听端口和一个 WebContent 辅助进程。**已验证**（§6）。
2. 渲染无关、三条路都原样保留的骨架：读取 + 缓存约 580 行（Loader 153 + Store 361 + Models 44 + DiffLineStat 54）。**已验证**。
3. 最重的运行时开销不是 git 读取，而是每次显示都要「主线程 JSON 编码 → 跨进程传整份文本 → 网页侧重新解析、重算 diff」。24 条缓存只省掉 git 读取，省不掉这条链路。**已验证**（代码路径）。
4. 应用启动即加载整套 Monaco，与用户是否查看 diff 无关。**已验证**（§8 R1）。
5. 编译器崩溃踩坑的触发因子从未被隔离，换方案后不能自动解除。**未验证假设**（§7）。

## 1. 外部依据

| 来源 | 取得方式 | 用到的结论 |
|---|---|---|
| [WebPage.callJavaScript(_:arguments:in:contentWorld:)](https://developer.apple.com/documentation/webkit/webpage/calljavascript(_:arguments:in:contentworld:)) | Apple 官方文档 JSON 直取（一手） | 参数以具名参数传入，支持 `String`，无需手工转义 |
| [com.apple.security.network.server](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.server) | Apple 官方文档 JSON 直取（一手） | 沙盒应用监听入站连接需该 entitlement |
| [WebPage.Configuration.websiteDataStore](https://developer.apple.com/documentation/webkit/webpage/configuration/websitedatastore) | Apple 官方文档 JSON 直取（一手） | `nonPersistent()` 即私有浏览会话 |
| 本机 SDK 27.2 接口与头文件（WebKit / Network） | 本机文件 | `callJavaScript` 为 `@MainActor`、`load(_:)` 返回异步序列、`Configuration.urlSchemeHandlers` 存在、`nw_listener_create` 分配随机端口、WebView 的 web content 进程来自进程池 |

`tavily_search` / `tavily_extract` 本次全部返回 429，**搜索成功 0 次**。以下均未核对，标为未验证假设（检索配额用尽）：Monaco 是否必须 http 源才能加载模块脚本与 Web Worker；自定义 scheme 能否承载 Worker；非持久数据存储之间是否共享内存缓存；Monaco diff 计算是否在 Worker 线程；监听器进入 `.waiting` 的触发条件。

## 2. 端到端数据流

```
点击文件 → 选中签名变化 → Store.select（主线程）
   ├ 命中缓存 → 直接 applyDocument
   └ 未命中 → 后台线程 → git cat-file --batch（0 或 1 个子进程）→ 回主线程
→ payloadForDisplay → WebView 视图 onChange → 控制器
→ 主线程 JSON 编码整份文本 → 跨进程调用 → 网页 JSON.parse → Monaco 建模、算 diff → 绘制
```

| 阶段 | 执行上下文 | 证据 |
|---|---|---|
| 1 选中变化触发 | 主线程；签名是每次求值都拼接的字符串 | `RepositoryPreviewPane.swift:14-21,117-120` |
| 2 `Store.select` 判占位/缓存/加载 | 主线程 | `RepositoryDiffStore.swift:39-103` |
| 3 读取切到后台 | `Task.detached`，一次上下文切换 | `GitRepositoryDiffLoader.swift:11-15` |
| 4 git 子进程 | **0 或 1 个**：两侧都是空/工作区文件时 0 个（如未跟踪文件）；有 Git 对象时合并成一次 `cat-file --batch` | `GitRepositoryDiffLoader.swift:69-98`；`GitCommandSupport.swift:93-103` |
| 5 回到主线程应用 | 一次切换 | `RepositoryDiffStore.swift:209-215` |
| 6 网页首次加载（每个窗口一次） | 主线程 → 资源加载器 actor → 又一次后台任务 → 监听器队列 → 回主线程 | `MonacoDiffView.swift:151-191,286-309` |
| 7 每次显示内容 | 主线程编码 → WebContent 进程执行脚本 | `MonacoDiffView.swift:239-242` |

未命中路径上，单侧文本的整份拷贝/编码次数（**已验证**到第 6 步，之后为未验证假设）：

| # | 拷贝 | 位置 |
|---|---|---|
| 1 | 读管道整段输出 | `GitCommandSupport.swift:53` |
| 2 | 按对象切片 | `GitCommandSupport.swift:129` |
| 3 | 解码成字符串并常驻缓存 | `GitRepositoryDiffLoader.swift:146-151` |
| 4 | 主线程 JSON 编码 | `MonacoDiffView.swift:239` |
| 5 | JSON 再转字符串 | `MonacoDiffView.swift:240` |
| 6 | 跨进程序列化 | `MonacoDiffView.swift:243` |
| 7-9 | 网页侧解析、建模、渲染 | `main.js:264-290` |

第 3 步之后缓存命中与未命中走同一条路：第 4 到 9 步每次显示都重做。只看变更开关例外，走独立小调用（`MonacoDiffView.swift:246-253`，测试 `MonacoWebViewTests.swift:121-131` 断言不重传）。第 4、5 步并非必需：官方文档称参数支持 `String`，可直接传文本。

## 3. 本地静态服务

| 项 | 现状 | 证据 | 标签 |
|---|---|---|---|
| 存在理由 | 页面用模块脚本，Monaco 依赖 Web Worker，推测 `file://` 源无法承载；代码未写明原因 | `index.html:8-9`；`main.js:2-6` | 未验证假设 |
| 服务根目录 | 是整个应用资源目录，不是 Monaco 子目录（构建时 94 个文件被平铺进资源根） | `MonacoDiffView.swift:296-299`；已安装包资源目录 96 项全为 Monaco 文件 | 已验证 |
| 监听地址 | 仅 IPv4 回环 `127.0.0.1` | `BundleStaticFileServer.swift:25` | 已验证 |
| 端口 | 系统随机分配，无固定端口 | 同上 `port: .any`；SDK `listener.h`「random port」 | 已验证 |
| 生命周期 | 启动后不再关闭，随应用常驻 | `BundleStaticFileServer.swift:14-18,68-73` | 已验证 |
| 路径校验 | 去查询串、百分号解码、按路径分量比较、拒绝目录和不存在文件 | `BundleStaticFileServer.swift:84-110`；测试 `BundleStaticFileServerTests.swift:10-55` | 已验证 |
| 方法 | 仅 GET / HEAD，一连接一请求 | `BundleStaticFileServer.swift:180-185` | 已验证 |
| 多余暴露面 | 响应带 `Access-Control-Allow-Origin: *`，同源加载并不需要 | `BundleStaticFileServer.swift:224` | 已验证 |
| 沙盒 | 工程无 entitlements，未沙盒；若上架需补监听 entitlement | `project.yml` 全文无 entitlements；Apple 文档 | 已验证 |
| 挂死风险 | 只在 `.ready` / `.failed` 放行信号量，`.waiting` 不处理；等待发生在后台任务里且无超时 | `BundleStaticFileServer.swift:36-56`；`MonacoDiffView.swift:292-309` | 代码已验证，触发条件未验证 |

实际泄露风险低：可读内容只有公开的构建产物，本机其他进程本来就能读应用包。

## 4. 缓存策略

| 链路 | 行为 | 证据 |
|---|---|---|
| 文件切换 | 取消上一个加载任务；命中则同步应用，未命中后台加载 | `RepositoryDiffStore.swift:41-44,94-102` |
| 模式切换 | 优先沿用用户所选模式；新模式通常未缓存，走完整加载和整份重传 | `RepositoryDiffStore.swift:44-47,136-148` |
| 仓库切换 | 置空当前选择；仅当新仓库版本号变化才清该仓库缓存，旧仓库缓存保留到被 LRU 淘汰 | `RepositoryDiffStore.swift:57-66,321-339` |
| 刷新失效 | 版本号变化清该仓库缓存并取消在途加载 | `RepositoryDiffStore.swift:321-339` |
| 悬停预取 | 60ms 延迟，只填缓存 | `RepositoryDiffStore.swift:7,105-128` |
| 上限 | 24 条，按（仓库、文件、模式）计，每条含两侧全文 | `RepositoryDiffStore.swift:8,268-277` |
| 常驻内存 | 整份文本常驻，理论上限约 24 × 两侧 × 750KB ≈ 36MB，另加当前显示的一份；网页侧无缓存 | `RepositoryDiffModels.swift:37-44` |

在途加载按同一键合并，结果总会写入缓存（`RepositoryDiffStore.swift:279-319`）。

## 5. 大小、二进制、冲突

| 情况 | 处理 | 证据 |
|---|---|---|
| 超过 750KB | 两侧都**完整读入后**才比较字节数并拒绝 | `GitRepositoryDiffLoader.swift:35-37` |
| 二进制 | 同样在全量读入后，任一侧含 0 字节即拒绝；UTF-16 文本会被误判 | `GitRepositoryDiffLoader.swift:39-41,142-144`；知识库第 245 行 |
| 冲突 | 读内容之前就拒绝，理由是 Monaco 会把冲突标记当普通文本 | `GitRepositoryDiffLoader.swift:25-27`；知识库第 133 行 |
| 多文件 / 非变更分组 | 占位提示，不进读取 | `RepositoryDiffStore.swift:78-92` |

冲突的拒绝理由与 Monaco 直接相关，换方案后这条约束需要重新判断。

## 6. 文件处置表

| 文件 | 行数 | 处置 | 证据与说明 |
|---|---|---|---|
| `Views/Diff/MonacoDiffView.swift` | 327 | 删除 | 全部是 WebView 宿主、桥接、超时、资源加载器 |
| `Services/BundleStaticFileServer.swift` | 267 | 删除 | 唯一调用方是上一文件（`:299`） |
| `Domain/RepositoryDiffModels.swift` | 69 | 删 22 行，留 47 行 | 删 46-68（网页专用载荷）；留 1-45 |
| `Services/GitRepositoryDiffLoader.swift` | 218 | 留 153 行；65 行待定 | 1-153 原样保留；154-218 语言提示表视高亮方案取舍 |
| `Stores/RepositoryDiffStore.swift` | 364 | 改 3 行，留 361 行 | 仅 154-156 的返回类型要换 |
| `Domain/DiffLineStat.swift` | 54 | 原样保留 | 属于 AI 提交说明链路，与预览无关（`CommitDiffAnalyzer.swift:31`） |
| `Views/RepositoryStatus/RepositoryPreviewPane.swift` | 124 | 改 4 行，留 120 行 | 35-38 换成新视图，其余是头部、模式切换、占位、加载态 |
| `Resources/MonacoDiff/` | 94 文件 12,846,926 字节 | 删除 | 未入库的构建产物（`.gitignore`）；其中 Worker 脚本 8.39MB、主包 3.68MB |
| `Web/MonacoDiff/` 源码 | 约 400 行 + 锁文件 1136 行 | 删除 | 同时去掉 Node 工具链依赖 |
| `NeatGitTests/MonacoWebViewTests.swift` | 195 | 删除并重写 | 断言的都是网页内部状态 |
| `NeatGitTests/BundleStaticFileServerTests.swift` | 56 | 删除 | 随服务消失 |
| `NeatGitTests/RepositoryDiffStoreTests.swift` | 150 | 改 2 行，留 148 行 | 第 43、82 行引用网页载荷 |
| `NeatGitUITests/NativeWorkspaceTests.swift` | — | 改 1 行 | 第 34 行断言存在 WebView |
| `docs/NEATGIT_KNOWLEDGE_BASE.md` | 267 | 改约 12 处 | 第 37、49、68、79、85-86、133、141、144-156、210-220、244、247-249、257 行 |
| `docs/OPERATIONS_GUIDE.md`、`AGENTS.md`、`README.md` | — | 同步修订 | OPERATIONS 第 15、44-56、73-77、103、119 行；AGENTS 第 45、74、88、101、114-115、279 行；README 第 63、69、96-97、112-115、128 行 |

合计：可删 Swift 867 行（约占全部 7,233 行的 12%），需改约 10 行，可保留约 580 行核心代码加 120 行预览面板。

换原生必须自己补回、目前由 Monaco 免费提供的能力（`main.js` 行号为依据）：

| 能力 | Monaco 中的位置 | 自研估算行数 |
|---|---|---|
| 行级 diff 算法 | `main.js:154` | 200–400，另加测试，或引入依赖 |
| 双栏/单栏、行号、增删底色、同步滚动、只读选择 | `main.js:147-183,205-224` | 500–900 |
| 未变更区域折叠与展开 | `main.js:226-252` | 100–200 |
| 语法高亮 | `main.js:197-203` 及 60 余种语言文件 | 不做则 0；做基础词法则 300–600 |
| 浅色、深色、高对比主题 | `main.js:44-137` | 50–100 |

以上行数是估算，不是实测。

## 7. 编译器崩溃相关的防御性写法

| 写法 | 位置 | 性质 | 换方案后 |
|---|---|---|---|
| 用两条 `.task(id: 签名)` 驱动刷新，不用 `onChange` | `RepositoryPreviewPane.swift:14-31,117-124` | 编译器防御 | 约束是否仍在：未验证假设 |
| 两个只做转发的小 `Binding` | `RepositoryPreviewPane.swift:99-115` | 同上 | 同上 |
| 主窗口拆成骨架/生命周期/弹窗三层，弹窗抽成修改器 | `ContentView.swift:36-38,238-240` | 防的是类型检查超时，该视图不含 WebView | 与本决策无关，保持 |
| 页面重建隔离旧脚本、单消费者串行提交、超时 | `MonacoDiffView.swift:153,203,267-283` | 并发防御，与编译器无关 | 随 WebView 一起消失 |

判断依据：承载 WebView 的 `MonacoDiffView` 自身用了三个带双参闭包的 `onChange`（`:51-59`）且能编译，说明 `onChange` 不是充分条件；文档只记录「预览面板叠加复杂 onChange / Binding 会崩」（知识库第 249 行、AGENTS §3.1），没有最小复现，WebView 类型是否为必要因子无从确认。另外踩坑记录于 Xcode 26.3，本机现为 Xcode 27.2，旧结论本身需要重验。

建议：原生视图沿用现有的签名驱动写法（成本接近零），等新视图写完再单独验证能否简化。

## 8. 风险清单

| 编号 | 风险 | 证据 | 标签 |
|---|---|---|---|
| R1 | 应用一启动就建网页、拉起整套 Monaco，即使从不看 diff；每开一个新窗口重来一次 | `ContentView.swift:100-106`；`RepositoryPreviewPane.swift:34-38`；`MonacoDiffView.swift:60-62,119-123,151-154` | 已验证 |
| R2 | 监听启动若卡住，资源加载器的单飞任务永不结束，重试永远超时，直到重启应用 | `BundleStaticFileServer.swift:36-56`；`MonacoDiffView.swift:292-309` | 代码已验证，触发条件未验证 |
| R3 | 后台任务里用信号量阻塞等待 | 同上 | 已验证 |
| R4 | 主线程编码最大约 1.5MB JSON，大文件切换会卡主线程 | `MonacoDiffView.swift:239-240` | 已验证 |
| R5 | 超限和二进制文件都是读完整份才拒绝 | `GitRepositoryDiffLoader.swift:35-41` | 已验证 |
| R6 | 每次重试重建网页并重新加载约 3.9MB（主包 3.68MB + 样式 0.15MB + 字体） | `MonacoDiffView.swift:96-99,154` | 已验证 |
| R7 | 干净检出无法直接出包：资源未入库，需 Node、npm 安装、前端构建、再生成工程；本机当前也没有前端依赖目录 | `.gitignore`；`OPERATIONS_GUIDE.md:44-56`；`README.md:128` | 已验证 |
| R8 | 回环 HTTP 可读取整个资源目录，且带通配跨域头 | `MonacoDiffView.swift:296-299`；`BundleStaticFileServer.swift:224` | 已验证，低危 |
| R9 | 24 条缓存跨仓库常驻，切仓库不释放 | `RepositoryDiffStore.swift:268-277,321-339` | 已验证 |
| R10 | 回归测试依赖真实网页和窗口，锁屏时不可靠 | `OPERATIONS_GUIDE.md:105-108` | 文档陈述，未复核 |

## 9. 三条路的改动量

| 路径 | NeatGit 侧改动 | 体量结果 | 保留的 WebView 开销 | 把握 |
|---|---|---|---|---|
| (a) 原生渲染 | 删 867 行 Swift、251 行测试中的一半以上、约 400 行前端源、12.8MB 资源、Node 构建链；改约 10 行；**新增约 850–2200 行**（§6 下表） | 应用包 17MB → 约 5MB；无辅助网页进程、无监听端口 | 无 | 新增行数为估算；语法高亮是否降级需产品拍板 |
| (b) 保留 Web、大幅瘦身 | 路线 b1 继续 Monaco：改 `main.js:1-7` 按需引入，不打包 JSON/CSS/HTML/TS 四个 Worker（合计 8.39MB 的主体），Swift 侧约 0–20 行。路线 b2 换轻量网页库：重写 `Web/MonacoDiff/src`（约 400 行），Swift 侧保留三入口协议，改动约 0–50 行 | 资源降幅取决于裁剪方式，未实测 | 进程、端口、跨进程传文本仍在 | 协议三入口稳定（`main.js:254-304`），Swift 改动小 |
| (c) 不动技术栈，做架构优化 | 懒启动（约 15 行）；去掉 JSON 编解码、直接传文本（约 15 行）；处理 `.waiting` 与启动超时（约 10 行）；删通配跨域头（1 行）。合计约 40–60 行 | 资源不变 | 首次显示仍需加载约 3.9MB；进程与端口仍在 | 三项均有代码或文档依据 |

(c) 的一个进阶项：用进程内自定义 scheme 取代回环服务，可删 267 行加 56 行测试。`Configuration.urlSchemeHandlers` 在本机 SDK 中存在（已验证），但能否承载模块脚本和 Worker 未验证，需先做最小验证。

硬下限：(b)(c) 都离不开网页进程和至少 3.9MB 的首屏加载；只有 (a) 能去掉。
