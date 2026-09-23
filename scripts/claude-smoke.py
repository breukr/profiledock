#!/usr/bin/env python3
"""Exercise the packaged Claude helper using an isolated home and fictional input."""
import concurrent.futures
import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import sys
import tempfile
import time

helper = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="profiledock-claude-smoke-") as temporary:
    home = Path(temporary).resolve()
    state = home / "Library/Application Support/Account Dock/ClaudeSessions/fixture.json"

    def run(mode, payload):
        result = subprocess.run(
            [str(helper), mode, "--home", str(home)], input=json.dumps(payload),
            capture_output=True, text=True, timeout=10, check=True,
        )
        assert not result.stderr, result.stderr
        return result.stdout

    base = {"session_id": "fixture", "cwd": "/fictional/project"}
    assert run("hook", dict(base, hook_event_name="UserPromptSubmit", prompt="PRIVATE FIXTURE")) == ""
    value = json.loads(state.read_text())
    assert value["state"] == "working"
    assert "PRIVATE FIXTURE" not in state.read_text()
    assert stat.S_IMODE(state.stat().st_mode) == 0o600
    assert run("hook", dict(base, hook_event_name="PermissionRequest")) == ""
    assert json.loads(state.read_text())["state"] == "waiting"
    limits = {"five_hour": {"used_percentage": 37, "resets_at": time.time() + 3600}}
    assert "37% used" in run("statusline", dict(base, rate_limits=limits))
    assert json.loads(state.read_text())["state"] == "waiting"
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(lambda _: run("hook", dict(base, hook_event_name="PostToolUse")), range(12)))
    assert json.loads(state.read_text())["state"] == "working"
    assert run("hook", dict(base, hook_event_name="Stop")) == ""
    assert json.loads(state.read_text())["state"] == "idle"
    assert json.loads(state.read_text())["completedAt"]
    unchanged = state.read_bytes()
    run("hook", dict(base, hook_event_name="UserPromptSubmit", agent_id="subagent-fixture"))
    assert state.read_bytes() == unchanged
    run("hook", {"session_id": "../escape", "cwd": "/fictional/project"})
    assert len(list(state.parent.glob("*.json"))) == 1

    original = home / "original-status.py"
    original.write_text("import json,sys\nassert json.load(sys.stdin)['session_id'] == 'fixture'\nprint('custom status preserved')\n")
    config = home / "Library/Application Support/Account Dock/ClaudeBridge/original-statusline.json"
    config.parent.mkdir(parents=True)
    config.write_text(json.dumps({"type": "command", "command": shlex.quote(sys.executable) + " " + shlex.quote(str(original))}))
    assert run("statusline", dict(base, rate_limits=limits)).strip() == "custom status preserved"
    assert json.loads(state.read_text())["limits"][0]["used"] == 37

print("PASS: packaged Claude hooks, private metadata, usage, concurrent writes, subagent exclusion, traversal rejection and custom status-line pass-through")
