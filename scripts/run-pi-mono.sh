#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAMLFLOW_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
PI_MONO_REPO="${PI_MONO_REPO:-$HOME/projects/pi-mono}"
PI_TEST_SCRIPT="$PI_MONO_REPO/pi-test.sh"
CAMLFLOW_OPAM_SWITCH="${CAMLFLOW_OPAM_SWITCH:-}"
REQUIRED_OCAML_VERSION="5.4.0"
REQUIRED_BUILDS=(
  "$PI_MONO_REPO/packages/ai/dist/index.js"
  "$PI_MONO_REPO/packages/agent/dist/index.js"
  "$PI_MONO_REPO/packages/tui/dist/index.js"
)
PI_TEST_EXEC_PREFIX=()

version_ge() {
  local actual="$1"
  local required="$2"

  [[ -n "$actual" ]] || return 1
  [[ "$(printf '%s\n' "$required" "$actual" | sort -V | head -n1)" == "$required" ]]
}

current_ocaml_version() {
  if command -v ocamlc >/dev/null 2>&1; then
    ocamlc -version 2>/dev/null || true
  fi
}

resolve_pi_test_exec_prefix() {
  local current_version="$1"
  local switch_name="$CAMLFLOW_OPAM_SWITCH"
  local switch_version=""

  if version_ge "$current_version" "$REQUIRED_OCAML_VERSION"; then
    return 0
  fi

  if ! command -v opam >/dev/null 2>&1; then
    echo "CamlFlow requires OCaml $REQUIRED_OCAML_VERSION+, but ocamlc reports ${current_version:-unknown}." >&2
    echo "Install or select a compatible opam switch before launching pi-mono." >&2
    exit 1
  fi

  if [[ -z "$switch_name" ]] && opam switch list --short 2>/dev/null | grep -Fxq "$REQUIRED_OCAML_VERSION"; then
    switch_name="$REQUIRED_OCAML_VERSION"
  fi

  if [[ -z "$switch_name" ]]; then
    echo "CamlFlow requires OCaml $REQUIRED_OCAML_VERSION+, but ocamlc reports ${current_version:-unknown}." >&2
    echo "Run the launcher through a compatible switch (for example: opam exec --switch $REQUIRED_OCAML_VERSION -- ./scripts/run-pi-mono-basic.sh)." >&2
    echo "Or set CAMLFLOW_OPAM_SWITCH to a compatible switch name." >&2
    exit 1
  fi

  switch_version="$(opam exec --switch "$switch_name" -- ocamlc -version 2>/dev/null || true)"
  if ! version_ge "$switch_version" "$REQUIRED_OCAML_VERSION"; then
    echo "CAMLFLOW_OPAM_SWITCH '$switch_name' provides OCaml ${switch_version:-unknown}, but CamlFlow requires $REQUIRED_OCAML_VERSION+." >&2
    exit 1
  fi

  echo "Using opam switch $switch_name for CamlFlow (shell ocamlc: ${current_version:-unknown})." >&2
  PI_TEST_EXEC_PREFIX=(opam exec --switch "$switch_name" --)
}

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

resolve_pi_test_exec_prefix "$(current_ocaml_version)"

export CAMLFLOW_REPO
cd "$CAMLFLOW_REPO"
if [[ ${#PI_TEST_EXEC_PREFIX[@]} -eq 0 ]]; then
  exec "$PI_TEST_SCRIPT" "$@"
fi

exec "${PI_TEST_EXEC_PREFIX[@]}" "$PI_TEST_SCRIPT" "$@"
