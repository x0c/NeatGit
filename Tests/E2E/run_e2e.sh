#!/bin/bash
# Deterministic E2E regression: no model, no network, window-scoped pixels only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOLKIT="${MACOS_E2E_TOOLKIT:-$HOME/.macos-e2e-toolkit}"
cd "$ROOT"
if [[ "${E2E_UPDATE_BASELINES:-0}" == "1" ]]; then
  echo "updating baselines in Tests/E2E/baselines"
fi
if [[ -x "$TOOLKIT/.venv/bin/python" ]]; then
  exec "$TOOLKIT/.venv/bin/python" -m pytest Tests/E2E -p no:cacheprovider "$@"
elif command -v macos-e2e >/dev/null 2>&1; then
  # 标准 uv tool 安装没有仓库内 .venv，交给已安装的 harness 入口。
  exec macos-e2e run . "$@"
else
  echo "找不到 macOS E2E 运行环境，请先安装 macos-e2e。" >&2
  exit 1
fi
