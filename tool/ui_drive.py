#!/usr/bin/env python3
"""Drive the Linux Cursor Chat window through AT-SPI + niri screenshots."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi

SHOTS = Path("/home/vox/dev/cursor-chat/tool/ui_shots")
CONV = Path.home() / "Documents" / "conversations.json"


def apps():
    desktop = Atspi.get_desktop(0)
    out = []
    for i in range(desktop.get_child_count()):
        child = desktop.get_child_at_index(i)
        if child is not None:
            out.append(child)
    return out


def find_app():
    for app in apps():
        name = (app.get_name() or "").lower()
        if any(
            s in name
            for s in ("cursor_chat", "cursor chat", "dev.vox.cursor_chat")
        ):
            return app
        try:
            if (app.get_toolkit_name() or "").lower() == "flutter":
                return app
        except Exception:
            pass
    return None


def walk(node, depth=0, acc=None, limit=500):
    if acc is None:
        acc = []
    if len(acc) >= limit or node is None:
        return acc
    try:
        name = node.get_name() or ""
        role = node.get_role_name() or ""
        acc.append((depth, role, name, node))
        for i in range(node.get_child_count()):
            walk(node.get_child_at_index(i), depth + 1, acc, limit)
    except Exception:
        pass
    return acc


def dump(node):
    rows = walk(node)
    for depth, role, name, n in rows:
        extra = ""
        try:
            if n.get_n_actions() > 0:
                acts = [
                    n.get_action_name(i) for i in range(n.get_n_actions())
                ]
                extra += f" actions={acts}"
        except Exception:
            pass
        try:
            if n.is_text() or n.is_editable_text():
                extra += f" text={n.get_text(0, 80)!r}"
        except Exception:
            pass
        label = (name or "").replace("\n", " ")[:80]
        print(f"{'  ' * depth}{role}: {label}{extra}")
    return rows


def click_named(rows, needle, role=None):
    needle_l = needle.lower()
    for _, r, name, node in rows:
        if role and r != role:
            continue
        if needle_l not in (name or "").lower():
            continue
        try:
            n = node.get_n_actions()
            for i in range(n):
                an = (node.get_action_name(i) or "").lower()
                if an in ("click", "press", "activate"):
                    node.do_action(i)
                    print(f"clicked {r}: {name} via {an}")
                    return True
            if n > 0:
                node.do_action(0)
                print(f"clicked {r}: {name} via action0")
                return True
        except Exception as e:
            print(f"click failed {name}: {e}")
    return False


def set_text(rows, text, needles=("问点什么", "composer")):
    for _, r, name, node in rows:
        blob = f"{r} {name}".lower()
        if r not in ("entry", "text", "password text", "text box"):
            if not any(n.lower() in blob for n in needles):
                continue
        try:
            if node.is_editable_text() or r in ("entry", "password text", "text box"):
                node.set_text_contents(text)
                print(f"set_text on {r}: {name!r}")
                return True
        except Exception as e:
            print(f"set_text failed {r} {name!r}: {e}")
    return False


def niri_windows():
    out = subprocess.check_output(["niri", "msg", "-j", "windows"], text=True)
    return json.loads(out)


def niri_chat_id():
    for w in niri_windows():
        title = (w.get("title") or "").lower()
        app = (w.get("app_id") or "").lower()
        if "cursor_chat" in title or "cursor_chat" in app or app == "dev.vox.cursor_chat":
            return w["id"]
    return None


def screenshot(name):
    SHOTS.mkdir(parents=True, exist_ok=True)
    path = SHOTS / name
    wid = niri_chat_id()
    if wid is None:
        print("screenshot skipped: no niri window")
        return None
    subprocess.check_call(
        [
            "niri",
            "msg",
            "action",
            "screenshot-window",
            "--id",
            str(wid),
            "--path",
            str(path.resolve()),
            "--write-to-disk",
            "true",
        ]
    )
    print("screenshot", path, "bytes", path.stat().st_size if path.exists() else 0)
    return path


def focus_chat():
    wid = niri_chat_id()
    if wid is None:
        return False
    subprocess.check_call(["niri", "msg", "action", "focus-window", "--id", str(wid)])
    return True


def wait_app(timeout=90):
    deadline = time.time() + timeout
    while time.time() < deadline:
        app = find_app()
        if app:
            return app
        wid = niri_chat_id()
        if wid is not None:
            print("niri window present, AT-SPI app not yet")
        time.sleep(1)
    return None


def conv_data():
    if not CONV.exists():
        return None
    try:
        return json.loads(CONV.read_text())
    except Exception:
        return None


def last_assistant():
    data = conv_data()
    if not data:
        return None
    items = data.get("items") or []
    if not items:
        return None
    active = data.get("activeId")
    conv = items[0]
    for c in items:
        if c.get("id") == active:
            conv = c
            break
    msgs = conv.get("messages") or []
    for m in reversed(msgs):
        if m.get("role") == "assistant" and not m.get("streaming"):
            return m
    return None


def scenario():
    print("seen apps:")
    for a in apps():
        print(" -", a.get_name(), a.get_toolkit_name() if hasattr(a, "get_toolkit_name") else "")
    print("niri windows:")
    for w in niri_windows():
        print(" -", w.get("id"), w.get("app_id"), w.get("title"))

    app = wait_app()
    if app is None:
        print("APP_NOT_FOUND")
        sys.exit(2)
    print("APP", app.get_name())
    focus_chat()
    time.sleep(0.5)
    rows = dump(app)
    screenshot("01-empty.png")

    q1 = "1+1等于几？只回一个数字。"
    if not set_text(rows, q1):
        print("TYPE_FAILED")
        sys.exit(3)
    rows = walk(app)
    if not click_named(rows, "发送") and not click_named(rows, "arrow"):
        print("SEND_FAILED")
        sys.exit(4)
    print("waiting for first reply")
    deadline = time.time() + 120
    reply = None
    while time.time() < deadline:
        reply = last_assistant()
        if reply and (reply.get("text") or "").strip():
            break
        time.sleep(2)
    print("reply1", json.dumps({
        "text": (reply or {}).get("text", "")[:200],
        "thinking_len": len((reply or {}).get("thinking") or ""),
        "title": ((conv_data() or {}).get("items") or [{}])[0].get("title"),
    }, ensure_ascii=False))
    screenshot("02-first-reply.png")
    rows = walk(app)
    dump(app)
    click_named(rows, "思考过程")
    time.sleep(0.4)
    screenshot("03-thinking.png")

    title1 = None
    data = conv_data() or {}
    for c in data.get("items") or []:
        title1 = c.get("title")
        break
    rows = walk(app)
    q2 = "再加1呢？只回数字。"
    if not set_text(rows, q2):
        print("TYPE2_FAILED")
        sys.exit(5)
    rows = walk(app)
    if not click_named(rows, "发送"):
        print("SEND2_FAILED")
        sys.exit(6)
    print("waiting for follow-up")
    prev = (reply or {}).get("text")
    deadline = time.time() + 120
    reply2 = None
    while time.time() < deadline:
        r = last_assistant()
        if r and (r.get("text") or "").strip() and r.get("text") != prev:
            reply2 = r
            break
        time.sleep(2)
    data = conv_data() or {}
    title2 = None
    for c in data.get("items") or []:
        title2 = c.get("title")
        break
    print("reply2", json.dumps({
        "text": (reply2 or {}).get("text", "")[:200],
        "title1": title1,
        "title2": title2,
        "title_frozen": title1 == title2,
    }, ensure_ascii=False))
    screenshot("04-followup.png")
    print("SCENARIO_DONE")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "dump"
    if cmd == "scenario":
        scenario()
        return
    app = wait_app(timeout=30)
    if app is None:
        print("APP_NOT_FOUND")
        print("seen:")
        for a in apps():
            print(" -", a.get_name())
        for w in niri_windows():
            print(" niri", w.get("id"), w.get("app_id"), w.get("title"))
        sys.exit(2)
    print("APP", app.get_name())
    rows = dump(app)
    if cmd == "dump":
        screenshot("dump.png")
        return
    if cmd == "shot":
        screenshot(sys.argv[2] if len(sys.argv) > 2 else "shot.png")
        return
    if cmd == "settings":
        sys.exit(0 if click_named(rows, "设置") else 3)
    if cmd == "save":
        sys.exit(0 if click_named(rows, "保存") else 3)
    if cmd == "new":
        sys.exit(0 if click_named(rows, "新对话") else 3)
    if cmd == "send":
        sys.exit(0 if click_named(rows, "发送") else 3)
    if cmd == "type":
        sys.exit(0 if set_text(rows, sys.argv[2]) else 3)
    if cmd == "thinking":
        sys.exit(0 if click_named(rows, "思考过程") else 3)
    print("unknown cmd", cmd)
    sys.exit(4)


if __name__ == "__main__":
    main()
