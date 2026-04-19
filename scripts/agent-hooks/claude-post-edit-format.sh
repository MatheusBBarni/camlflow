#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
import json
import os
import pathlib
import shutil
import subprocess
import sys

data = json.load(sys.stdin)
project = os.environ.get("CLAUDE_PROJECT_DIR") or data.get("cwd") or os.getcwd()
tool_input = data.get("tool_input") or {}
path = tool_input.get("file_path") or ""
if not path:
    raise SystemExit(0)

name = pathlib.Path(path).name
suffix = pathlib.Path(path).suffix
should_format = suffix in {".ml", ".mli"} or name in {"dune", "dune-project"} or path.endswith(".opam")
if not should_format:
    raise SystemExit(0)

cmd = "opam exec -- dune fmt" if shutil.which("opam") else "dune fmt"
result = subprocess.run(
    ["bash", "-lc", cmd],
    cwd=project,
    capture_output=True,
    text=True,
)
if result.returncode != 0:
    payload = {
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": (
                "Auto-format hook failed while running "
                + cmd
                + ". Run it manually before finishing source changes."
            ),
        }
    }
    print(json.dumps(payload))
PY
