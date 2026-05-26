#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/pi-mono-message-lib.sh"

WORKFLOW="${CAMLFLOW_WORKFLOW:-examples/basic/main.cml}"
ENTRY="${CAMLFLOW_ENTRY:-main}"
INPUT_JSON="${CAMLFLOW_INPUT_JSON:-\"Ada\"}"

INITIAL_MESSAGE="$(build_camlflow_run_message "$WORKFLOW" "$ENTRY" "$INPUT_JSON")"

echo "Launching pi-mono with initial message:"
echo "  $INITIAL_MESSAGE"

exec "$SCRIPT_DIR/run-pi-mono.sh" "$@" "$INITIAL_MESSAGE"
