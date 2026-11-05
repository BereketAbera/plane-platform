#!/usr/bin/env python3
"""Fails on a case statement inside a command substitution, on one line or across lines. Bash 3.2 reads the ) of a
case pattern as the end of the substitution, so it fails when that line runs, and bash -n passes it. The (PATTERN)
form is safe, and a helper function is clearer. Prints each place, and exits 1 if there is any."""
import re, sys

found = 0
for path in sys.argv[1:]:
    with open(path, errors="replace") as f:
        text = f.read()
    depth_at_case = []
    depth = 0
    for number, line in enumerate(text.splitlines(), 1):
        code = line.split(" # ", 1)[0]
        if code.lstrip().startswith("#"):
            continue
        for m in re.finditer(r"\$\((?!\()|\bcase\b|\(|\)", code):
            token = m.group(0)
            if token == "$(":
                depth += 1
            elif token == "case":
                if depth > 0:
                    print(f"{path}:{number}: case inside a command substitution")
                    found += 1
            elif token == "(":
                depth += 1 if depth else 0
            elif token == ")":
                depth = max(0, depth - 1)
sys.exit(1 if found else 0)
