# Operations 指南

> 覆盖范围：本地构建步骤、Monaco 前端构建、运行时验证路径、常见阻碍排查。

---

## 一、环境前提

| 项目 | 要求 |
|------|------|
| macOS | 15.0+ |
| Xcode | 建议 16+（当前验证通过：`/Applications/Xcode.app`） |
| Swift | 6.0 |
| XcodeGen | 需安装（`brew install xcodegen`） |
| Node.js | 仅修改 Monaco 前端时需要 |

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
xcodebuild -scheme NeatGit -configuration Debug -destination 'platform=macOS'
```

---

## 三、Monaco 前端构建

修改 `Web/MonacoDiff/src/` 下任意文件后需要重新构建：

```bash
cd Web/MonacoDiff
npm install       # 首次或 package.json 变更后
npm run build
# 构建产物目录：Web/MonacoDiff/dist/
# 需要将 dist/ 内容同步到 NeatGitApp/Resources/MonacoDiff/
```

构建完后务必把 `dist/` 内容复制到 `NeatGitApp/Resources/MonacoDiff/`，否则 App 内的 Monaco Diff 预览会使用旧版静态资源。

---

## 四、运行时验证路径

### 4.1 仓库扫描

启动 App 后左侧栏自动扫描 Home 目录（约 1-3 秒），出现仓库列表说明扫描链路正常。

### 4.2 文件状态读取

选中左栏任意仓库 → 中间面板出现文件列表（changed / skipped / ignored 分组）说明 `GitRepositoryStatusLoader` 正常工作。

### 4.3 Diff 预览

点击中间面板任意 changed 文件 → 右侧 Monaco Diff 预览出现（侧边模式或 inline 模式取决于窗口宽度）。
若预览空白，检查：
- `BundleStaticFileServer` 是否启动（查看 App 启动日志）。
- `NeatGitApp/Resources/MonacoDiff/` 是否有构建产物。

### 4.4 AI commit message 生成

1. 打开 `NeatGit → Preferences → LLM 配置`，填写兼容 OpenAI 接口的 baseURL / model / apiKey。
2. 在中间面板勾选文件 → 点击底部提交栏 AI 按钮 → commit message 框应自动填入。
3. 如生成失败，打开 `Window → AI 调试`（或通过 `AICommitDebugWindowView`）查看 prompt 和 error 详情。

---

## 五、常见阻碍

| 现象 | 排查方向 |
|------|---------|
| `xcodebuild` 编译报 sendability 错误 | 可能是 Swift 6.2 工具链变化引入的，先确认是否工具链升级导致 |
| Monaco Diff 空白 | 检查 `BundleStaticFileServer` 端口是否冲突；检查 dist/ 资源是否存在 |
| 仓库扫描超时 / 卡死 | 检查 Home 目录下是否存在超深嵌套或超大 node_modules（扫描深度上限 6，但部分目录未被排除规则覆盖） |
| AI 生成请求失败 | 在 AI 调试窗口查看 errorMessage；检查 apiKey 是否正确写入 Keychain |
| xcodegen generate 报文件找不到 | 确认 `project.yml` 中 sources 路径与实际文件路径一致 |
