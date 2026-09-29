#!/usr/bin/env python3
"""Update the Hyprland cursor snapshot.

Prints "ok" when a cursor position was read, otherwise "unavailable".
Writes last_input_ms only when the pointer moves by at least 8 pixels,
and seeds last_input_ms on the first successful read.

Hyprland socket events are intentionally not used: they fire on
notifications and animations and were resetting idle on an empty desk.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from typing import Optional

DEADZONE = 8


def now_ms() -> int:
    return int(time.time() * 1000)


def atomic_write(path: str, text: str) -> None:
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.replace(tmp, path)


def hypr_signature() -> Optional[str]:
    sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "").strip()
    if sig:
        return sig
    runtime = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    hypr = os.path.join(runtime, "hypr")
    try:
        names = sorted(os.listdir(hypr))
    except OSError:
        return None
    return names[0] if names else None


def cursor_pos() -> Optional[str]:
    sig = hypr_signature()
    commands = []
    if sig:
        commands.append(["hyprctl", "-i", sig, "-j", "cursorpos"])
        commands.append(["hyprctl", "-i", sig, "cursorpos"])
    commands.append(["hyprctl", "-j", "cursorpos"])
    commands.append(["hyprctl", "cursorpos"])
    for cmd in commands:
        try:
            out = subprocess.check_output(
                cmd, stderr=subprocess.DEVNULL, text=True, timeout=2
            ).strip()
        except (OSError, subprocess.SubprocessError, subprocess.TimeoutExpired):
            continue
        if not out:
            continue
        if out.startswith("{"):
            try:
                data = json.loads(out)
            except json.JSONDecodeError:
                continue
            if "x" in data and "y" in data:
                return f"{data['x']},{data['y']}"
            continue
        compact = out.replace(" ", "")
        if "," in compact:
            return compact
    return None


def moved(previous: Optional[str], current: str) -> bool:
    if previous in (None, current):
        return False
    try:
        x_str, y_str = current.replace(" ", "").split(",", 1)
        px_str, py_str = str(previous).replace(" ", "").split(",", 1)
        return abs(float(x_str) - float(px_str)) >= DEADZONE or abs(
            float(y_str) - float(py_str)
        ) >= DEADZONE
    except (TypeError, ValueError):
        return True


def main() -> int:
    if len(sys.argv) != 3:
        print("unavailable")
        return 2
    snap_path, last_path = sys.argv[1], sys.argv[2]
    current = cursor_pos()
    if current is None:
        print("unavailable")
        return 2

    previous = None
    if os.path.exists(snap_path):
        try:
            with open(snap_path, encoding="utf-8") as handle:
                previous = json.loads(handle.read()).get("cursor")
        except (OSError, json.JSONDecodeError):
            previous = None

    atomic_write(
        snap_path,
        json.dumps({"cursor": current, "t": now_ms()}),
    )
    if not os.path.exists(last_path) or moved(previous, current):
        atomic_write(last_path, str(now_ms()))
    print("ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
