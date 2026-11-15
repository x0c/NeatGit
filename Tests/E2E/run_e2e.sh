#!/bin/bash
# Deterministic E2E regression: no model, no network, window-scoped pixels only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOLKIT="${MACOS_E2E_TOOLKIT:-$HOME/.macos-e2e-toolkit}"
cd "$ROOT"
if [[ "${E2E_UPDATE_BASELINES:-0}" == "1" ]]; then
  echo "updating baselines in Tests/E2E/baselines"
fi
exec "$TOOLKIT/.venv/bin/python" -m pytest Tests/E2E -p no:cacheprovider "$@"
