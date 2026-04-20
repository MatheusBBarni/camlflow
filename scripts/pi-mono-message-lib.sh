#!/usr/bin/env bash
set -euo pipefail

pi_quote_arg() {
  local value="$1"

  if [[ "$value" =~ ^[A-Za-z0-9_./:-]+$ ]]; then
    printf '%s' "$value"
    return
  fi

  if [[ "$value" != *"'"* ]]; then
    printf "'%s'" "$value"
    return
  fi

  local escaped="$value"
  escaped="${escaped//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  printf '"%s"' "$escaped"
}

build_camlflow_run_message() {
  local workflow="$1"
  local entry="$2"
  local input_json="$3"
  local skills_dir="${4:-}"
  local message

  message="/camlflow-run $(pi_quote_arg "$workflow")"
  message+=" --entry $(pi_quote_arg "$entry")"
  message+=" --input-json $(pi_quote_arg "$input_json")"

  if [[ -n "$skills_dir" ]]; then
    message+=" --skills-dir $(pi_quote_arg "$skills_dir")"
  fi

  printf '%s' "$message"
}
