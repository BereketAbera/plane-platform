#!/usr/bin/env python3
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
"""Fails if the flattened backend image dropped anything the base image's config says.

The last stage of runtime/Dockerfile.backend is FROM scratch, which starts with an empty config, so that stage restates
the base's by hand, and a later base could add something the restatement misses: an Env value, a port, a stop signal.
This reads the base at the digest that Dockerfile pins, and the built image, and compares every field. A field it has
no rule for fails, so a new kind of setting is read too. The differences that are meant are listed below and nothing
else is allowed. It also fails if the image shares a layer with the base, other than the empty one.

    flatten-config.py <built image>                     must name a digest
    flatten-config.py --base-config <file> <built image>    the base's config from a file, for a negative control

scripts/ci/build-images.sh runs this after pushing the backend, before it records any digest, and so does
checks/smoke-images.sh. Exits 0 if nothing is dropped, 1 if something is, and 2 if an image cannot be read.
"""
import argparse
import json
import os
import re
import sys

# A __pycache__ beside this file would make the source read as changed, and scripts/ci/build-images.sh would refuse it.
sys.dont_write_bytecode = True

from oci_read import EMPTY_LAYER, Image, Unreadable

DOCKERFILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "runtime", "Dockerfile.backend")

# Every difference from the base that the Dockerfile means.
OURS_ENV = {"INSTANCE_CHANGELOG_URL": ""}  # Empty takes the local fallback, not upstream's page. MODIFICATIONS.md says so.
OURS_USER = "1000"  # Upstream's image runs as root. The chart runs it as 1000, and so does this.
OURS_LABELS = {
    "org.opencontainers.image.title",
    "org.opencontainers.image.description",
    "org.opencontainers.image.licenses",
    "org.opencontainers.image.source",
    "org.opencontainers.image.revision",
}
# These must be the same as the base's, absent or not.
SAME = ("Cmd", "Entrypoint", "WorkingDir", "ExposedPorts", "Volumes", "StopSignal", "Healthcheck", "Shell", "OnBuild", "ArgsEscaped")
KNOWN = {*SAME, "Env", "User", "Labels"}

failures = 0


def report(ok, label, detail=""):
    global failures
    failures += 0 if ok else 1
    print(f"{'PASS' if ok else 'FAIL'} {label}{(' ' + detail) if detail else ''}", flush=True)


def as_dict(env):
    return dict(item.split("=", 1) for item in env or [])


def pinned_base():
    with open(DOCKERFILE, encoding="utf-8") as handle:
        text = handle.read()
    froms = re.findall(r"^FROM\s+(\S+)", text, re.M)
    report(len(froms) == 2 and froms[1] == "scratch", "Dockerfile.backend has two stages and the last is FROM scratch", str(froms))
    return froms[0]


def compare(base, built):
    print("\n== Env")
    base_env, built_env = as_dict(base.get("Env")), as_dict(built.get("Env"))
    for key in sorted(base_env.keys() | built_env.keys()):
        if key in OURS_ENV:
            report(built_env.get(key) == OURS_ENV[key], f"{key} is ours, as the Dockerfile means it")
        elif key not in base_env:
            report(False, f"{key} is in the image and not in the base, and nothing here says it is meant")
        elif key not in built_env:
            report(False, f"{key} is in the base and the image dropped it")
        else:
            report(base_env[key] == built_env[key], f"{key} is the base's value")

    print("\n== Labels")
    base_labels, built_labels = base.get("Labels") or {}, built.get("Labels") or {}
    for key in sorted(base_labels.keys() | built_labels.keys() | OURS_LABELS):
        if key in OURS_LABELS:
            report(bool(built_labels.get(key)), f"{key} is set", built_labels.get(key, ""))
        elif key not in built_labels:
            report(False, f"label {key} is in the base and the image dropped it")
        elif key not in base_labels:
            report(False, f"label {key} is in the image and not in the base, and nothing here says it is meant")
        else:
            report(base_labels[key] == built_labels[key], f"label {key} is the base's value")

    print("\n== User")
    report(built.get("User") == OURS_USER, f"User is {OURS_USER}, where the base says {base.get('User')!r}", repr(built.get("User")))

    print("\n== Everything else")
    for key in SAME:
        left, right = base.get(key), built.get(key)
        report(left == right, f"{key} is the base's", json.dumps(right, sort_keys=True))

    unknown = sorted((base.keys() | built.keys()) - KNOWN)
    report(not unknown, "every config field has a rule here", f"no rule for: {unknown}" if unknown else "")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("image")
    parser.add_argument("--base-config", help="read the base's config from this JSON file, as a negative control")
    parser.add_argument("--platform", default="linux/arm64")
    args = parser.parse_args()

    base_ref = pinned_base()
    try:
        built = Image(args.image, args.platform)
        base = Image(base_ref, args.platform)
    except (Unreadable, OSError) as err:
        print(f"COULD NOT READ: {err}")
        sys.exit(2)
    print(f"base  {base_ref}, config {base.config_digest}, read from {base.source}")
    print(f"built {args.image}, config {built.config_digest}")

    base_config = base.config.get("config", {})
    if args.base_config:
        with open(args.base_config, encoding="utf-8") as handle:
            base_config = json.load(handle)
        print(f"base's config taken from {args.base_config}, not from the base")
    compare(base_config, built.config.get("config", {}))

    print("\n== Layers")
    shared = {layer["digest"] for layer in base.layers} & {layer["digest"] for layer in built.layers}
    shared.discard(EMPTY_LAYER)
    report(not shared, "the image shares no layer with the base, other than the empty one", str(sorted(shared)) if shared else f"{len(built.layers)} layers")
    for key in ("architecture", "os"):
        report(base.config.get(key) == built.config.get(key), f"{key} is the base's", str(built.config.get(key)))

    print(f"\nRESULT {'FAIL' if failures else 'PASS'}: {failures} failed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
