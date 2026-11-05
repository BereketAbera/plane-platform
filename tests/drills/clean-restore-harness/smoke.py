#!/usr/bin/env python3
"""Stub of tests/e2e/smoke.py for tests/drills/clean-restore-harness.sh. A state file says what each kind of call exits with:
smoke-rc-verify for the check a clean restore makes at the end, smoke-rc-proof for the proof inside a restore."""
import os, subprocess, sys

S = os.environ["H_STATE"]
proof = "--job-probe" in sys.argv
with open(f"{S}/calls.log", "a") as f:
    f.write("smoke " + " ".join(sys.argv[1:5]) + (" proof" if proof else "") + "\n")
name = "smoke-rc-proof" if proof else "smoke-rc-verify"
# So a scenario can change something after a restore has proven it, for the check at the end to find.
hook = f"{S}/smoke-proof-hook"
if proof and os.path.exists(hook):
    os.rename(hook, hook + ".ran")
    subprocess.run(["/bin/bash", hook + ".ran"], check=True)
try:
    with open(f"{S}/{name}") as f:
        sys.exit(int(f.read().strip()))
except FileNotFoundError:
    sys.exit(0)
