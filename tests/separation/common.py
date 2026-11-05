"""Shared by network.py and state.py: kubectl, and a report whose every line is PASS, FAIL or BLOCKED.

Both scripts handle Secrets of both environments, so everything they print goes through Report.say, which replaces
any Secret value it finds and counts the find as a failure. Exit status as in scripts/test.sh: 0 everything passed,
1 something failed, 2 nothing failed but something could not run.
"""
from __future__ import annotations

import base64
import datetime as dt
import json
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ENVS = {"dev": "plane-dev", "prod-sim": "plane-prod-sim"}
OTHER = {"dev": "prod-sim", "prod-sim": "dev"}
SECRET_NAMES = ["plane-app-env", "plane-app-keys", "plane-live-env", "plane-doc-store", "plane-pgdb", "plane-rabbitmq",
                "plane-infisical-identity"]
# A Secret value shorter than this also appears in ordinary text.
SHORTEST_SCANNED_VALUE = 6
# The contract fixes these or they are harmless to share, so both environments may hold the same value.
NOT_CREDENTIALS = {("plane-doc-store", "USE_MINIO"), ("plane-doc-store", "AWS_S3_BUCKET_NAME"),
                   ("plane-doc-store", "AWS_S3_ENDPOINT_URL"), ("plane-doc-store", "FILE_SIZE_LIMIT"),
                   ("plane-pgdb", "POSTGRES_USER"), ("plane-pgdb", "POSTGRES_DB"), ("plane-rabbitmq", "RABBITMQ_DEFAULT_USER")}


class Blocked(Exception):
    """A check cannot run, which says nothing about separation."""


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def kubectl(*args: str, stdin: str | None = None, timeout: float = 120) -> subprocess.CompletedProcess:
    pinned = ROOT / ".tools" / "bin" / "kubectl"
    command = [str(pinned) if pinned.exists() else "kubectl",
               "--kubeconfig", os.environ.get("KUBECONFIG") or str(ROOT / ".local" / "kubeconfig"),
               "--context", os.environ.get("KUBE_CONTEXT") or "kind-plane-platform", *args]
    try:
        return subprocess.run(command, input=stdin, capture_output=True, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Blocked(f"kubectl {' '.join(args[:6])}: {type(exc).__name__}") from exc


def must(*args: str, stdin: str | None = None, timeout: float = 120) -> str:
    done = kubectl(*args, stdin=stdin, timeout=timeout)
    if done.returncode != 0:
        raise Blocked(f"kubectl {' '.join(args[:6])} exited {done.returncode}: {done.stderr.strip()[:300]}")
    return done.stdout


def read_secret(namespace: str, name: str) -> dict[str, str]:
    item = json.loads(must("-n", namespace, "get", "secret", name, "-o", "json"))
    return {key: base64.b64decode(value).decode() for key, value in item.get("data", {}).items()}


def read_secrets() -> dict[str, dict[str, dict[str, str]]]:
    """Read into memory only, by environment and Secret."""
    return {env: {name: read_secret(namespace, name) for name in SECRET_NAMES} for env, namespace in ENVS.items()}


def credential_values(stores: dict) -> set[str]:
    return {value for store in stores.values() for name, secret in store.items() for key, value in secret.items()
            if (name, key) not in NOT_CREDENTIALS and len(value) >= SHORTEST_SCANNED_VALUE}


def require_environments() -> None:
    """A rollout in flight has pods missing or being replaced, and that must not read as a result."""
    for namespace in ENVS.values():
        must("get", "namespace", namespace, timeout=30)
        app = json.loads(must("-n", "argocd", "get", "application", namespace, "-o", "json", timeout=30))
        state = f"{app['status']['sync']['status']}/{app['status']['health']['status']}"
        if state != "Synced/Healthy":
            raise Blocked(f"Application {namespace} is {state}. Run this when both environments are Synced and Healthy")


def attempts_printed(stdout: str, key: str) -> dict[str, dict]:
    """The JSON lines a script in a pod printed, by the attempt each one names. A line that is not one is left out, and the
    caller compares the rest with what it asked for, so an attempt with no line reads BLOCKED and does not just vanish."""
    printed = {}
    for line in stdout.splitlines():
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if isinstance(record, dict) and key in record:
            printed[record[key]] = record
    return printed


class Report:
    def __init__(self) -> None:
        self.passes = 0
        self.failures: list[str] = []
        self.blocked: list[str] = []
        self.values: set[str] = set()
        self.leaked = 0

    def add_secrets(self, values) -> None:
        self.values.update(value for value in values if value)

    def say(self, text: str = "") -> None:
        for value in sorted(self.values, key=len, reverse=True):
            if value in text:
                self.leaked += 1
                text = text.replace(value, "***")
        print(text, flush=True)

    def check(self, ok: bool, text: str) -> None:
        if ok:
            self.passes += 1
            self.say(f"PASS {text}")
        else:
            self.failures.append(text)
            self.say(f"FAIL {text}")

    def block(self, text: str) -> None:
        self.blocked.append(text)
        self.say(f"BLOCKED {text}")

    def finish(self) -> int:
        self.say(f"\nRESULT checks passed={self.passes} failed={len(self.failures)} blocked={len(self.blocked)} {now()}")
        for failure in self.failures:
            self.say(f"FAILED: {failure}")
        # Counted before this line is printed, so a value that got this far is reported as well as replaced.
        print(f"Scanned this output for {len(self.values)} secret values: {self.leaked} found and replaced.", flush=True)
        if self.failures or self.leaked:
            return 1
        return 2 if self.blocked else 0
