"""NeatGit E2E harness wiring.

The scan root is a throwaway /tmp fixture, never the owner's home, and the repo
list is opened through the app's `--repository-root` launch option so no
NSOpenPanel is involved. This file must prepare the fixture before the toolkit
resolves `e2e_config`, because launch arguments come from there.
"""

import os
import pathlib
import sys

TOOLKIT = pathlib.Path.home() / ".macos-e2e-toolkit"
sys.path.insert(0, str(TOOLKIT / "harness"))

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import fixture_repo  # noqa: E402

pytest_plugins = ["macos_e2e_harness.pytest_support"]

FIXTURE_ROOT = fixture_repo.build_fixture()
ALPHA = fixture_repo.ALPHA

_extra = os.environ.get("E2E_EXTRA_ARGS", "").strip()
os.environ["E2E_EXTRA_ARGS"] = f"{_extra} --repository-root {FIXTURE_ROOT}".strip()
