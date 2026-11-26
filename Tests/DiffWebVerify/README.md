# 差异网页视图的独立验收脚本

用途：对 `NeatGitApp/Resources/DiffWeb/` 的构建产物做黑盒验收，覆盖并排与单栏切换、行号与增删改着色、行内高亮、只读与等宽字体、深浅色与高对比、定位到第一处差异、无障碍标签、大文本、差异精度、只看变更折叠、语法高亮、查找、幂等与加载约束，共 31 项。

网页页面改动后必须重跑，避免功能退化。

## 前提

- 已安装 Node 与 Playwright 的浏览器驱动（脚本从环境变量 `PW_CORE` 读取驱动目录，本机是全局 `@playwright/cli` 附带的 `playwright-core`）。
- 已构建网页产物：`cd Web/DiffWeb && npm run build`。

## 用法

```sh
PW_CORE="$(npm root -g)/@playwright/cli/node_modules/playwright-core" \
  node Tests/DiffWebVerify/verify.cjs NeatGitApp/Resources/DiffWeb /tmp/diffweb-verify-out
```

脚本会起一个仅绑定本机回环的临时静态服务，用无头浏览器加载产物并逐项打印「通过 / 未通过 | 编号 | 读数」，截图写入第二个参数指定的目录，同时写入 `results.json`。完成标准是「合计 31 项，未通过 0 项」。脚本有总时限，结束时自动退出。

## 维护约定

- 页面结构或选择器约定变化时，同步更新脚本里的选择器。
- 验收样本与期望值的对应关系写死在脚本里（例如折叠各段应隐藏的行数）；改样本时必须同时重算期望值，不要把实现方当前的输出直接当成期望值。
