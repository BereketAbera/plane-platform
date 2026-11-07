#!/usr/bin/env python3
"""Scratch helper: pushes plain images with the push code from layer-check-cases.py. push_case.py <registry> <repo> <architecture>"""
import importlib.util, os, sys, io, tarfile
sys.dont_write_bytecode = True
CHECKS = "/Users/bek/dev/pr/plane-platform/apps/wayline/checks"
spec = importlib.util.spec_from_file_location("cases", os.path.join(CHECKS, "layer-check-cases.py"))
cases = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cases)
registry, repo, arch = sys.argv[1:4]
content = (sys.argv[4] if len(sys.argv) > 4 else "nothing here\n").encode()
print(cases.push_image(registry, repo, cases.tar_of({"x/hello.txt": content, "etc/os-release": b'ID=alpine\nVERSION_ID=3.21.0\n'}), arch))
