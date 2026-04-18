#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAMLFLOW_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
PI_MONO_REPO="${PI_MONO_REPO:-$HOME/projects/pi-mono}"
PI_TEST_SCRIPT="$PI_MONO_REPO/pi-test.sh"
REQUIRED_BUILDS=(
  "$PI_MONO_REPO/packages/ai/dist/index.js"
  "$PI_MONO_REPO/packages/agent/dist/index.js"
  "$PI_MONO_REPO/packages/tui/dist/index.js"
)

if [[ ! -d "$PI_MONO_REPO" ]]; then
  echo "pi-mono repo not found: $PI_MONO_REPO" >&2
  exit 1
fi

if [[ ! -x "$PI_TEST_SCRIPT" ]]; then
  echo "pi-test.sh not found or not executable: $PI_TEST_SCRIPT" >&2
  echo "Clone pi-mono to ~/projects/pi-mono or set PI_MONO_REPO=/path/to/pi-mono" >&2
  exit 1
fi

for required in "${REQUIRED_BUILDS[@]}"; do
  if [[ ! -f "$required" ]]; then
    echo "Missing pi-mono build artifact: $required" >&2
    echo "Build pi-mono first (for example from $PI_MONO_REPO run npm run build)." >&2
    exit 1
  fi
done

export CAMLFLOW_REPO
cd "$CAMLFLOW_REPO"
exec "$PI_TEST_SCRIPT" "$@"
