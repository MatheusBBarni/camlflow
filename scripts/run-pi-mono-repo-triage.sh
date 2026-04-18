#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW="${CAMLFLOW_WORKFLOW:-examples/repo-triage/main.cml}"
ENTRY="${CAMLFLOW_ENTRY:-main}"
if [[ -n "${CAMLFLOW_INPUT_JSON:-}" ]]; then
  INPUT_JSON="$CAMLFLOW_INPUT_JSON"
else
  INPUT_JSON='{"task":"Triage how the pi-mono host integration is wired in this repo and identify the best files to inspect for improving no-model UX, effect streaming, and helper script ergonomics.","suspected_area":"pi-mono host integration docs, scripts, and TypeScript SDK wiring","file_hints":["docs/pi-mono-host-integration-plan.md","docs/pi-mono-implementation-checklist.md","docs/pi-mono-integration-testing.md","packages/camlflow-ts-json-rpc-sdk/src/client.ts","scripts"],"goals":["map the main integration path","identify the highest-value files for a follow-up patch","propose a small validation plan"],"constraints":["ground conclusions in repository evidence","prefer concrete file paths over generic advice","assume the caller wants to test through pi-mono"],"mode":{"tag":"DeepDive"}}'
fi
SKILLS_DIR="${CAMLFLOW_SKILLS_DIR:-examples/repo-triage/skills}"

INITIAL_MESSAGE="/camlflow-run $WORKFLOW --entry $ENTRY --input-json $INPUT_JSON"
if [[ -n "$SKILLS_DIR" ]]; then
  INITIAL_MESSAGE+=" --skills-dir $SKILLS_DIR"
fi

echo "Launching pi-mono with initial message:"
echo "  $INITIAL_MESSAGE"

exec "$SCRIPT_DIR/run-pi-mono.sh" "$@" "$INITIAL_MESSAGE"
