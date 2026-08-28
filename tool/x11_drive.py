#!/usr/bin/env python3
"""Click/type in the X11 cursor_chat window (GDK_BACKEND=x11)."""

from __future__ import annotations

import sys
import time

from Xlib import XK, X, display
from Xlib.ext import xtest


def _display():
    return display.Display()


def _walk(d, win, acc):
    try:
        name = win.get_wm_name()
        cls = win.get_wm_class()
        acc.append((win, name, cls))
        for c in win.query_tree().children:
            _walk(d, c, acc)
    except Exception:
        pass
    return acc


def find_chat(d):
    root = d.screen().root
    for win, name, cls in _walk(d, root, []):
        blob = " ".join(
            [
                str(name or ""),
                " ".join(cls or ()),
            ]
        ).lower()
        if "cursor_chat" in blob or "dev.vox.cursor_chat" in blob:
            geom = win.get_geometry()
            if geom.width < 200 or geom.height < 200:
                continue
            return win
    return None


def abs_pos(d, win):
    root = d.screen().root
    p = root.translate_coords(win, 0, 0)
    g = win.get_geometry()
    return p.x, p.y, g.width, g.height


def click(d, x, y):
    xtest.fake_input(d, X.MotionNotify, x=int(x), y=int(y))
    d.sync()
    time.sleep(0.05)
    xtest.fake_input(d, X.ButtonPress, 1)
    d.sync()
    time.sleep(0.04)
    xtest.fake_input(d, X.ButtonRelease, 1)
    d.sync()
    time.sleep(0.08)


def key_once(d, keysym, shift=False):
    shift_code = d.keysym_to_keycode(XK.XK_Shift_L)
    code = d.keysym_to_keycode(keysym)
    if not code:
        raise RuntimeError(f"no keycode for {keysym}")
    if shift:
        xtest.fake_input(d, X.KeyPress, shift_code)
    xtest.fake_input(d, X.KeyPress, code)
    xtest.fake_input(d, X.KeyRelease, code)
    if shift:
        xtest.fake_input(d, X.KeyRelease, shift_code)
    d.sync()
    time.sleep(0.02)


def type_ascii(d, text):
    special = {
        " ": XK.XK_space,
        ".": XK.XK_period,
        "-": XK.XK_minus,
        "=": XK.XK_equal,
        "?": XK.XK_question,
        "+": XK.XK_plus,
        "*": XK.XK_asterisk,
        "/": XK.XK_slash,
        "'": XK.XK_apostrophe,
        ",": XK.XK_comma,
        ":": XK.XK_colon,
        "\n": XK.XK_Return,
    }
    for ch in text:
        if ch in special:
            ks = special[ch]
            shift = ch in "?+*: "
            if ch in " ?+*":
                shift = ch in "?+*"
            if ch == ":":
                shift = True
            if ch == "?":
                shift = True
            if ch == "+":
                shift = True
            if ch == "*":
                shift = True
            key_once(d, ks, shift=shift)
            continue
        if ch.isupper() or (not ch.isalnum() and ch in "!@#$%^&()"):
            ks = XK.string_to_keysym(ch.lower()) if ch.isalpha() else XK.string_to_keysym(ch)
            key_once(d, XK.string_to_keysym(ch.lower()) if ch.isalpha() else special.get(ch, XK.string_to_keysym(ch)), shift=ch.isupper())
            continue
        ks = XK.string_to_keysym(ch)
        if not ks:
            raise RuntimeError(f"cannot type {ch!r}")
        key_once(d, ks, shift=ch.isupper())


def enter(d):
    key_once(d, XK.XK_Return)


def ctrl_a(d):
    ctrl = d.keysym_to_keycode(XK.XK_Control_L)
    a = d.keysym_to_keycode(XK.XK_a)
    xtest.fake_input(d, X.KeyPress, ctrl)
    xtest.fake_input(d, X.KeyPress, a)
    xtest.fake_input(d, X.KeyRelease, a)
    xtest.fake_input(d, X.KeyRelease, ctrl)
    d.sync()


def info():
    d = _display()
    win = find_chat(d)
    if win is None:
        print("NO_WINDOW")
        sys.exit(2)
    x, y, w, h = abs_pos(d, win)
    print(f"WINDOW {x},{y} {w}x{h} id={hex(win.id)}")
    return d, win, x, y, w, h


def rel_click(rx, ry):
    d, win, x, y, w, h = info()
    cx, cy = x + rx * w, y + ry * h
    print(f"click {cx:.0f},{cy:.0f}")
    click(d, cx, cy)


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "info"
    if cmd == "info":
        info()
        return
    if cmd == "click":
        rel_click(float(sys.argv[2]), float(sys.argv[3]))
        return
    if cmd == "click-xy":
        d = _display()
        click(d, int(sys.argv[2]), int(sys.argv[3]))
        print("clicked", sys.argv[2], sys.argv[3])
        return
    if cmd == "type":
        d = _display()
        type_ascii(d, sys.argv[2])
        print("typed", len(sys.argv[2]), "chars")
        return
    if cmd == "enter":
        enter(_display())
        return
    if cmd == "ctrl-a":
        ctrl_a(_display())
        return
    print("unknown", cmd)
    sys.exit(4)


if __name__ == "__main__":
    main()
