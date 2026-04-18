#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW="${CAMLFLOW_WORKFLOW:-examples/recursion/main.cml}"
ENTRY="${CAMLFLOW_ENTRY:-main}"
INPUT_JSON="${CAMLFLOW_INPUT_JSON:-4}"

INITIAL_MESSAGE="/camlflow-run $WORKFLOW --entry $ENTRY --input-json $INPUT_JSON"

echo "Launching pi-mono with initial message:"
echo "  $INITIAL_MESSAGE"

exec "$SCRIPT_DIR/run-pi-mono.sh" "$@" "$INITIAL_MESSAGE"
