#!/usr/bin/env python3
"""For tests/drills/clean-restore-harness.sh: runs a command on a real terminal, and closes that terminal once a pattern
shows in a file, as closing a window does. From then on its prints fail. On this OS the close signals only the session
leader, and with a person's shell as that leader, the shell passes SIGHUP on to the foreground job. So this does that part.
Exits as the command did.

  close-terminal.py <file> <regular expression> <limit in seconds> <command...>"""
import os, pty, re, select, signal, sys, time

path, pattern, limit = sys.argv[1], re.compile(sys.argv[2]), float(sys.argv[3])
pid, terminal = pty.fork()
if pid == 0:
    # Python starts with SIGPIPE ignored, and a script cannot trap what it was started ignoring. A terminal leaves these
    # at their defaults.
    for sig in (signal.SIGINT, signal.SIGHUP, signal.SIGPIPE):
        signal.signal(sig, signal.SIG_DFL)
    os.execvp(sys.argv[4], sys.argv[4:])

deadline = time.time() + limit
while time.time() < deadline:
    ready, _, _ = select.select([terminal], [], [], 0.1)
    if ready:
        try:
            data = os.read(terminal, 65536)
        except OSError:
            break
        if not data:
            break
        sys.stdout.buffer.write(data)
        sys.stdout.flush()
    try:
        with open(path) as f:
            if pattern.search(f.read()):
                break
    except FileNotFoundError:
        pass
os.close(terminal)
try:
    os.killpg(pid, signal.SIGHUP)
except ProcessLookupError:
    pass


def too_long(*_):
    os.kill(pid, signal.SIGKILL)


signal.signal(signal.SIGALRM, too_long)
signal.alarm(int(limit))
_, status = os.waitpid(pid, 0)
sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status))
