#!/usr/bin/env python3
"""On a real terminal: runs a command, sends Ctrl-C through the terminal once a pattern shows in one file, and closes the
terminal once a pattern shows in another, as a person who pressed Ctrl-C, saw nothing for a while and closed the window.
ctrlc-then-close.py <file1> <regex1> <file2> <regex2> <limit> <command...>"""
import os, pty, re, select, signal, sys, time
f1, p1, f2, p2, limit = sys.argv[1], re.compile(sys.argv[2]), sys.argv[3], re.compile(sys.argv[4]), float(sys.argv[5])
pid, fd = pty.fork()
if pid == 0:
    for sig in (signal.SIGINT, signal.SIGHUP, signal.SIGPIPE):
        signal.signal(sig, signal.SIG_DFL)
    os.execvp(sys.argv[6], sys.argv[6:])
def has(path, pattern):
    try:
        with open(path) as f:
            return bool(pattern.search(f.read()))
    except FileNotFoundError:
        return False
deadline = time.time() + limit
state = 0
closed = False
while time.time() < deadline:
    ready, _, _ = select.select([fd], [], [], 0.05)
    if ready:
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        sys.stdout.buffer.write(data)
        sys.stdout.flush()
    if state == 0 and has(f1, p1):
        os.write(fd, b"\x03")
        print("[helper] Ctrl-C sent through the terminal", flush=True)
        state = 1
    elif state == 1 and has(f2, p2):
        print("[helper] the window closes", flush=True)
        os.close(fd)
        closed = True
        try:
            os.killpg(pid, signal.SIGHUP)
        except ProcessLookupError:
            pass
        break
def too_long(*_):
    os.kill(pid, signal.SIGKILL)
signal.signal(signal.SIGALRM, too_long)
signal.alarm(int(limit))
_, status = os.waitpid(pid, 0)
sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status))
