"""Run the unchanged read-only terminal viewer in a PTY and inspect its PNG output."""
import base64
import fcntl
import json
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time

master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 1200, 800))
pid = os.fork()
if pid == 0:
    os.close(master)
    os.setsid()
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    for descriptor in (0, 1, 2):
        os.dup2(slave, descriptor)
    os.close(slave)
    os.environ["TERM"] = "xterm-kitty"
    os.environ.pop("TMUX", None)
    os.execv("./dist/terminal-mac", ["terminal-mac", "view", sys.argv[1] if len(sys.argv) > 1 else "default", "--read-only", "--protocol", "kitty"])

os.close(slave)
received = bytearray()
status = None
try:
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if select.select([master], [], [], 0.1)[0]:
            try:
                received.extend(os.read(master, 65536))
            except OSError:
                break
        finished, code = os.waitpid(pid, os.WNOHANG)
        if finished:
            status = code
            break
    if status is None:
        os.write(master, b"\x1d")
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                try:
                    received.extend(os.read(master, 65536))
                except OSError:
                    pass
            finished, code = os.waitpid(pid, os.WNOHANG)
            if finished:
                status = code
                break
    assert status == 0, "Viewer did not exit cleanly"
    images, pieces = [], []
    for header, payload in re.findall(rb"\x1b_G([^;]*);([^\x1b]*)\x1b\\", received):
        if b"a=T,f=100" in header:
            pieces = []
        if pieces or b"a=T,f=100" in header:
            pieces.append(payload)
            if b"m=0" in header:
                png = base64.b64decode(b"".join(pieces))
                assert png[:8] == b"\x89PNG\r\n\x1a\n"
                images.append(struct.unpack(">II", png[16:24]))
                pieces = []
    assert images, "Viewer produced no PNG frames"
    assert all(width > 640 for width, _ in images), "Viewer unexpectedly used observer width"
    print(json.dumps({"status": "pass", "pngFrames": len(images), "dimensions": sorted(set(images)), "viewerExit": status}))
finally:
    if status is None:
        os.kill(pid, signal.SIGTERM)
        os.waitpid(pid, 0)
    os.close(master)
