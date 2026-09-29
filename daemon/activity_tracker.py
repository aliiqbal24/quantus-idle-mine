#!/usr/bin/env python3
"""Mark keyboard and mouse activity from readable /dev/input devices.

Requires membership in the `input` group (or equivalent read permission).
EV_ABS is ignored so noisy absolute devices do not keep the machine "busy".
Keys (EV_KEY) and relative pointer motion (EV_REL) count.
"""

from __future__ import annotations

import os
import select
import struct
import sys
import time
from typing import List

EVENT_FORMAT = "llHHi"
EVENT_SIZE = struct.calcsize(EVENT_FORMAT)
EV_KEY = 0x01
EV_REL = 0x02


def atomic_write(path: str, text: str) -> None:
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.replace(tmp, path)


def open_devices() -> List[int]:
    fds: List[int] = []
    try:
        names = sorted(os.listdir("/dev/input"))
    except OSError:
        return fds
    for name in names:
        if not name.startswith("event"):
            continue
        path = os.path.join("/dev/input", name)
        try:
            fds.append(os.open(path, os.O_RDONLY | os.O_NONBLOCK))
        except OSError:
            continue
    return fds


def seed(path: str) -> None:
    if not os.path.exists(path):
        atomic_write(path, str(int(time.time() * 1000)))


def interesting(payload: bytes) -> bool:
    if len(payload) < EVENT_SIZE or len(payload) % EVENT_SIZE != 0:
        return False
    for offset in range(0, len(payload), EVENT_SIZE):
        _sec, _usec, ev_type, _code, value = struct.unpack_from(
            EVENT_FORMAT, payload, offset
        )
        if ev_type == EV_KEY and value:
            return True
        if ev_type == EV_REL and value:
            return True
    return False


def main() -> int:
    if len(sys.argv) == 2 and sys.argv[1] == "--check":
        fds = open_devices()
        for fd in fds:
            os.close(fd)
        return 0 if fds else 2
    if len(sys.argv) != 2:
        print("usage: activity_tracker.py LAST_INPUT_FILE | --check", file=sys.stderr)
        return 2

    last_path = sys.argv[1]
    fds = open_devices()
    if not fds:
        return 2
    seed(last_path)
    last_mark = 0.0
    try:
        while True:
            readable, _, _ = select.select(fds, [], [], 1.0)
            active = False
            for fd in readable:
                try:
                    payload = os.read(fd, EVENT_SIZE * 64)
                except OSError:
                    continue
                if interesting(payload):
                    active = True
            now = time.time()
            if active and now - last_mark >= 0.5:
                atomic_write(last_path, str(int(now * 1000)))
                last_mark = now
    finally:
        for fd in fds:
            os.close(fd)


if __name__ == "__main__":
    sys.exit(main())
