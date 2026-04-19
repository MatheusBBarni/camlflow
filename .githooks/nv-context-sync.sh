#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

warn() {
  printf '%s\n' "[nv-context] $*" >&2
}

age_days() {
  local path="$1"
  if [ ! -f "$path" ]; then
    return 1
  fi
  local now
  local mtime
  now="$(date +%s)"
  mtime="$(stat -c %Y "$path" 2>/dev/null || stat -f %m "$path")"
  printf '%s\n' "$(( (now - mtime) / 86400 ))"
}

staged="$(git diff --cached --name-only --diff-filter=ACMRTUXB || true)"
if [ -n "$staged" ] && printf '%s\n' "$staged" | grep -Eq '(^|/)(package\.json|camlflow\.opam|dune-project|Makefile|\.ocamlformat|AGENTS\.md|CLAUDE\.md|hooks-config\.json)$|^\.github/workflows/|^lib/(cli|project_config|rpc_protocol|rpc_server)\.ml$'; then
  warn "Staged changes touch build, package, workflow, or public-contract files. Review AGENTS.md and CLAUDE.md or rerun /nv-context."
fi

for cfg in AGENTS.md CLAUDE.md; do
  if days="$(age_days "$cfg")"; then
    if [ "$days" -gt 14 ]; then
      warn "$cfg is $days days old. Agent configs may be stale."
    fi
  fi
done

if rg -n "\b(do not|don't|avoid)\b" AGENTS.md CLAUDE.md lib/CLAUDE.md test/CLAUDE.md docs/CLAUDE.md packages/CLAUDE.md hooks-config.json >/dev/null 2>&1; then
  warn "Soft negative instructions found in agent config files. Rewrite them as positive MUST/SHOULD guidance."
fi

exit 0
