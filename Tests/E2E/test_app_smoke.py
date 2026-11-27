"""NeatGit E2E: repository scan, file sections, diff pane, pixel baselines.

Every case runs against a throwaway git repository under /tmp created by
conftest.py. The app is launched with `open -g` (never activated), a window is
presented through the AppKit `--e2e-testing` path, and all interaction goes
through AX or window-local driver calls.
"""

from __future__ import annotations

import time

import pytest

from conftest import ALPHA

ALPHA_ROW = f"repository-{ALPHA}"
BEHIND = "/tmp/neatgit-e2e/behind"
BEHIND_ROW = f"repository-{BEHIND}"

README_LABEL = "README.md"
UNTRACKED_LABEL = "untracked.txt"
BINARY_LABEL = "blob.bin"
CHANGED_COUNT = 3  # README.md (modified), untracked.txt (new), blob.bin (binary)


def _select_repository(driver, identifier: str = ALPHA_ROW) -> None:
    driver.press(identifier=identifier, role=None)
    driver.ax().find(identifier="file-section-changed", timeout=12)


def _press_file(driver, label: str) -> None:
    """按行文本选中文件。

    List 行不暴露 accessibilityIdentifier（section 的 identifier 盖掉了行上的
    `file-<item.id>`，且行没有 AXPress），只能：按 AXValue 找到元素
    → 按 role+frame 从 driver 快照里取 element_token → 后台点击。
    """

    hit = driver.ax().find(value_contains=label, role="AXStaticText", timeout=8)
    snapshot = driver.snapshot()
    token = None
    for element in snapshot.get("elements", []):
        frame = element.get("frame") or {}
        if element.get("role") != hit.role:
            continue
        if all(abs(float(frame.get(key, -999)) - value) <= 2.0 for key, value in zip(("x", "y", "w", "h"), hit.frame)):
            token = element["element_token"]
            break
    if token is None:
        raise AssertionError(f"no driver token for file row {label!r}")
    driver.call("click", element_token=token)
    time.sleep(1.2)


def test_launch_is_background_and_guard_holds(app, driver):
    """背景启动：窗口可截、App 没有被激活、输入设备没有被碰。"""

    window = app.window
    assert window.title == "NeatGit", f"unexpected window title {window.title!r}"
    assert window.width >= 960 and window.height >= 600
    scale_x, scale_y = driver.app_scale()
    assert 1.0 <= scale_x <= 4.0, f"unexpected backing scale {scale_x}"
    assert abs(scale_x - scale_y) < 0.01

    driver.snapshot()  # 至少一次真实调用，之后才有 guard 证据
    evidence = driver.guard_evidence
    assert evidence, "no guard evidence recorded"
    for call in evidence:
        # 每次 AX/driver 调用前后都记录光标与前台进程；光标位移由报告如实记录，不在这里判。
        assert "cursor_drift" in call, call
        assert call.get("mode") in {"auto", "all", "frontmost", "off"}, call
        before, after = call.get("before") or {}, call.get("after") or {}
        assert before.get("frontmost_pid") == after.get("frontmost_pid"), f"frontmost changed during {call.get('tool')}"
        assert after.get("frontmost_pid") != app.pid, f"app became frontmost after {call.get('tool')}"

    launch = app._result
    assert launch is not None
    assert launch.focus_after.frontmost_pid != app.pid, "app became frontmost"
    assert launch.focus_after.frontmost_pid == launch.focus_before.frontmost_pid, "frontmost app changed during launch"


def test_fixture_repositories_listed_without_open_panel(app, driver):
    """--repository-root 直接给扫描根目录，不弹 NSOpenPanel。"""

    ax = driver.ax()
    alpha_hit = ax.find(identifier=ALPHA_ROW, timeout=10)
    assert alpha_hit.role == "AXStaticText", alpha_hit.role
    ax.find(identifier=BEHIND_ROW, timeout=5)

    roles = [hit.role for hit in ax.walk()]
    assert "AXSheet" not in roles, "a modal sheet/panel is open"
    assert roles.count("AXWindow") == 1, f"unexpected extra windows: {roles.count('AXWindow')}"
    assert "AXDialog" not in roles
    # 没有系统面板进程参与：面板会是独立 AXWindow，且本窗口不会拿到仓库列表。


def test_repository_selection_renders_file_sections(app, driver):
    """选中仓库后，文件按 changed / skipped / ignored 三段渲染。"""

    _select_repository(driver)

    changed = driver.ax().find(identifier="file-section-changed", timeout=10)
    assert str(CHANGED_COUNT) in (changed.label or ""), changed.label
    skipped = driver.ax().find(identifier="file-section-skipped", timeout=5)
    assert "0" in (skipped.label or ""), skipped.label
    driver.ax().find(identifier="file-section-ignored", timeout=5)

    text = driver.text()
    assert any("README.md" in item for item in text), "README.md missing from file list"
    assert any("untracked.txt" in item for item in text), "untracked.txt missing from file list"
    assert not any(f"{CHANGED_COUNT} 个更改" in item for item in text), "duplicate status summary"


def test_commit_composer_tracks_selection(app, driver):
    """提交区按当前仓库的变更数给出自动暂存说明，入口控件齐全。"""

    _select_repository(driver)

    editor = driver.ax().find(identifier="commit-message-editor", timeout=5)
    assert editor.role == "AXTextArea", editor.role
    driver.ax().find(identifier="generate-commit-message", timeout=5)
    driver.ax().find(identifier="commit-menu", timeout=5)
    driver.ax().find(identifier="commit-status-message", timeout=5)

    status = driver.value("commit-status-message") or ""
    assert f"将提交 {CHANGED_COUNT} 个文件" in status, status


def test_single_file_diff_changes_pixels(app, driver, vision):
    """单文件 diff：空态 → 选中 README.md 后预览区像素确实改变。"""

    _select_repository(driver)
    empty_shot = vision.capture("preview-empty")
    assert empty_shot.image.width > 0

    _press_file(driver, README_LABEL)
    diff_shot = vision.capture("preview-diff")

    text = driver.text()
    assert not any("从左侧选择单个更改文件后" in item for item in text), "diff pane still shows the empty state"
    assert any("README.md" in item for item in text)

    diff_pixels = _changed_pixel_ratio(empty_shot.image, diff_shot.image)
    assert diff_pixels > 0.01, f"preview pixels barely changed: {diff_pixels:.4f}"


def test_changed_files_summary_keeps_only_focused_file_expanded(app, driver):
    """右侧汇总全部变动文件，但只展开当前关注的一个文件。"""

    _select_repository(driver)
    # 前一条用例可能保留文件选择；先切到空仓库再切回，验证真正的全折叠初态。
    _select_repository(driver, BEHIND_ROW)
    _select_repository(driver)
    driver.ax().find(identifier="changed-file-diff-list", timeout=8)

    for label in (README_LABEL, UNTRACKED_LABEL, BINARY_LABEL):
        identifier = f"diff-file-changed:{label}"
        driver.ax().find(identifier=identifier, timeout=5)
        driver.assert_value(identifier, equals="已折叠", timeout=5)

    _press_file(driver, README_LABEL)
    driver.assert_value(f"diff-file-changed:{README_LABEL}", equals="已展开", timeout=8)
    driver.assert_value(f"diff-file-changed:{UNTRACKED_LABEL}", equals="已折叠", timeout=5)
    driver.assert_value(f"diff-file-changed:{BINARY_LABEL}", equals="已折叠", timeout=5)

    driver.press(identifier=f"diff-file-changed:{UNTRACKED_LABEL}")
    driver.assert_value(f"diff-file-changed:{UNTRACKED_LABEL}", equals="已展开", timeout=8)
    driver.assert_value(f"diff-file-changed:{README_LABEL}", equals="已折叠", timeout=5)
    driver.assert_value(f"diff-file-changed:{BINARY_LABEL}", equals="已折叠", timeout=5)


def test_second_repository_switch_updates_context(app, driver):
    """切到另一个临时仓库：标题、变更数量、文件列表都跟着换。"""

    _select_repository(driver)
    _select_repository(driver, BEHIND_ROW)

    time.sleep(1.0)
    text = driver.text()
    assert any("behind" in item for item in text)
    assert any("没有文件更改" in item for item in text), f"expected empty change list: {text[:10]}"
    assert not any("README.md" in item for item in text), "previous repository files leaked into the new context"

    _select_repository(driver)


def test_binary_file_shows_documented_boundary(app, driver):
    """回归（docs 2.3）：二进制文件不渲染 diff，显示既有的中文拒绝说明。"""

    _select_repository(driver)
    _press_file(driver, BINARY_LABEL)

    deadline = time.time() + 12
    body = ""
    while time.time() < deadline:
        body = " ".join(driver.text())
        if "二进制" in body:
            break
        time.sleep(0.4)
    assert "二进制" in body, f"binary placeholder missing: {body[-400:]}"


def test_window_visual_matches_baseline(app, driver, vision):
    """窗口级像素基线：第二次运行必须 match。"""

    _select_repository(driver)
    _press_file(driver, README_LABEL)
    shot = vision.capture("main-window")
    result = vision.assert_visual("main-window", shot=shot, max_diff_ratio=0.0)
    assert result.passed, f"visual regression: {result.paths}"


def _changed_pixel_ratio(first, second) -> float:
    """两张同尺寸窗口截图里，变化的像素占比。"""

    from PIL import Image, ImageChops

    assert first.size == second.size, f"size mismatch {first.size} vs {second.size}"
    diff = ImageChops.difference(first.convert("RGB"), second.convert("RGB"))
    bbox = diff.getbbox()
    if bbox is None:
        return 0.0
    changed = sum(1 for pixel in diff.convert("L").tobytes() if pixel > 8)
    return changed / float(first.size[0] * first.size[1])


@pytest.mark.skip(reason="branch list UI does not exist in NeatGit; covered by git fixture, not AX")
def test_branch_list_renders(app, driver):
    pass
