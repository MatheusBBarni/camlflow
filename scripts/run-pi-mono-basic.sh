#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW="${CAMLFLOW_WORKFLOW:-examples/basic/main.cml}"
ENTRY="${CAMLFLOW_ENTRY:-main}"
INPUT_JSON="${CAMLFLOW_INPUT_JSON:-\"Ada\"}"
SKILLS_DIR="${CAMLFLOW_SKILLS_DIR:-}"

INITIAL_MESSAGE="/camlflow-run $WORKFLOW --entry $ENTRY --input-json $INPUT_JSON"
if [[ -n "$SKILLS_DIR" ]]; then
  INITIAL_MESSAGE+=" --skills-dir $SKILLS_DIR"
fi

echo "Launching pi-mono with initial message:"
echo "  $INITIAL_MESSAGE"

exec "$SCRIPT_DIR/run-pi-mono.sh" "$@" "$INITIAL_MESSAGE"
