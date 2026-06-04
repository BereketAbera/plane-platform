#!/usr/bin/env python3
"""Stub of tests/e2e/smoke.py for tests/drills/clean-restore-harness.sh. A state file says what each kind of call exits with:
smoke-rc-verify for the check a clean restore makes at the end, smoke-rc-proof for the proof inside a restore."""
import os, sys

S = os.environ["H_STATE"]
with open(f"{S}/calls.log", "a") as f:
    f.write("smoke " + " ".join(sys.argv[1:4]) + "\n")
name = "smoke-rc-proof" if "--job-probe" in sys.argv else "smoke-rc-verify"
try:
    with open(f"{S}/{name}") as f:
        sys.exit(int(f.read().strip()))
except FileNotFoundError:
    sys.exit(0)
