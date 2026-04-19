#!/usr/bin/env bash
set -euo pipefail

project="${CLAUDE_PROJECT_DIR:-$(pwd)}"
git_dir="$(git -C "$project" rev-parse --git-dir 2>/dev/null || printf '.git')"
if [ "${git_dir#/}" = "$git_dir" ]; then
  git_dir="$project/$git_dir"
fi
state_dir="$git_dir/nv-context"
mkdir -p "$state_dir"

python3 - "$project" "$state_dir/postcompact-context.txt" <<'PY'
import pathlib
import sys

project = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
parts = []

claude = project / "CLAUDE.md"
if claude.exists():
    head = claude.read_text(encoding="utf-8").splitlines()[:30]
    if head:
        parts.append("CLAUDE.md head:\n" + "\n".join(head))

agents = project / "AGENTS.md"
if agents.exists():
    capture = []
    inside = False
    for line in agents.read_text(encoding="utf-8").splitlines():
        if line.startswith("## Landmines"):
            inside = True
            continue
        if inside and line.startswith("## "):
            break
        if inside:
            capture.append(line)
    text = "\n".join(capture).strip()
    if text:
        parts.append("AGENTS landmines:\n" + text)

out.write_text("\n\n".join(parts).strip() + "\n", encoding="utf-8")
PY
