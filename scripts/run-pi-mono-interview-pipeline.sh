#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/pi-mono-message-lib.sh"

WORKFLOW="${CAMLFLOW_WORKFLOW:-examples/interview-pipeline/main.cml}"
ENTRY="${CAMLFLOW_ENTRY:-main}"
if [[ -n "${CAMLFLOW_INPUT_JSON:-}" ]]; then
  INPUT_JSON="$CAMLFLOW_INPUT_JSON"
else
  INPUT_JSON='{"algorithm_name":"longest increasing subsequence","preferred_language":{"tag":"Python"},"target_difficulty":{"tag":"Hard"},"focus":[{"tag":"Pattern","value":"dynamic programming"},{"tag":"Constraint","value":"n up to 10^5"}]}'
fi
SKILLS_DIR="${CAMLFLOW_SKILLS_DIR:-examples/interview-pipeline/skills}"

INITIAL_MESSAGE="$(build_camlflow_run_message "$WORKFLOW" "$ENTRY" "$INPUT_JSON" "$SKILLS_DIR")"

echo "Launching pi-mono with initial message:"
echo "  $INITIAL_MESSAGE"

exec "$SCRIPT_DIR/run-pi-mono.sh" "$@" "$INITIAL_MESSAGE"
