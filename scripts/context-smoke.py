#!/usr/bin/env python3
"""Exercise the packaged stdio helper with fictional, isolated profile history."""
import argparse
import json
import os
from pathlib import Path
import select
import sqlite3
import subprocess
import tempfile
import time


def fixture(root):
    profiles = [
        {"id": "default", "name": "Studio", "color": "377CF6"},
        {"id": "research", "name": "Research", "color": "009B87"},
        {"id": "private", "name": "Personal", "color": "955CE5"},
    ]
    support = root / "Library/Application Support/Account Dock"
    support.mkdir(parents=True)
    (support / "preferences.json").write_text(json.dumps({"profiles": profiles, "scale": 1}))
    policy = support / "Context/access.json"
    policy.parent.mkdir(mode=0o700)
    policy.write_text(json.dumps({"version": 1, "grants": {"default": ["research"]}}))
    for profile in profiles:
        directory = root / (".codex" if profile["id"] == "default" else ".codex-" + profile["id"])
        directory.mkdir()
    directory = root / ".codex-research"
    with sqlite3.connect(directory / "state_5.sqlite") as db:
        db.execute("CREATE TABLE threads (id TEXT, name TEXT, title TEXT, updated_at INTEGER, archived INTEGER, source TEXT, agent_path TEXT, thread_source TEXT, rollout_path TEXT, history_mode TEXT)")
        db.execute("INSERT INTO threads VALUES (?,?,?,?,?,?,?,?,?,?)", ("sample-session", "Workshop planning", "", int(time.time()), 0, "vscode", "/root", "user", "", "paginated"))
    with sqlite3.connect(directory / "thread_history_1.sqlite") as db:
        db.execute("CREATE TABLE thread_items (thread_id TEXT, item_id TEXT, item_json TEXT, created_at_ms INTEGER, rollout_ordinal INTEGER, item_type TEXT)")
        for index, (role, text) in enumerate([
            ("userMessage", "Let us prepare the autumn workshop. The participants should bring a real example."),
            ("agentMessage", "We could start with a short demonstration and then work on participants' own examples."),
            ("userMessage", "Agreed. Keep the workshop practical: a fifteen-minute demonstration, then hands-on exercises. No fixed timings for individual exercises."),
            ("agentMessage", "The workshop outline is a draft. The practical exercises still need a review before we share it."),
        ], 1):
            item = {"type": role, "id": f"sample-{index}", "phase": "final_answer"}
            item["content" if role == "userMessage" else "text"] = [{"type": "text", "text": text}] if role == "userMessage" else text
            db.execute("INSERT INTO thread_items VALUES (?,?,?,?,?,?)", ("sample-session", f"sample-{index}", json.dumps(item), int(time.time() * 1000), index, role))
    return policy


def smoke(binary, root, policy):
    process = subprocess.Popen([str(binary), "mcp", "--profile", "default", "--home", str(root)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        def rpc(method, params=None, request_id=1):
            process.stdin.write((json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}}) + "\n").encode())
            process.stdin.flush()
            if not select.select([process.stdout], [], [], 5)[0]:
                raise AssertionError(f"No live stdio response for {method}; stdin is intentionally still open")
            value = json.loads(process.stdout.readline())
            assert value.get("id") == request_id, value
            assert "error" not in value, value
            return value["result"]

        assert rpc("initialize", {"protocolVersion": "2025-06-18", "clientInfo": {"name": "fixture", "version": "1"}, "capabilities": {}})["serverInfo"]["name"] == "profiledock-context"
        tools = rpc("tools/list")["tools"]
        assert len(tools) == 3 and all(t["annotations"]["readOnlyHint"] for t in tools)
        profiles = rpc("tools/call", {"name": "list_profiles"})["structuredContent"]["profiles"]
        assert [p["id"] for p in profiles] == ["research"]
        result = rpc("tools/call", {"name": "search_sessions", "arguments": {"query": "workshop practical", "profiles": ["@research"], "limit": 1}})
        assert result["isError"] is False, result
        hit = result["structuredContent"]["hits"][0]
        assert hit["message"]["id"] == "sample-3"
        page = rpc("tools/call", {"name": "read_session", "arguments": {"profile": "research", "session_id": hit["thread"]["id"], "message_id": hit["message"]["id"]}})
        assert len(page["structuredContent"]["messages"]) == 4
        assert rpc("tools/call", {"name": "search_sessions", "arguments": {"query": "workshop", "profiles": ["private"]}})["isError"]
        policy.write_text(json.dumps({"version": 1, "grants": {}}))
        assert rpc("tools/call", {"name": "read_session", "arguments": {"profile": "research", "session_id": "sample-session"}})["isError"]
        policy.write_text(json.dumps({"version": 1, "grants": {"default": ["research"]}}))
        print("PASS: live MCP initialization, discovery, aliases, ranked search, focused reading, denied source, immediate revocation")
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=3)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("--keep-fixture", action="store_true")
    args = parser.parse_args()
    if args.keep_fixture:
        root = Path(tempfile.mkdtemp(prefix="profiledock-context-preview-")).resolve()
        smoke(args.binary.resolve(), root, fixture(root))
        print("PREVIEW_HOME=" + str(root))
    else:
        with tempfile.TemporaryDirectory(prefix="profiledock-context-smoke-") as folder:
            root = Path(folder).resolve()
            smoke(args.binary.resolve(), root, fixture(root))
