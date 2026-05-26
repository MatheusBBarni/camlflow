#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/pi-mono-message-lib.sh"

WORKFLOW="${CAMLFLOW_WORKFLOW:-examples/orchestrator-session/main.cml}"
ENTRY="${CAMLFLOW_ENTRY:-main}"
if [[ -n "${CAMLFLOW_INPUT_JSON:-}" ]]; then
  INPUT_JSON="$CAMLFLOW_INPUT_JSON"
else
  INPUT_JSON='{"issue_number":16,"task":"Triage the sandbox orchestrator workflow.","goals":["ground the plan in the .cml contract"]}'
fi
SKILLS_DIR="${CAMLFLOW_SKILLS_DIR:-}"

INITIAL_MESSAGE="$(build_camlflow_run_message "$WORKFLOW" "$ENTRY" "$INPUT_JSON" "$SKILLS_DIR")"

echo "Launching pi-mono with initial message:"
echo "  $INITIAL_MESSAGE"

exec "$SCRIPT_DIR/run-pi-mono.sh" "$@" "$INITIAL_MESSAGE"
