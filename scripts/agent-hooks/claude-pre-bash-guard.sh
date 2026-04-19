#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
import json
import os
import re
import shlex
import shutil
import subprocess
import sys

data = json.load(sys.stdin)
project = os.environ.get("CLAUDE_PROJECT_DIR") or data.get("cwd") or os.getcwd()
tool_input = data.get("tool_input") or {}
command = tool_input.get("command") or ""
if not command:
    raise SystemExit(0)

if "NV_CONTEXT_PRECOMMIT_GUARD=1" in command:
    raise SystemExit(0)

try:
    branch = subprocess.run(
        ["git", "branch", "--show-current"],
        cwd=project,
        capture_output=True,
        text=True,
        check=False,
    ).stdout.strip()
except Exception:
    branch = ""

push_match = re.search(r"\bgit\s+push\b", command)
mentions_protected = re.search(r"(^|[\s:])(main|master)([\s:]|$)", command)
if push_match and (mentions_protected or branch in {"main", "master"}):
    payload = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": (
                "Direct pushes to main or master are blocked. Push a feature branch and open a pull request."
            ),
        }
    }
    print(json.dumps(payload))
    raise SystemExit(0)

if not re.search(r"\bgit\s+commit\b", command):
    raise SystemExit(0)

format_cmd = "opam exec -- dune fmt" if shutil.which("opam") else "dune fmt"
test_cmd = "opam exec -- dune test" if shutil.which("opam") else "dune test"
sdk_test_cmd = "opam exec -- npm test" if shutil.which("opam") else "npm test"

gated_command = " && ".join(
    [
        "export NV_CONTEXT_PRECOMMIT_GUARD=1",
        "cd " + shlex.quote(project),
        format_cmd,
        test_cmd,
        (
            "if [ -d packages/camlflow-ts-json-rpc-sdk/node_modules ]; then "
            "(cd packages/camlflow-ts-json-rpc-sdk && "
            + sdk_test_cmd
            + "); else "
            "echo '[nv-context] skipping packages/camlflow-ts-json-rpc-sdk npm test; run npm install there to enable the full gate.' >&2; "
            "fi"
        ),
        (
            "if [ -d packages/camlflow-vscode/node_modules ]; then "
            "(cd packages/camlflow-vscode && npm run smoke:highlight); else "
            "echo '[nv-context] skipping packages/camlflow-vscode smoke test; run npm install there to enable the optional gate.' >&2; "
            "fi"
        ),
        command,
    ]
)

updated_input = dict(tool_input)
updated_input["command"] = gated_command
payload = {
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "allow",
        "permissionDecisionReason": "Running format and test gates before git commit.",
        "updatedInput": updated_input,
        "additionalContext": "The git commit command was rewritten to run repo checks before committing.",
    }
}
print(json.dumps(payload))
PY
