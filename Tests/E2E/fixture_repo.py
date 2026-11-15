"""Throwaway fixture repositories for the NeatGit E2E suite.

Everything lives under /tmp and is created from scratch on every run, so a case
never touches the owner's repositories and never needs a git remote.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

ROOT = Path("/tmp/neatgit-e2e")
ALPHA = ROOT / "alpha"
BEHIND = ROOT / "behind"


def _git(repo: Path, *args: str) -> None:
    subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        capture_output=True,
        text=True,
    )


def _init(repo: Path) -> None:
    repo.mkdir(parents=True, exist_ok=True)
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.email", "e2e@localhost")
    _git(repo, "config", "user.name", "E2E")


def build_fixture() -> Path:
    """Recreate the fixture tree and return the scanned root."""

    if ROOT.exists():
        shutil.rmtree(ROOT)
    ROOT.mkdir(parents=True)

    _init(ALPHA)
    (ALPHA / "README.md").write_text("line one\nline two\nline three\n", encoding="utf-8")
    (ALPHA / "keep.txt").write_text("tracked\n", encoding="utf-8")
    _git(ALPHA, "add", "-A")
    _git(ALPHA, "commit", "-q", "-m", "init alpha")
    _git(ALPHA, "tag", "v0")
    _git(ALPHA, "checkout", "-q", "-b", "feature/e2e")

    # Working tree state the suite asserts on: one modified tracked file, one
    # untracked file, one tracked file turned binary (documented binary gate).
    (ALPHA / "README.md").write_text("line one\nline two CHANGED\nline three\nline four\n", encoding="utf-8")
    (ALPHA / "untracked.txt").write_text("brand new\n", encoding="utf-8")
    (ALPHA / "blob.bin").write_text("plain text payload\n", encoding="utf-8")
    _git(ALPHA, "add", "blob.bin")
    _git(ALPHA, "commit", "-q", "-m", "add blob as text")
    (ALPHA / "blob.bin").write_bytes(b"\x00\x01binary payload\n")

    _init(BEHIND)
    (BEHIND / "b.txt").write_text("b\n", encoding="utf-8")
    _git(BEHIND, "add", "-A")
    _git(BEHIND, "commit", "-q", "-m", "init behind")

    return ROOT
