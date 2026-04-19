#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
import json
import os
import pathlib
import subprocess
import sys
import time

data = json.load(sys.stdin)
project = pathlib.Path(os.environ.get("CLAUDE_PROJECT_DIR") or data.get("cwd") or os.getcwd())
source = data.get("source", "")

def git_dir_for(project_path: pathlib.Path) -> pathlib.Path:
    result = subprocess.run(
        ["git", "-C", str(project_path), "rev-parse", "--git-dir"],
        capture_output=True,
        text=True,
        check=False,
    )
    value = result.stdout.strip() or ".git"
    git_dir = pathlib.Path(value)
    if not git_dir.is_absolute():
        git_dir = project_path / git_dir
    return git_dir

parts = []
now = time.time()
for rel in ("AGENTS.md", "CLAUDE.md"):
    path = project / rel
    if path.exists():
        age_days = int((now - path.stat().st_mtime) // 86400)
        if age_days > 14:
            parts.append(f"Agent configs may be stale — {rel} is {age_days} days old. Review or run /nv-context to refresh.")

if source == "compact":
    snapshot = git_dir_for(project) / "nv-context" / "postcompact-context.txt"
    if snapshot.exists():
        text = snapshot.read_text(encoding="utf-8").strip()
    else:
        text = ""
    if text:
        parts.append("Compaction refresh:\n" + text[:6000])

if parts:
    payload = {
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": "\n\n".join(parts),
        }
    }
    print(json.dumps(payload))
PY
