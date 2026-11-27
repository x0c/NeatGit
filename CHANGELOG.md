# Changelog

All notable changes to this project will be documented in this file.

The format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## 0.1.2 - 2026-11-27

### Changed

- Diff preview is now fully native, rendered by the system text view with no embedded web engine. Switch between side-by-side and single-column, with line numbers, added/removed backgrounds and inline highlights; "Changes only" collapses long unchanged stretches and expands on click.
- Larger text files can be previewed: the diff size limit rises from about 750 KB to 5 MB.
- Switching repositories and files feels quicker: hovering a repository preloads its status, stale results never appear, and only the changed rows are re-laid-out when toggling "Changes only".
- Updates now follow the standard Sparkle prompts: a new version found in the background is announced, and you choose when to download and install it instead of it happening automatically.

### Fixed

- Unresolved merge conflicts are no longer committed as if they were ordinary additions; all seven unmerged states are detected and reported.
- Committing a file whose name contains wildcard characters no longer sweeps in other files.

### Known trade-off

- The native diff preview does not provide syntax highlighting for now.

### 简体中文

- 差异预览改为完全原生：由系统文本视图直接渲染，不再内嵌网页或浏览器内核。可在“并排 / 单栏”之间切换，带行号、增删底色和行内高亮；开启“只看变更”会折叠长段未变更内容，点击可展开。
- 可预览的文本文件更大：差异大小上限由约 750 KB 提高到 5 MB。
- 切换仓库与文件更跟手：悬停仓库即预读状态，过期结果不会上屏，切换“只看变更”只重排版、不重算差异。
- 更新改用 Sparkle 标准提示：后台发现新版本先提醒，由你决定何时下载安装，不再自动下载和安装。
- 未解决的合并冲突不再被当作普通新增提交：七种未合并状态全部识别并提示。
- 文件名含通配字符时，提交不再波及其他文件。
- 取舍：原生差异预览暂不提供语法高亮。

## 0.1.1 - 2026-10-22

### Changed

- Compact, content-sized native Settings: aligned connection fields, system-prompt editing, update switches and app actions fit on one page without scrolling.
- Edit long generation instructions in a native sheet with Cancel, Done and Restore Default; cancelling preserves the saved prompt.

### 简体中文

- 设置改为紧凑、按内容定高的原生分组表单：连接配置、生成说明入口、更新开关和应用操作在一页完整显示，无需滚动。
- 长篇生成说明在原生弹窗中编辑，提供取消、完成和恢复默认；取消不会修改已保存内容。

## 0.1.0 - 2026-10-21

### Added

- Sparkle 2 in-app updates: automatic checks, background download and install, with EdDSA-signed feed and verification before extraction.
- First signed public route: Developer ID-signed, Apple-notarized DMG for first install and Sparkle-signed ZIP for updates, published to GitHub Releases.

### 简体中文

- 应用内 Sparkle 2 更新：自动检查、后台下载安装，更新清单带 EdDSA 签名，解包前验签。
- 首个签名公开发布链路：Developer ID 签名、苹果公证的 DMG（首装）与 Sparkle 签名 ZIP（更新），随 GitHub Releases 发布。
