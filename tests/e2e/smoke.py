#!/usr/bin/env python3
"""End-to-end smoke test of a running Plane environment, through Traefik, over real HTTP.

Standard library only, so it runs on a clean host and in any CI image. HTTP cannot see inside a
broker or a bucket, so a few steps also use kubectl. They read BLOCKED when the cluster is out of reach.

Every line of output is PASS, FAIL, BLOCKED or SKIP. BLOCKED means a step could not run because
something it depends on did not pass, so it is neither evidence of working nor of broken. SKIP means a
step does not apply to this environment as it stands, and its line says why. It proves nothing either
way, and it is how branding reads until an environment runs the Wayline images.

Exit status: 0 all passed, 1 at least one FAIL, 2 no FAIL but something was BLOCKED. SKIP does not count.

During a rollout, workloads-ready and branding-overlay read BLOCKED and not FAIL, so a run that finds nothing else exits 2.
That is not a pass, and it says nothing about the images on their way. A step that does fail during one still exits 1,
because nothing here can tell whether the rollout caused it, so read such a run again once the rollout has finished. A
rollout past its deadline is no longer under way, and fails, and so is a sync that has failed an attempt and is retrying.

Generated credentials go only to .local/test-accounts.env (mode 0600). They are never printed
and never written to the evidence file.

--env hosted --mode verify is another flow, for hosted production: over https, with a person's existing account, whose email and
password come on stdin from scripts/hosted/smoke.sh. It creates no user and never touches the admin sign-up. It makes one project,
one work item, an attachment, a page and a short-lived API token, and removes them before it ends, whatever else happened.
"""
from __future__ import annotations

import argparse
import base64
import contextlib
import datetime as dt
import fcntl
import hashlib
import http.client
import http.server
import io
import json
import os
import re
import secrets
import select
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import zipfile
from http.cookies import SimpleCookie
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlsplit

ROOT = Path(__file__).resolve().parents[2]
LOCAL_DIR = ROOT / ".local"
HOSTS = {"dev": "plane.dev.localhost", "prod-sim": "plane.prod-sim.localhost"}
ADMIN_EMAIL = "smoke-admin@wayline.test"
# Names no host of its own: scripts/hosted/smoke.sh passes the one in infrastructure/hosted.
HOSTED = "hosted"

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
# Hocuspocus 2.15 wire values, confirmed against its source in the research and in the live image.
HP_MSG_SYNC = 0
HP_MSG_AUTH = 2
HP_MSG_SYNC_REPLY = 4
HP_MSG_SYNC_STATUS = 8
HP_AUTH_TOKEN = 0
HP_AUTH_DENIED = 1
HP_AUTH_OK = 2
# y-protocols/sync.
Y_SYNC_STEP1 = 0
Y_SYNC_STEP2 = 1
Y_SYNC_UPDATE = 2
Y_EMPTY_STATE_VECTOR = b"\x00"
Y_EMPTY_UPDATE = b"\x00\x00"
CSRF_FAILURE_TITLE = b"CSRF Verification Failed"
# What a healthy environment runs. Names match in both, because the Helm release is `plane` in each.
WORKLOADS = [("Deployment", f"plane-{name}-wl") for name in ("web", "admin", "space", "live", "api", "worker", "beat-worker")]
WORKLOADS += [("StatefulSet", f"plane-{name}-wl") for name in ("pgdb", "redis", "rabbitmq", "minio")]
MIGRATOR_JOB = "plane-api-migrate-1"
WORKER_SELECTOR = "app.kubernetes.io/component=worker"
# What the Wayline images replace, and the Deployments that run each. The backend image serves three.
BRANDED_WORKLOADS = {"web": ["plane-web-wl"], "admin": ["plane-admin-wl"], "space": ["plane-space-wl"],
                     "backend": ["plane-api-wl", "plane-worker-wl", "plane-beat-worker-wl"]}
BRANDED_REPOSITORY = re.compile(r"^localhost:5001/wayline/(\w+)$")
# The product name as a word, so plane-dev, plane_api and the plane.dev.localhost host do not count.
UPSTREAM_NAME = re.compile(r"(?<![A-Za-z])Plane(?![A-Za-z])")
# As apps/wayline/checks/smoke-images.sh reads a page, and the one credit apps/wayline/README.md permits.
UPSTREAM_BRAND = re.compile(r"Plane|plane\.so|makeplane")
PERMITTED_CREDIT = "Built on Plane Community Edition"
LICENCE_FILES = ("LICENSE.txt", "COPYRIGHT.txt", "NOTICE.txt", "MODIFICATIONS.txt", "OFL-InstrumentSans.txt",
                 "OFL-JetBrainsMono.txt")
# A 1x1 PNG, because the avatar endpoint accepts images only.
ONE_PIXEL_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
)
# Runs in the api pod with its own credentials. It talks straight to Silo, past Traefik, and prints
# sizes and hashes only.
SILO_PROBE = """
import boto3, hashlib, json, os, sys
from botocore.config import Config
s3 = boto3.client("s3", endpoint_url=os.environ["AWS_S3_ENDPOINT_URL"],
                  aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
                  aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
                  config=Config(signature_version="s3v4"))
bucket = os.environ["AWS_S3_BUCKET_NAME"]
body = s3.get_object(Bucket=bucket, Key=sys.argv[1])["Body"].read()
print(json.dumps({"bucket": bucket, "all_buckets": [b["Name"] for b in s3.list_buckets()["Buckets"]],
                  "size": len(body), "sha256": hashlib.sha256(body).hexdigest()}))
"""


class StepFailed(Exception):
    """The step ran and the system misbehaved."""


class StepBlocked(Exception):
    """The step cannot run, which says nothing about the system under test."""


class StepSkipped(Exception):
    """The step does not apply here. Its message says why, and it counts neither for nor against."""


class Redactor:
    """Last line of defence: anything that reaches stdout or the evidence file passes here."""

    PATTERNS = [
        (re.compile(r"plane_api_[0-9a-zA-Z]+"), "plane_api_***"),
        (re.compile(r"(?i)(x-amz-signature=)[^&\s\"']+"), r"\1***"),
        (re.compile(r"(?i)(x-amz-credential=)[^&\s\"']+"), r"\1***"),
        (re.compile(r"(?i)(session-id=)[^;\s\"']+"), r"\1***"),
        # An S3 error body echoes the signature and the access key, which is Silo's root user here.
        (re.compile(r"(<(?:SignatureProvided|AWSAccessKeyId|StringToSign|CanonicalRequest)[^>]*>)[^<]*"), r"\1***"),
    ]

    def __init__(self) -> None:
        self.values: set[str] = set()

    def add(self, value: str | None) -> None:
        if value:
            self.values.add(value)

    def __call__(self, text: str) -> str:
        for value in sorted(self.values, key=len, reverse=True):
            text = text.replace(value, "***")
        for pattern, replacement in self.PATTERNS:
            text = pattern.sub(replacement, text)
        return text


class Response:
    def __init__(self, status: int, headers: http.client.HTTPMessage, body: bytes) -> None:
        self.status = status
        self.headers = headers
        self.body = body

    @property
    def location(self) -> str:
        return self.headers.get("Location", "") or ""

    def json(self):
        try:
            return json.loads(self.body or b"null")
        except ValueError as exc:
            raise StepFailed(f"HTTP {self.status}: response is not JSON") from exc

    def snippet(self) -> str:
        return self.body[:200].decode("utf-8", "replace").replace("\n", " ")


class TlsConnection(http.client.HTTPSConnection):
    """Dials one address, and names the public host in SNI and in the certificate check, as a browser would."""

    def __init__(self, server_name: str, host: str, port: int, *, timeout: float, tls: ssl.SSLContext) -> None:
        super().__init__(host, port, timeout=timeout, context=tls)
        self.server_name = server_name
        self.tls = tls

    def connect(self) -> None:
        http.client.HTTPConnection.connect(self)
        self.sock = self.tls.wrap_socket(self.sock, server_hostname=self.server_name)


class Http:
    """A small client that always dials the Traefik address, whatever host a URL names.

    A presigned URL carries the public host, and the signature covers it, so the Host header
    must stay as signed while the TCP connection goes to the published port.
    """

    def __init__(self, host: str, connect_host: str, connect_port: int, timeout: float = 30,
                 tls: ssl.SSLContext | None = None) -> None:
        self.host = host
        self.connect_host = connect_host
        self.connect_port = connect_port
        self.timeout = timeout
        self.tls = tls
        self.scheme = "https" if tls else "http"
        self.cookies: dict[str, str] = {}
        self.cookie_flags: dict[str, dict[str, bool]] = {}

    def cookie_header(self) -> str:
        return "; ".join(f"{k}={v}" for k, v in self.cookies.items())

    def _store_cookies(self, headers: http.client.HTTPMessage) -> None:
        for raw in headers.get_all("Set-Cookie") or []:
            parsed: SimpleCookie = SimpleCookie()
            parsed.load(raw)
            for name, morsel in parsed.items():
                if morsel.value == "" or morsel["max-age"] == "0":
                    self.cookies.pop(name, None)
                else:
                    self.cookies[name] = morsel.value
                    self.cookie_flags[name] = {"secure": bool(morsel["secure"]), "httponly": bool(morsel["httponly"])}

    def request(self, method: str, target: str, *, headers: dict | None = None, body: bytes | None = None,
                session: bool = True, host: str | None = None) -> Response:
        request_headers = {"Host": host or self.host, "User-Agent": "wayline-smoke/1", "Connection": "close",
                           "Accept": "application/json"}
        request_headers.update(headers or {})
        if session and self.cookies:
            request_headers["Cookie"] = self.cookie_header()
        if self.tls:
            connection = TlsConnection(self.host, self.connect_host, self.connect_port, timeout=self.timeout, tls=self.tls)
        else:
            connection = http.client.HTTPConnection(self.connect_host, self.connect_port, timeout=self.timeout)
        try:
            connection.request(method, target, body=body, headers=request_headers)
            raw = connection.getresponse()
            data = raw.read()
            if session:
                self._store_cookies(raw.headers)
            return Response(raw.status, raw.headers, data)
        finally:
            connection.close()

    def get(self, target: str, **kwargs) -> Response:
        return self.request("GET", target, **kwargs)

    def send_json(self, method: str, target: str, payload, **kwargs) -> Response:
        headers = {"Content-Type": "application/json", **kwargs.pop("headers", {})}
        return self.request(method, target, headers=headers, body=json.dumps(payload).encode(), **kwargs)

    def post_form(self, target: str, fields: dict, **kwargs) -> Response:
        headers = {"Content-Type": "application/x-www-form-urlencoded", "Origin": f"{self.scheme}://{self.host}",
                   "Referer": f"{self.scheme}://{self.host}/", **kwargs.pop("headers", {})}
        return self.request("POST", target, headers=headers, body=urlencode(fields).encode(), **kwargs)


def hosted_tls(args: argparse.Namespace) -> ssl.SSLContext:
    if args.allow_untrusted_certificate:
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        return context
    context = ssl.create_default_context(cafile=args.ca_file)
    if not args.ca_file and not context.get_ca_certs():
        # A Python with no CA list of its own, as on macOS from python.org.
        for candidate in ("/etc/ssl/cert.pem", "/etc/ssl/certs/ca-certificates.crt"):
            if os.path.exists(candidate):
                context.load_verify_locations(candidate)
                break
    return context


def expect(response: Response, *statuses: int) -> Response:
    if CSRF_FAILURE_TITLE in response.body:
        raise StepFailed(f"Plane refused the CSRF token (HTTP {response.status})")
    if response.status not in statuses:
        raise StepFailed(f"expected HTTP {'/'.join(map(str, statuses))}, got {response.status}: {response.snippet()}")
    return response


def multipart(fields: dict, filename: str, content_type: str, content: bytes) -> tuple[str, bytes]:
    """S3 ignores everything after the file part, so the file must come last."""
    boundary = "wayline" + secrets.token_hex(12)
    parts: list[bytes] = []
    for name, value in fields.items():
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
    parts.append(
        f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{filename}"\r\n'
        f"Content-Type: {content_type}\r\n\r\n".encode() + content + b"\r\n"
    )
    parts.append(f"--{boundary}--\r\n".encode())
    return f"multipart/form-data; boundary={boundary}", b"".join(parts)


# --- WebSocket (RFC 6455) and the Hocuspocus auth frame ------------------------------------------


def uvarint(number: int) -> bytes:
    out = bytearray()
    while number > 0x7F:
        out.append((number & 0x7F) | 0x80)
        number >>= 7
    out.append(number)
    return bytes(out)


def varstring(text: str) -> bytes:
    data = text.encode()
    return uvarint(len(data)) + data


def read_uvarint(buffer: bytes, index: int) -> tuple[int, int]:
    shift = number = 0
    while True:
        byte = buffer[index]
        index += 1
        number |= (byte & 0x7F) << shift
        shift += 7
        if byte < 0x80:
            return number, index


def read_varstring(buffer: bytes, index: int) -> tuple[str, int]:
    length, index = read_uvarint(buffer, index)
    return buffer[index:index + length].decode(), index + length


def auth_frame(document: str, token: str) -> bytes:
    return varstring(document) + uvarint(HP_MSG_AUTH) + uvarint(HP_AUTH_TOKEN) + varstring(token)


def sync_frame(document: str, kind: int, payload: bytes) -> bytes:
    return varstring(document) + uvarint(HP_MSG_SYNC) + uvarint(kind) + uvarint(len(payload)) + payload


def yjs_paragraph_update(client_id: int, text: str) -> bytes:
    """A Yjs v1 update that puts <paragraph>text</paragraph> at the head of the fragment `default`.

    Written by hand so this stays standard library. selftest() holds the bytes real yjs 13.6.27
    produces for the same content, which is what proves this is right.
    """
    paragraph = bytes([7]) + uvarint(1) + varstring("default") + uvarint(3) + varstring("paragraph")
    text_node = bytes([7]) + uvarint(0) + uvarint(client_id) + uvarint(0) + uvarint(6)
    characters = bytes([4]) + uvarint(0) + uvarint(client_id) + uvarint(1) + varstring(text)
    return uvarint(1) + uvarint(3) + uvarint(client_id) + uvarint(0) + paragraph + text_node + characters + uvarint(0)


def ws_accept(key: str) -> str:
    return base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()


def ws_encode(opcode: int, payload: bytes, mask: bytes | None = None) -> bytes:
    """Clients must mask every frame, and a server may drop the connection if one is not."""
    mask = mask if mask is not None else secrets.token_bytes(4)
    header = bytearray([0x80 | opcode])
    length = len(payload)
    if length < 126:
        header.append(0x80 | length)
    elif length < 65536:
        header.append(0x80 | 126)
        header += struct.pack(">H", length)
    else:
        header.append(0x80 | 127)
        header += struct.pack(">Q", length)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return bytes(header) + mask + masked


class WsClosed(Exception):
    def __init__(self, code: int | None, reason: str) -> None:
        super().__init__(f"closed code={code} reason={reason}")
        self.code = code
        self.reason = reason


class WebSocket:
    def __init__(self, connect_host: str, connect_port: int, host: str, target: str, cookie: str,
                 timeout: float = 15, tls: ssl.SSLContext | None = None) -> None:
        self.sock = socket.create_connection((connect_host, connect_port), timeout=timeout)
        if tls:
            self.sock = tls.wrap_socket(self.sock, server_hostname=host)
        origin = f"{'https' if tls else 'http'}://{host}"
        self.buffer = b""
        self.pings = 0
        self.partial = b""
        key = base64.b64encode(secrets.token_bytes(16)).decode()
        request = (
            f"GET {target} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nOrigin: {origin}\r\n"
            f"Cookie: {cookie}\r\n\r\n"
        )
        self.sock.sendall(request.encode())
        head = self._read_until(b"\r\n\r\n").decode("latin-1")
        status_line, _, rest = head.partition("\r\n")
        if " 101 " not in status_line + " ":
            raise StepFailed(f"upgrade refused: {status_line}")
        headers = {k.strip().lower(): v.strip() for k, _, v in
                   (line.partition(":") for line in rest.split("\r\n") if line)}
        if headers.get("sec-websocket-accept") != ws_accept(key):
            raise StepFailed("upgrade answered with a wrong Sec-WebSocket-Accept")

    def _read_until(self, marker: bytes) -> bytes:
        while marker not in self.buffer:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise WsClosed(None, "connection closed")
            self.buffer += chunk
        head, _, self.buffer = self.buffer.partition(marker)
        return head + marker

    def _read_exact(self, count: int) -> bytes:
        while len(self.buffer) < count:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise WsClosed(None, "connection closed")
            self.buffer += chunk
        data, self.buffer = self.buffer[:count], self.buffer[count:]
        return data

    def send_binary(self, payload: bytes) -> None:
        self.sock.sendall(ws_encode(0x2, payload))

    def read_frame(self) -> bytes | None:
        """Read one frame and answer it if it is a ping. Returns a message once it is complete."""
        first, second = self._read_exact(2)
        opcode, fin, length = first & 0x0F, first & 0x80, second & 0x7F
        if length == 126:
            length = struct.unpack(">H", self._read_exact(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", self._read_exact(8))[0]
        mask = self._read_exact(4) if second & 0x80 else None
        payload = self._read_exact(length)
        if mask:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        if opcode == 0x8:
            code = struct.unpack(">H", payload[:2])[0] if len(payload) >= 2 else None
            raise WsClosed(code, payload[2:].decode("utf-8", "replace"))
        if opcode == 0x9:
            self.pings += 1
            self.sock.sendall(ws_encode(0xA, payload))
            return None
        if opcode == 0xA:
            return None
        self.partial += payload
        if not fin:
            return None
        message, self.partial = self.partial, b""
        return message

    def receive(self) -> bytes:
        while True:
            message = self.read_frame()
            if message is not None:
                return message

    def close(self) -> None:
        try:
            self.sock.sendall(ws_encode(0x8, struct.pack(">H", 1000)))
        except OSError:
            pass
        self.sock.close()


def collaboration_auth(ws: WebSocket, document: str, token: str, deadline: float = 15) -> tuple[str, str]:
    """Send the first-frame token and return (verdict, reason).

    HTTP 101 alone proves nothing, because the handshake itself is unauthenticated. Only this
    reply shows that live reached api and api accepted the session.
    """
    ws.send_binary(auth_frame(document, token))
    end = time.monotonic() + deadline
    while time.monotonic() < end:
        frame = ws.receive()
        _, index = read_varstring(frame, 0)
        message_type, index = read_uvarint(frame, index)
        if message_type != HP_MSG_AUTH:
            continue
        verdict, index = read_uvarint(frame, index)
        reason, _ = read_varstring(frame, index)
        return {HP_AUTH_OK: "Authenticated", HP_AUTH_DENIED: "PermissionDenied"}.get(verdict, str(verdict)), reason
    raise StepFailed(f"no auth reply within {deadline}s")


class Collaborator:
    """One authenticated client on one document, doing what a browser tab's provider does."""

    def __init__(self, ws: WebSocket, document: str) -> None:
        self.ws = ws
        self.document = document

    def frames(self, deadline: float):
        """Yield (message type, body) for this document until the deadline, which then fails the step."""
        end = time.monotonic() + deadline
        while time.monotonic() < end:
            self.ws.sock.settimeout(max(0.1, end - time.monotonic()))
            frame = self.ws.receive()
            document, index = read_varstring(frame, 0)
            message_type, index = read_uvarint(frame, index)
            if document == self.document:
                yield message_type, frame[index:]
        raise StepFailed(f"nothing suitable from the server within {deadline}s")

    def first_sync(self, deadline: float = 30) -> bytes:
        """Both halves of the y-sync handshake. Returns the document the server sent.

        Asking with an empty state vector means the answer must be the whole document, which the
        live server can only have loaded from the api with this session's cookie.
        """
        self.ws.send_binary(sync_frame(self.document, Y_SYNC_STEP1, Y_EMPTY_STATE_VECTOR))
        document = None
        answered = False
        for message_type, body in self.frames(deadline):
            if message_type in (HP_MSG_SYNC, HP_MSG_SYNC_REPLY):
                kind, index = read_uvarint(body, 0)
                length, index = read_uvarint(body, index)
                if kind == Y_SYNC_STEP2:
                    document = body[index:index + length]
                elif kind == Y_SYNC_STEP1:
                    # The server asks in turn. This client holds nothing, so it answers with an empty update.
                    self.ws.send_binary(sync_frame(self.document, Y_SYNC_STEP2, Y_EMPTY_UPDATE))
                    answered = True
            elif message_type == HP_MSG_SYNC_STATUS and answered and document is not None:
                return document
        raise AssertionError("unreachable")

    def send_update(self, update: bytes, deadline: float = 15) -> None:
        """Returns once the server acknowledges it. The ack says applied, which a read-only session is not."""
        self.ws.send_binary(sync_frame(self.document, Y_SYNC_UPDATE, update))
        for message_type, body in self.frames(deadline):
            if message_type == HP_MSG_SYNC_STATUS:
                applied, _ = read_uvarint(body, 0)
                if not applied:
                    raise StepFailed("the server refused the update, so this session is read-only")
                return

    def wait_for_update(self, needle: bytes, deadline: float = 15) -> bytes:
        for message_type, body in self.frames(deadline):
            if message_type == HP_MSG_SYNC:
                kind, index = read_uvarint(body, 0)
                length, index = read_uvarint(body, index)
                payload = body[index:index + length]
                if kind == Y_SYNC_UPDATE and needle in payload:
                    return payload
        raise AssertionError("unreachable")


class Cluster:
    """kubectl, for what HTTP cannot show: the broker's queues, the bucket itself, the rollout."""

    def __init__(self, env: str) -> None:
        self.namespace = f"plane-{env}"
        self.application = f"plane-{env}"
        pinned = ROOT / ".tools" / "bin" / "kubectl"
        self.kubectl = str(pinned) if pinned.exists() else "kubectl"
        self.kubeconfig = os.environ.get("KUBECONFIG") or str(LOCAL_DIR / "kubeconfig")
        self.context = os.environ.get("KUBE_CONTEXT") or "kind-plane-platform"
        self.reachable: bool | None = None

    def _call(self, args: tuple[str, ...], timeout: float) -> subprocess.CompletedProcess:
        return subprocess.run([self.kubectl, "--kubeconfig", self.kubeconfig, "--context", self.context, *args],
                              capture_output=True, text=True, timeout=timeout, check=False)

    def run(self, *args: str, timeout: float = 120) -> str:
        if self.reachable is None:
            try:
                self.reachable = self._call(("get", "--raw", "/readyz"), 15).returncode == 0
            except (OSError, subprocess.TimeoutExpired):
                self.reachable = False
        if not self.reachable:
            raise StepBlocked(f"kubectl cannot reach context {self.context}")
        try:
            done = self._call(args, timeout)
        except subprocess.TimeoutExpired as exc:
            raise StepFailed(f"kubectl {args[0]} did not finish within {timeout}s") from exc
        if done.returncode != 0:
            raise StepFailed(f"kubectl {' '.join(args[:4])} exited {done.returncode}: {done.stderr.strip()[:300]}")
        return done.stdout

    def in_namespace(self, *args: str, timeout: float = 120) -> str:
        return self.run("-n", self.namespace, *args, timeout=timeout)

    def queues(self) -> dict:
        output = self.in_namespace("exec", "plane-rabbitmq-wl-0", "--", "rabbitmqctl", "-q", "list_queues",
                                   "name", "messages", "consumers", "--formatter", "json")
        return {queue["name"]: queue for queue in json.loads(output)}

    def celery_control(self, *args: str) -> str:
        return self.in_namespace("exec", "deploy/plane-worker-wl", "--", "celery", "-A", "plane", "control",
                                 "-t", "15", *args)

    def worker_log(self) -> str:
        """The running container's log, which starts again with each new container and so each new selection."""
        return self.in_namespace("logs", "deploy/plane-worker-wl", "--tail=-1")

    def deployments(self) -> dict:
        listed = json.loads(self.in_namespace("get", "deployments", "-o", "json"))
        return {item["metadata"]["name"]: item for item in listed["items"]}

    def silo_object(self, key: str) -> dict:
        output = self.in_namespace("exec", "deploy/plane-api-wl", "--", "python", "-c", SILO_PROBE, key)
        return json.loads(output.strip().splitlines()[-1])


# --- Local state ---------------------------------------------------------------------------------


def read_credentials() -> tuple[str, str]:
    """Two lines on stdin, so neither reaches an argv or an environment."""
    email = sys.stdin.readline().rstrip("\n")
    password = sys.stdin.readline().rstrip("\n")
    return email, password


def write_private(path: Path, content: str) -> None:
    """Write through a 0600 temp file, so the secret is never briefly world-readable."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temp_name = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            handle.write(content)
        os.replace(temp_name, path)
    except BaseException:
        if os.path.exists(temp_name):
            os.unlink(temp_name)
        raise


class Accounts:
    """KEY=value file holding generated test credentials for both environments.

    One file for both, and scripts and the load test read it, so a write takes a lock and reads the file again.
    Without that, a smoke in the other environment that started first would write back what it read then, and
    this run's new token would be gone. A reader needs no lock, because write_private replaces the file whole.
    """

    def __init__(self, path: Path, env: str) -> None:
        self.path = path
        self.prefix = "PLANE_" + env.upper().replace("-", "_") + "_"
        self.values = self._read()

    def _read(self) -> dict[str, str]:
        values: dict[str, str] = {}
        if self.path.exists():
            if self.path.stat().st_mode & 0o077:
                os.chmod(self.path, 0o600)
            for line in self.path.read_text().splitlines():
                key, separator, value = line.partition("=")
                if separator and not key.startswith("#"):
                    values[key] = value
        return values

    def get(self, key: str) -> str | None:
        return self.values.get(self.prefix + key)

    def set(self, **pairs: str | None) -> None:
        """Writes each pair, and None removes that key."""
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        # A file of its own, because write_private replaces the credentials file, and a lock held on the
        # replaced file would no longer exclude anyone. The kernel drops it if this process dies.
        descriptor = os.open(self.path.parent / f".{self.path.name}.lock", os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            self.values = self._read()
            for key, value in pairs.items():
                if value is None:
                    self.values.pop(self.prefix + key, None)
                else:
                    self.values[self.prefix + key] = value
            lines = ["# Generated by tests/e2e/smoke.py. Test credentials only. Never commit."]
            lines += [f"{key}={value}" for key, value in sorted(self.values.items())]
            write_private(self.path, "\n".join(lines) + "\n")
        finally:
            os.close(descriptor)


# --- What Git says about an environment's images ---------------------------------------------------


def overlay_path(env: str) -> Path:
    return ROOT / "helm" / "plane" / "overlays" / env / "kustomization.yaml"


def parse_overlay_images(text: str) -> dict[str, dict[str, str]]:
    """The images: list of a kustomization, by the name the chart renders. Standard library only, so no YAML
    parser: `make promote` writes this list as kustomize sorts it, one key per line."""
    _, _, listed = text.partition("\nimages:\n")
    entries = {}
    for block in re.split(r"^- ", listed, flags=re.M):
        fields = dict(re.findall(r"^\s*(\w+):\s*(\S+)\s*$", block, flags=re.M))
        if "name" in fields:
            entries[fields["name"]] = fields
    return entries


def branded_images(text: str) -> dict[str, dict[str, str]]:
    """Which Wayline images a kustomization names, by component (web, admin, space, backend)."""
    branded = {}
    for entry in parse_overlay_images(text).values():
        match = BRANDED_REPOSITORY.match(entry.get("newName", ""))
        if match:
            branded[match.group(1)] = entry
    return branded


def rollout_unfinished(deployment: dict) -> str | None:
    """Why pods of an older template may still be serving, or why the new ones may not be yet. None if neither.
    The spec names what should run, and only these fields say it does. kubectl rollout status reads the same ones and not
    terminatingReplicas, but status.replicas leaves out a pod being terminated, and that pod can still get requests during
    its preStop sleep. A Kubernetes without that field reads as none terminating."""
    spec, status = deployment.get("spec", {}), deployment.get("status", {})
    wanted = spec.get("replicas", 1)
    observed, generation = status.get("observedGeneration", 0), deployment.get("metadata", {}).get("generation", 0)
    if observed < generation:
        return f"the controller has read generation {observed} of {generation}"
    updated, replicas, available = status.get("updatedReplicas", 0), status.get("replicas", 0), status.get("availableReplicas", 0)
    if updated != wanted:
        return f"{updated} of {wanted} replicas have the new template"
    if replicas != updated:
        return f"{replicas - updated} old replicas are still there"
    terminating = status.get("terminatingReplicas") or 0
    if terminating > 0:
        return f"{terminating} replicas are still terminating"
    if available != updated:
        return f"{available} of {updated} new replicas are available"
    return None


def rollout_under_way(workload: dict) -> bool:
    """Whether the controller says it is still moving this workload to a new template. A rollout past its deadline reads
    ProgressDeadlineExceeded, and a pod lost after a finished one keeps NewReplicaSetAvailable, and neither of those will
    end by waiting. So this is narrower than rollout_unfinished, which is true of both."""
    status = workload.get("status", {})
    if status.get("observedGeneration", 0) < workload.get("metadata", {}).get("generation", 0):
        return True
    if workload.get("kind") == "StatefulSet":
        return status.get("updateRevision") != status.get("currentRevision")
    progressing = next((c for c in status.get("conditions", []) if c.get("type") == "Progressing"), {})
    return progressing.get("status") == "True" and progressing.get("reason") != "NewReplicaSetAvailable"


def sync_failing(application: dict) -> str | None:
    """Why an Application's open sync will not end by waiting, or None. Every Application here sets retry.limit: -1, so a
    sync that fails every attempt never closes: the controller sets each failed attempt back to phase Running and counts it
    in retryCount. An operation about to replace a finished one still shows that one's count, so this reads the phase too."""
    state = application.get("status", {}).get("operationState", {})
    attempts = state.get("retryCount") or 0
    if state.get("phase") != "Running" or attempts <= 0:
        return None
    return f"its sync has failed {attempts} time(s) and is retrying: {state.get('message') or 'with no message'}"


def job_failed(job: dict) -> bool:
    return any(c.get("type") == "Failed" and c.get("status") == "True" for c in job.get("status", {}).get("conditions", []))


def parse_time(text: str) -> dt.datetime:
    """Kubernetes and this script write a trailing Z, which fromisoformat does not read before Python 3.11."""
    return dt.datetime.fromisoformat(text.replace("Z", "+00:00"))


def configured_source_repo() -> str:
    """Where /source points. The Dockerfile holds the default, and scripts/ci/build-images.sh passes the same variable."""
    override = os.environ.get("WAYLINE_SOURCE_REPO")
    if override:
        return override
    dockerfile = (ROOT / "apps" / "wayline" / "runtime" / "Dockerfile.web").read_text()
    match = re.search(r"^ARG WAYLINE_SOURCE_REPO=(\S+)$", dockerfile, flags=re.M)
    if not match:
        raise StepBlocked("apps/wayline/runtime/Dockerfile.web no longer sets WAYLINE_SOURCE_REPO")
    return match.group(1)


def git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True, timeout=30, check=False)


def branded_backend_since(env: str) -> dt.datetime | None:
    """When the Wayline backend first reached this environment's overlay. An instance registered earlier was
    registered by upstream's image. None if Git cannot say, including if it never has."""
    try:
        done = git("log", "--reverse", "--format=%ct", "-S", "localhost:5001/wayline/backend", "--",
                   str(overlay_path(env).relative_to(ROOT)))
    except (OSError, subprocess.TimeoutExpired):
        return None
    lines = done.stdout.split() if done.returncode == 0 else []
    return dt.datetime.fromtimestamp(int(lines[0]), dt.timezone.utc) if lines else None


def page_title(html: str) -> str:
    match = re.search(r"<title[^>]*>(.*?)</title>", html, flags=re.S | re.I)
    return match.group(1).strip() if match else ""


def brand_problems(path: str, html: str) -> list[str]:
    """What is wrong with a served page: its title must name Wayline and not upstream, and the rest of it
    may name upstream only in the one permitted credit."""
    problems = []
    title = page_title(html)
    if "Wayline" not in title:
        problems.append(f"{path} title does not name Wayline: {title!r}")
    if UPSTREAM_NAME.search(title):
        problems.append(f"{path} title names upstream as the product: {title!r}")
    leaks = [hit.group(0) for hit in re.finditer(r".{0,30}(?:" + UPSTREAM_BRAND.pattern + r").{0,30}", html)
             if PERMITTED_CREDIT not in hit.group(0)]
    if leaks:
        problems.append(f"{path} carries the upstream brand {len(leaks)} time(s), first: {leaks[0]!r}")
    return problems


# --- The run -------------------------------------------------------------------------------------


class Smoke:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.host = args.host or HOSTS[args.env]
        connect_host, _, connect_port = args.connect.partition(":")
        self.connect_host = connect_host
        self.connect_port = int(connect_port or 80)
        self.tls = hosted_tls(args) if args.env == HOSTED else None
        self.http = Http(self.host, self.connect_host, self.connect_port, tls=self.tls)
        self.cluster = Cluster(args.env)
        self.redact = Redactor()
        self.accounts = Accounts(Path(args.accounts), args.env)
        self.redact.add(self.accounts.get("ADMIN_PASSWORD"))
        self.redact.add(self.accounts.get("ADMIN_PASSWORD_PENDING"))
        self.redact.add(ADMIN_EMAIL)
        self.redact.add(self.accounts.get("ADMIN_EMAIL"))
        self.redact.add(self.accounts.get("API_TOKEN"))
        self.credentials = read_credentials() if args.env == HOSTED and args.credentials_stdin else ("", "")
        self.redact.add(self.credentials[0])
        self.redact.add(self.credentials[1])
        self.sentinel_path = Path(args.sentinel or LOCAL_DIR / f"test-sentinel-{args.env}.json")
        self.run_id = secrets.token_hex(4)
        self.steps: list[dict] = []
        self.passed: set[str] = set()
        self.state: dict = {}
        self.deadline_seconds = args.wait_seconds

    # -- framework --

    def run(self, name: str, function, requires: tuple[str, ...] = ()) -> None:
        missing = [r for r in requires if r not in self.passed]
        started = time.monotonic()
        data: dict = {}
        try:
            if missing:
                raise StepBlocked("needs " + ", ".join(missing))
            detail = function(data) or ""
            status = "PASS"
            self.passed.add(name)
        except StepBlocked as exc:
            status, detail = "BLOCKED", str(exc)
        except StepSkipped as exc:
            status, detail = "SKIP", str(exc)
        except StepFailed as exc:
            status, detail = "FAIL", str(exc)
        except (OSError, http.client.HTTPException, WsClosed, ValueError, KeyError, TypeError, IndexError) as exc:
            status, detail = "FAIL", f"{type(exc).__name__}: {exc}"
        detail = self.redact(str(detail))
        duration_ms = int((time.monotonic() - started) * 1000)
        print(f"{status:<8}{name}" + (f"  {detail}" if detail else ""), flush=True)
        self.steps.append({"name": name, "status": status, "detail": detail, "duration_ms": duration_ms,
                           "data": json.loads(self.redact(json.dumps(data)))})

    def overall(self) -> str:
        statuses = {step["status"] for step in self.steps}
        if "FAIL" in statuses:
            return "FAIL"
        if "BLOCKED" in statuses or not statuses:
            return "BLOCKED"
        return "PASS"

    def write_evidence(self, started_at: str) -> None:
        counts = {s: sum(1 for step in self.steps if step["status"] == s) for s in ("PASS", "FAIL", "BLOCKED", "SKIP")}
        document = {
            "tool": "tests/e2e/smoke.py",
            "environment": self.args.env,
            "host": self.host,
            "mode": self.args.mode,
            "run_id": self.run_id,
            "started_at": started_at,
            "finished_at": now_iso(),
            "result": self.overall(),
            "counts": counts,
            "steps": self.steps,
        }
        path = Path(self.args.evidence or LOCAL_DIR / "evidence-raw" / f"smoke-{self.args.env}-{self.run_id}.json")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.redact(json.dumps(document, indent=2, sort_keys=True)) + "\n")
        print(f"evidence: {path}", flush=True)

    def retrying_get(self, target: str, **kwargs) -> Response:
        """Tolerate a backend that is restarting. Used on reads only, so retries are harmless."""
        end = time.monotonic() + self.deadline_seconds
        last = "no attempt"
        while True:
            try:
                response = self.http.get(target, **kwargs)
                if response.status not in (429, 502, 503, 504):
                    return response
                last = f"HTTP {response.status}"
                pause = float(response.headers.get("Retry-After") or 5)
            except (OSError, http.client.HTTPException) as exc:
                last, pause = type(exc).__name__, 5
            if time.monotonic() + pause > end:
                raise StepFailed(f"{target.split('?')[0]} not available after {self.deadline_seconds}s: {last}")
            time.sleep(min(pause, 15))

    def csrf(self, client: Http | None = None) -> str:
        """The cookie is HttpOnly in a browser, so the token comes from this endpoint."""
        client = client or self.http
        response = expect(client.get("/auth/get-csrf-token/"), 200)
        token = response.json().get("csrf_token")
        if not token or "csrftoken" not in client.cookies:
            raise StepFailed("no csrf_token in the body, or no csrftoken cookie set")
        return token

    def api(self) -> dict:
        token = self.state.get("api_token") or self.accounts.get("API_TOKEN")
        if not token:
            raise StepBlocked("no API token available")
        return {"X-API-Key": token}

    def base(self) -> str:
        return f"/api/v1/workspaces/{self.state['slug']}/projects/{self.state['project_id']}"

    def create_workspace(self, name: str, slug: str) -> None:
        response = self.http.send_json("POST", "/api/workspaces/",
                                       {"name": name, "slug": slug, "organization_size": "1-10"})
        expect(response, 201)

    def instance_now(self, reading: str) -> dict:
        """What /api/instances/ says now, read by a key nothing else fills. Upstream caches that route in Valkey for two
        hours, by full path and for everyone, and the blackbox probe and every browser read the bare path. So that key can
        hold what the previous image answered: a new api pod clears the cache as it starts, the old pod serves until the
        new one is Ready, and a probe refills the key from it. It can also hold what a probe read during an admin sign-up,
        because upstream invalidates the key before that view runs and not after. A query only this reading sends misses
        all of that, at the cost of one more key that expires in two hours."""
        return expect(self.retrying_get(f"/api/instances/?smoke={self.run_id}-{reading}", session=False), 200).json()

    # -- steps --

    def step_reachable(self, data: dict) -> str:
        web = self.retrying_get("/", session=False)
        expect(web, 200)
        instance = self.retrying_get("/api/instances/", session=False)
        expect(instance, 200)
        payload = instance.json()
        # What the bare path says, which instance-setup replaces with a reading that cannot be stale.
        self.state["instance"] = payload.get("instance", payload)
        data["web_status"], data["instances_status"] = web.status, instance.status
        return f"web 200, /api/instances/ 200 via {self.host}"

    def step_frontends(self, data: dict) -> str:
        """A 200 for the HTML says little: nginx falls back to it for any path. So fetch what it names."""
        for label, path in (("web", "/"), ("admin", "/god-mode/"), ("space", "/spaces/")):
            page = expect(self.http.get(path, session=False, headers={"Accept": "text/html"}), 200)
            html = page.body.decode("utf-8", "replace")
            assets = sorted(set(re.findall(r'(?:src|href)="(/[^"]*assets/[^"]+\.(?:js|css))"', html)))
            if not assets:
                raise StepFailed(f"{label}: {path} names no script or stylesheet, so it is not the app's page")
            for asset in assets[:6]:
                fetched = expect(self.http.get(asset, session=False, headers={"Accept": "*/*"}), 200)
                content_type = fetched.headers.get("Content-Type", "")
                if "javascript" not in content_type and "css" not in content_type:
                    raise StepFailed(f"{label}: {asset} came back as {content_type}, so the route is wrong")
            data[label] = len(assets)
        return "web, admin and space pages and the assets they name are served"

    def step_routes(self, data: dict) -> str:
        """The chart has no redirect for the bare paths, and the path-style presigned POST needs /uploads."""
        for target, want in (("/god-mode", "/god-mode/"), ("/spaces", "/spaces/"), ("/spaces?x=1", "/spaces/?x=1")):
            response = self.http.get(target, session=False)
            where = urlsplit(response.location)
            got = where.path + (f"?{where.query}" if where.query else "")
            if response.status not in (301, 308) or got != want or where.netloc != self.host:
                raise StepFailed(f"{target} answered {response.status} to {response.location!r}, want a redirect to {want}")
        deep = expect(self.http.get("/god-mode/general/", session=False, headers={"Accept": "text/html"}), 200)
        if b"/god-mode/assets/" not in deep.body:
            raise StepFailed("/god-mode/general/ was not served by admin")
        health = expect(self.http.get("/live/health", session=False), 200).json()
        data["live_health"] = health
        return "bare paths redirect, deep links reach admin, /live/health answers"

    def step_workloads(self, data: dict) -> str:
        """FAIL for what will not end by waiting, and BLOCKED for what a rollout or an open sync explains, which says nothing
        yet either way. An open sync that has failed an attempt explains nothing. tests/separation's require_environments
        reads a rollout the same way."""
        listed = json.loads(self.cluster.in_namespace("get", "deployments,statefulsets,jobs", "-o", "json"))
        items = {(item["kind"], item["metadata"]["name"]): item for item in listed["items"]}
        app = json.loads(self.cluster.run("-n", "argocd", "get", "application", self.cluster.application, "-o", "json"))
        sync_open = bool(app.get("operation")) or app["status"].get("operationState", {}).get("phase") == "Running"
        problems, under_way = [], []
        for kind, name in WORKLOADS:
            item = items.get((kind, name))
            if item is None:
                problems.append(f"{kind} {name} is missing")
                continue
            ready, wanted = item["status"].get("readyReplicas", 0), item["spec"].get("replicas", 1)
            if ready != wanted:
                (under_way if rollout_under_way(item) else problems).append(f"{name} has {ready}/{wanted} ready")
        job = items.get(("Job", MIGRATOR_JOB))
        if job is None or not job["status"].get("succeeded"):
            # An open sync runs this hook again, and the Job is replaced each time. One that has failed is done, though.
            (under_way if sync_open and not (job and job_failed(job)) else problems).append(f"Job {MIGRATOR_JOB} has not succeeded")
        pods = json.loads(self.cluster.in_namespace("get", "pods", "-o", "json"))["items"]
        data["restarts"] = {
            pod["metadata"]["name"]: status["restartCount"]
            for pod in pods for status in pod["status"].get("containerStatuses", []) if status["restartCount"]
        }
        data["application"] = f"{app['status']['sync']['status']}/{app['status']['health']['status']}"
        if data["application"] != "Synced/Healthy":
            moving = sync_open or any(rollout_under_way(item) for (kind, _), item in items.items() if kind != "Job")
            finished_badly = app["status"]["health"]["status"] in ("Degraded", "Missing")
            (under_way if moving and not finished_badly else problems).append(f"Application {self.cluster.application} is {data['application']}")
        failing = sync_failing(app)
        if failing:
            problems.append(f"Application {self.cluster.application}: {failing}")
        if problems:
            raise StepFailed("; ".join(problems + under_way))
        if under_way:
            raise StepBlocked("a rollout is under way, so this says nothing yet, and this run cannot read PASS: " + "; ".join(under_way))
        return f"{len(WORKLOADS)} workloads ready, migrator succeeded, Application {data['application']}, " \
               f"pods that have restarted: {len(data['restarts'])}"

    def step_instance_setup(self, data: dict) -> str:
        # Not what reachable read. A stale false would send this to a sign-up that can only be refused.
        found = self.instance_now("before-setup")
        instance = self.state["instance"] = found.get("instance", found)
        data["was_setup_done"] = bool(instance.get("is_setup_done"))
        if instance.get("is_setup_done"):
            self.settle_pending_admin(data)
            if not (self.accounts.get("ADMIN_EMAIL") and self.accounts.get("ADMIN_PASSWORD")):
                raise StepBlocked(
                    "instance is already set up and .local/test-accounts.env has no credentials for it. "
                    "Admin sign-up is one-shot, so restore that file or reset this environment."
                )
            return "already set up, reusing stored admin"

        token = self.csrf()
        password = secrets.token_hex(24)
        self.redact.add(password)
        # Beside what is stored, not over it, until the answer is known. Sign-up is one-shot, so a crash right after it must
        # not lose this password, and a refusal must not lose the one the database still holds.
        self.accounts.set(ADMIN_PASSWORD_PENDING=password)
        pending = f"its password stays pending in {self.accounts.path.name}, and the next run settles it"

        # Telemetry defaults to on and reports to telemetry.plane.so. The UI always submits true,
        # so only this path can turn it off at creation.
        try:
            response = self.http.post_form("/api/instances/admins/sign-up/", {
                "csrfmiddlewaretoken": token, "email": ADMIN_EMAIL, "password": password,
                "first_name": "Smoke", "last_name": "Admin", "company_name": "Wayline",
                "is_telemetry_enabled": "False",
            })
        except (OSError, http.client.HTTPException) as exc:
            raise StepFailed(f"the sign-up got no answer ({type(exc).__name__}), so it may have gone through: {pending}") from exc
        # Form endpoints always answer 302, and report failure only in the Location query string.
        try:
            expect(response, 302)
            self.assert_no_auth_error(response)
        except StepFailed as exc:
            # A 5xx says nothing: the view commits the admin before it writes the session.
            if response.status >= 500:
                raise StepFailed(f"{exc}. That does not say whether the sign-up went through: {pending}") from exc
            self.accounts.set(ADMIN_PASSWORD_PENDING=None)
            raise StepFailed(f"{exc}. The sign-up was refused, so {self.accounts.path.name} keeps what it held") from exc
        if not urlsplit(response.location).path.endswith("/god-mode/general/"):
            raise StepFailed(f"unexpected redirect target: {urlsplit(response.location).path}, and {pending}")
        if "admin-session-id" not in self.http.cookies:
            raise StepFailed(f"sign-up did not set admin-session-id, and {pending}")
        self.accounts.set(ADMIN_EMAIL=ADMIN_EMAIL, ADMIN_PASSWORD=password, ADMIN_PASSWORD_PENDING=None)

        # Not the bare path, which a probe during that POST can have filled with the false from before it.
        after = self.instance_now("after-setup")
        after = after.get("instance", after)
        if not after.get("is_setup_done"):
            raise StepFailed("is_setup_done is still false after admin sign-up")
        data["is_telemetry_enabled"] = after.get("is_telemetry_enabled")
        if after.get("is_telemetry_enabled") is not False:
            raise StepFailed(f"telemetry should be off, instance reports {after.get('is_telemetry_enabled')!r}")
        return "admin created, telemetry off"

    def settle_pending_admin(self, data: dict) -> None:
        """A run saved a password and stopped before it learned what its sign-up did. This instance has an admin, so either
        that sign-up made it and this is the only copy of its password, or it did not and this is worth nothing. Only a
        sign-in can tell. A refusal for any other reason settles nothing, so the password stays."""
        pending = self.accounts.get("ADMIN_PASSWORD_PENDING")
        if not pending:
            return
        admin = Http(self.host, self.connect_host, self.connect_port)
        response = expect(admin.post_form("/api/instances/admins/sign-in/", {
            "csrfmiddlewaretoken": self.csrf(admin), "email": ADMIN_EMAIL, "password": pending,
        }), 302)
        refused = parse_qs(urlsplit(response.location).query).get("error_message", [""])[0]
        if not refused and "admin-session-id" in admin.cookies:
            self.redact.add(admin.cookies["admin-session-id"])
            self.accounts.set(ADMIN_EMAIL=ADMIN_EMAIL, ADMIN_PASSWORD=pending, ADMIN_PASSWORD_PENDING=None)
            data["pending_admin"] = "its sign-up had gone through, so it is the stored admin now"
        elif refused in ("ADMIN_AUTHENTICATION_FAILED", "ADMIN_USER_DOES_NOT_EXIST"):
            self.accounts.set(ADMIN_PASSWORD_PENDING=None)
            data["pending_admin"] = f"its sign-up had not gone through ({refused}), so it was dropped"
        else:
            raise StepFailed(f"could not tell whether an earlier sign-up went through: admin sign-in said {refused or 'no session'!r}")

    @staticmethod
    def assert_no_auth_error(response: Response) -> None:
        query = parse_qs(urlsplit(response.location).query)
        if "error_code" in query:
            raise StepFailed(f"auth error {query['error_code'][0]} {query.get('error_message', [''])[0]}")

    def step_csrf_enforced(self, data: dict) -> str:
        # A bare client with no cookie and no token must be refused by the middleware, before the
        # view runs, so this does not spend the 10/min auth throttle. Plane's csrf_failure view
        # renders its page with no status argument, so the refusal is HTTP 200, not 403. The page
        # title and the missing redirect are the signal.
        response = self.http.request("POST", "/auth/sign-in/", session=False,
                                     headers={"Content-Type": "application/x-www-form-urlencoded"},
                                     body=b"email=nobody%40wayline.test&password=x")
        data["status"] = response.status
        if response.status == 302 or CSRF_FAILURE_TITLE not in response.body:
            raise StepFailed(f"sign-in without a CSRF token was not refused: HTTP {response.status}")
        return f"sign-in without a CSRF token is refused (HTTP {response.status}, Plane's CSRF page)"

    def step_sign_in(self, data: dict) -> str:
        # Admin sign-up gives admin-session-id only. The app needs its own session-id.
        response = self.http.post_form("/auth/sign-in/", {
            "csrfmiddlewaretoken": self.csrf(),
            "email": self.accounts.get("ADMIN_EMAIL"),
            "password": self.accounts.get("ADMIN_PASSWORD"),
        })
        expect(response, 302)
        self.assert_no_auth_error(response)
        if "session-id" not in self.http.cookies:
            raise StepFailed("sign-in did not set session-id")
        self.redact.add(self.http.cookies["session-id"])
        anonymous = self.http.get("/api/users/me/", session=False)
        data["anonymous_me_status"] = anonymous.status
        if anonymous.status == 200:
            raise StepFailed("/api/users/me/ answered 200 with no session")
        me = expect(self.http.get("/api/users/me/"), 200).json()
        self.state["user_id"] = me["id"]
        data["user_id"] = me["id"]
        return "session established, anonymous request refused"

    def step_workspace(self, data: dict) -> str:
        slug = f"smoke-{self.run_id}"
        self.create_workspace(f"Smoke {self.run_id}", slug)
        self.state["slug"] = slug
        self.state["workspace_name"] = f"Smoke {self.run_id}"
        data["slug"] = slug
        return slug

    def step_api_token(self, data: dict) -> str:
        response = self.http.send_json("POST", "/api/users/api-tokens/",
                                       {"label": f"smoke-{self.run_id}", "description": "tests/e2e/smoke.py"})
        token = expect(response, 201).json().get("token")
        if not token:
            raise StepFailed("response has no token")
        self.redact.add(token)
        self.state["api_token"] = token
        self.accounts.set(API_TOKEN=token)
        me = expect(self.http.get("/api/v1/users/me/", session=False, headers=self.api()), 200).json()
        if me.get("id") != self.state["user_id"]:
            raise StepFailed("/api/v1/users/me/ returned another user")
        anonymous = self.http.get("/api/v1/users/me/", session=False)
        data["anonymous_status"] = anonymous.status
        if anonymous.status == 200:
            raise StepFailed("/api/v1/users/me/ answered 200 with no key")
        return "token works on /api/v1, refused without it"

    def create_project(self, slug: str, label: str) -> dict:
        # Not the first five letters of the workspace name: the workspace_seed task takes that
        # identifier for itself and would race this request.
        identifier = "P" + secrets.token_hex(3).upper()
        response = self.http.send_json("POST", f"/api/v1/workspaces/{slug}/projects/",
                                       {"name": f"{label} {identifier}", "identifier": identifier},
                                       session=False, headers=self.api())
        return expect(response, 201).json()

    def create_work_item(self, base: str, name: str) -> str:
        response = self.http.send_json("POST", f"{base}/work-items/", {"name": name},
                                       session=False, headers=self.api())
        return expect(response, 201).json()["id"]

    def step_project(self, data: dict) -> str:
        project = self.create_project(self.state["slug"], "Platform")
        self.state["project_id"] = project["id"]
        self.state["project"] = project
        data["project_id"] = self.state["project_id"]
        return self.state["project_id"]

    def step_work_item(self, data: dict) -> str:
        self.state["work_item_name"] = f"smoke {self.run_id}"
        self.state["work_item_id"] = self.create_work_item(self.base(), self.state["work_item_name"])
        data["work_item_id"] = self.state["work_item_id"]
        return self.state["work_item_id"]

    def step_list(self, data: dict) -> str:
        results = expect(self.http.get(f"{self.base()}/work-items/", session=False, headers=self.api()), 200).json()
        ids = [item["id"] for item in results.get("results", [])]
        data["listed"] = len(ids)
        if self.state["work_item_id"] not in ids:
            raise StepFailed(f"new work item missing from the list of {len(ids)}")
        return f"new work item is among {len(ids)} listed"

    def step_read_back(self, data: dict) -> str:
        """By id, and compared field by field: a 201 and a list entry do not show what was stored."""
        slug, project, item_id = self.state["slug"], self.state["project"], self.state["work_item_id"]
        workspace = expect(self.http.get(f"/api/workspaces/{slug}/"), 200).json()
        if (workspace.get("slug"), workspace.get("name")) != (slug, self.state["workspace_name"]):
            raise StepFailed("workspace read back with a different slug or name")
        stored = expect(self.http.get(self.base() + "/", session=False, headers=self.api()), 200).json()
        if (stored.get("name"), stored.get("identifier")) != (project["name"], project["identifier"]):
            raise StepFailed("project read back with a different name or identifier")
        item = expect(self.http.get(f"{self.base()}/work-items/{item_id}/", session=False, headers=self.api()), 200).json()
        if item.get("name") != self.state["work_item_name"] or item.get("project") != project["id"]:
            raise StepFailed("work item read back with a different name or project")
        # The route the web app uses, with a session rather than a key.
        browser = expect(self.http.get(f"/api/workspaces/{slug}/projects/{project['id']}/issues/{item_id}/"), 200).json()
        if browser.get("name") != self.state["work_item_name"]:
            raise StepFailed("the session route returned a different work item")
        data.update(sequence_id=item.get("sequence_id"), state=item.get("state"))
        return f"workspace, project and work item {project['identifier']}-{item.get('sequence_id')} all match, by key and by session"

    def step_workspace_seed(self, data: dict) -> str:
        """workspace_seed runs in the worker, and creates a project named after the workspace."""
        slug, name = self.state["slug"], self.state["workspace_name"]
        started = time.monotonic()
        while time.monotonic() - started < self.args.job_timeout:
            projects = expect(self.http.get(f"/api/workspaces/{slug}/projects/"), 200).json()
            projects = projects.get("results", projects) if isinstance(projects, dict) else projects
            if any(project.get("name") == name for project in projects):
                data["seconds_until_seeded"] = round(time.monotonic() - started, 1)
                return f"seed project present after {data['seconds_until_seeded']}s"
            time.sleep(2)
        raise StepFailed(f"no seed project after {self.args.job_timeout}s")

    def step_app_shell(self, data: dict) -> str:
        """What the web app asks for right after sign-in, since the sign-in page itself proves none of it."""
        slug, project_id = self.state["slug"], self.state["project_id"]
        workspace, project = f"/api/workspaces/{slug}", f"/api/workspaces/{slug}/projects/{project_id}"
        targets = ["/api/users/me/profile/", "/api/users/me/settings/", "/api/users/me/workspaces/",
                   f"{workspace}/workspace-members/me/", f"{workspace}/user-properties/", f"{workspace}/projects/details/",
                   f"{workspace}/sidebar-preferences/", f"{workspace}/views/", f"{workspace}/members/",
                   f"{project}/", f"{project}/states/", f"{project}/issue-labels/", f"{project}/members/",
                   f"{project}/user-properties/", f"{project}/issues/?per_page=50&cursor=50:0:0&group_by=state_id"]
        statuses = {target: self.http.get(target).status for target in targets}
        failed = {target: status for target, status in statuses.items() if status != 200}
        data["checked"] = len(statuses)
        if failed:
            raise StepFailed(f"{failed}")
        return f"all {len(statuses)} requests answered 200"

    def step_admin_sign_in(self, data: dict) -> str:
        """The god-mode session and its config rows. Those are encrypted with a key derived from
        SECRET_KEY, and a wrong key decrypts silently to an empty string, so a value must survive."""
        admin = Http(self.host, self.connect_host, self.connect_port)
        anonymous = admin.get("/api/instances/configurations/").status
        response = admin.post_form("/api/instances/admins/sign-in/", {
            "csrfmiddlewaretoken": self.csrf(admin),
            "email": self.accounts.get("ADMIN_EMAIL"),
            "password": self.accounts.get("ADMIN_PASSWORD"),
        })
        expect(response, 302)
        self.assert_no_auth_error(response)
        if "admin-session-id" not in admin.cookies:
            raise StepFailed("admin sign-in did not set admin-session-id")
        self.redact.add(admin.cookies["admin-session-id"])
        me = expect(admin.get("/api/instances/admins/me/"), 200).json()
        rows = expect(admin.get("/api/instances/configurations/"), 200).json()
        by_key = {row["key"]: row for row in rows}
        data.update(anonymous_status=anonymous, rows=len(rows), encrypted_rows=sum(1 for row in rows if row.get("is_encrypted")))
        if anonymous == 200:
            raise StepFailed("instance configuration answered 200 with no admin session")
        if by_key.get("ENABLE_EMAIL_PASSWORD", {}).get("value") != "1":
            raise StepFailed("ENABLE_EMAIL_PASSWORD did not read back as 1")
        if not me.get("id"):
            raise StepFailed("/api/instances/admins/me/ has no id")
        return f"{len(rows)} config rows read, {data['encrypted_rows']} of them encrypted, refused with no session ({anonymous})"

    def step_second_user(self, data: dict) -> str:
        """A normal sign-up, with its own session, is refused the first user's workspace."""
        other = Http(self.host, self.connect_host, self.connect_port)
        email, password = f"smoke-user-{self.run_id}@wayline.test", secrets.token_hex(24)
        self.redact.add(email)
        self.redact.add(password)
        response = other.post_form("/auth/sign-up/", {"csrfmiddlewaretoken": self.csrf(other), "email": email,
                                                      "password": password})
        expect(response, 302)
        self.assert_no_auth_error(response)
        if "session-id" not in other.cookies:
            raise StepFailed("sign-up did not set session-id")
        self.redact.add(other.cookies["session-id"])
        me = expect(other.get("/api/users/me/"), 200).json()
        if me.get("id") == self.state["user_id"] or me.get("email") != email:
            raise StepFailed("the new session is not the new user")
        slug, project_id = self.state["slug"], self.state["project_id"]
        denied = {
            "workspace": other.get(f"/api/workspaces/{slug}/").status,
            "work_item": other.get(f"/api/workspaces/{slug}/projects/{project_id}/issues/{self.state['work_item_id']}/").status,
        }
        data["statuses"] = denied
        if any(status == 200 for status in denied.values()):
            raise StepFailed(f"another user could read this workspace: {denied}")
        return f"sign-up works, and that user is refused this workspace: {denied}"

    def step_consumers(self, data: dict) -> str:
        queues = self.cluster.queues()
        celery = queues.get("celery")
        if celery is None:
            raise StepFailed(f"no queue named celery, only {sorted(queues)}")
        data.update(celery_consumers=celery["consumers"], celery_messages=celery["messages"], queues=sorted(queues))
        if celery["consumers"] < 1:
            raise StepFailed("queue celery has 0 consumers, so nothing runs background jobs")
        return f"queue celery has {celery['consumers']} consumer, {celery['messages']} waiting"

    def step_broker_memory(self, data: dict) -> str:
        """The conf.d watermark, from the running broker. Its total is the VM, not the cgroup limit."""
        rabbit = ("exec", "plane-rabbitmq-wl-0", "--")
        watermark = self.cluster.in_namespace(*rabbit, "rabbitmqctl", "-q", "eval",
                                              "vm_memory_monitor:get_vm_memory_high_watermark().").strip()
        limit = int(self.cluster.in_namespace(*rabbit, "rabbitmqctl", "-q", "eval",
                                              "vm_memory_monitor:get_memory_limit().").strip())
        alarms = self.cluster.in_namespace(*rabbit, "rabbitmq-diagnostics", "-q", "alarms").strip()
        data.update(watermark=watermark, limit_bytes=limit, alarms=alarms)
        if limit != 256 * 1024 * 1024:
            raise StepFailed(f"watermark is {watermark} = {limit} bytes, want an absolute 256Mi")
        if "no alarms" not in alarms:
            raise StepFailed(f"the broker reports alarms: {alarms}")
        return f"watermark {watermark} = {limit} bytes, no alarms"

    def activity_count(self, base: str, work_item_id: str) -> int:
        target = f"{base}/work-items/{work_item_id}/activities/"
        results = expect(self.http.get(target, session=False, headers=self.api()), 200).json().get("results", [])
        return sum(1 for activity in results if activity.get("verb") == "created")

    def replace_worker(self, data: dict) -> None:
        """Why the control ends in a new pod: cancel_consumer empties Celery's queue selection, and no remote command
        restores it. add_consumer attaches a consumer without putting the queue back, because in Celery 5.5.3
        add_task_queue reaches select_add only for a queue it has never heard of. Such a worker runs normally until its
        next broker reconnect. It then builds its consumer from the empty selection and consumes nothing, while inspect
        ping still answers pong.

        So the selection has to start again, and a new pod does that with no signal into a running worker and no
        restart count. Remote control's shutdown does not restore it either: it ends the process, and the container
        that follows adds to the restart count PodRestarting reads. This was run in prod-sim with a broker restart
        after it, and the worker came back and consumed (harness-worker-control-prod-sim-1.txt). Deleting a pod is no
        drift for Argo CD, though the Application reads Progressing until the replacement is ready.
        """
        self.cluster.in_namespace("delete", "pod", "-l", WORKER_SELECTOR, "--wait=true", "--timeout=120s", timeout=150)
        self.cluster.in_namespace("rollout", "status", "deployment/plane-worker-wl", "--timeout=180s", timeout=200)
        end = time.monotonic() + 120
        while self.cluster.queues().get("celery", {}).get("consumers", 0) < 1:
            if time.monotonic() > end:
                raise StepFailed("the replacement worker has no consumer on queue celery after 120s")
            time.sleep(2)
        data["worker_replaced"] = True

    def step_worker_negative_control(self, data: dict) -> str:
        """Stops the worker consuming, then replaces its pod, because the control leaves state a later reconnect
        would trip on. No spec changes, so Argo CD has nothing to revert.

        Without this, an activity that some other path wrote would pass the background-job step.
        """
        try:
            detail = self.worker_negative_control(data)
        except BaseException as exc:
            # Whatever stopped the control, it may have stopped after the cancel. Its own failure stays the one to read.
            try:
                self.replace_worker(data)
            except (StepFailed, StepBlocked, OSError, subprocess.SubprocessError) as replacing:
                raise StepFailed(f"{exc}. Then the worker could not be replaced either: {replacing}") from exc
            raise
        self.replace_worker(data)
        return f"{detail}. Worker pod replaced, so no emptied queue selection is left behind"

    def worker_negative_control(self, data: dict) -> str:
        control = self.cluster.celery_control
        control("cancel_consumer", "celery")
        try:
            end = time.monotonic() + 30
            while self.cluster.queues()["celery"]["consumers"] != 0:
                if time.monotonic() > end:
                    raise StepFailed("the worker still consumes 30s after cancel_consumer")
                time.sleep(2)
            work_item_id = self.create_work_item(self.base(), f"negative-control {self.run_id}")
            time.sleep(15)
            early = self.activity_count(self.base(), work_item_id)
            parked = self.cluster.queues()["celery"]
            data.update(activity_with_no_consumer=early, messages_with_no_consumer=parked["messages"],
                        consumers_with_no_consumer=parked["consumers"])
            if early != 0:
                raise StepFailed("the activity appeared with no consumer, so the worker is not what writes it")
            if parked["messages"] < 1:
                raise StepFailed("the work item left no message in queue celery")
        finally:
            asked = time.monotonic()
            control("add_consumer", "celery")
        self.wait_for_created_activity(self.base(), work_item_id)
        seconds = time.monotonic() - asked
        data["seconds_after_asking_consumer_back"] = round(seconds, 1)
        back = self.cluster.queues()["celery"]
        if back["consumers"] < 1:
            raise StepFailed("the worker did not come back on queue celery")
        data["consumers_after"] = back["consumers"]
        return (f"With 0 consumers: {parked['messages']} messages parked, no activity after 15s. "
                f"Asked the consumer back: activity within {seconds:.1f}s")

    def step_worker_clean(self, data: dict) -> str:
        """A worker that has logged this keeps consuming until its next broker reconnect, and then stops. Nothing
        else shows it: the queue has its consumer and inspect ping answers until the moment it matters."""
        cancelled = [line for line in self.cluster.worker_log().splitlines() if "Canceling queue" in line]
        data["canceling_queue_lines"] = len(cancelled)
        if cancelled:
            raise StepFailed(f"the worker has been through cancel_consumer ({cancelled[-1][:60]}), so it will consume "
                             f"nothing after its next broker reconnect. Replace it: kubectl -n {self.cluster.namespace} "
                             f"delete pod -l {WORKER_SELECTOR}")
        return "no cancel_consumer in this worker's log, so its queue selection should survive a broker reconnect"

    def wait_for_created_activity(self, base: str, work_item_id: str) -> float:
        """Proves API -> RabbitMQ -> worker -> Postgres. The POST alone returns 201 with no worker."""
        started = time.monotonic()
        target = f"{base}/work-items/{work_item_id}/activities/"
        while time.monotonic() - started < self.args.job_timeout:
            response = self.http.get(target, session=False, headers=self.api())
            if response.status == 200 and any(a.get("verb") == "created" for a in response.json().get("results", [])):
                return time.monotonic() - started
            if response.status not in (200, 429, 502, 503, 504):
                raise StepFailed(f"activities answered {response.status}")
            # 60 requests per minute per key, so stay comfortably below it.
            time.sleep(3)
        raise StepFailed(f"no 'created' activity after {self.args.job_timeout}s: worker or broker is not processing")

    def step_background_job(self, data: dict) -> str:
        seconds = self.wait_for_created_activity(self.base(), self.state["work_item_id"])
        data["seconds_until_activity"] = round(seconds, 1)
        return f"issue_activity task ran in {seconds:.1f}s"

    def upload_attachment(self, base: str, work_item_id: str, content: bytes) -> str:
        filename = "smoke.txt"
        headers = self.api()
        # /api/v1/workspaces/{slug}/assets/ passes a keyword S3Storage does not accept, so this
        # per-work-item endpoint is the one that works for scripted uploads.
        created = self.http.send_json("POST", f"{base}/work-items/{work_item_id}/attachments/",
                                      {"name": filename, "type": "text/plain", "size": len(content)},
                                      session=False, headers=headers)
        grant = expect(created, 200).json()
        upload = grant["upload_data"]
        self.state["last_object_key"] = upload["fields"]["key"]
        target = urlsplit(upload["url"])
        if target.netloc != self.host:
            raise StepFailed(f"presigned POST names host {target.netloc}, expected {self.host}")
        if self.tls and target.scheme != "https":
            raise StepFailed(f"presigned POST is {target.scheme}, so a browser would refuse it on this https page")
        content_type, body = multipart(upload["fields"], filename, "text/plain", content)
        posted = self.http.request("POST", target.path, session=False, body=body,
                                   headers={"Content-Type": content_type})
        # Path-style presigned POST goes to the bare bucket path, which only works if Traefik
        # routes /uploads as well as /uploads/*.
        expect(posted, 204, 201)
        confirmed = self.http.send_json("PATCH", f"{base}/work-items/{work_item_id}/attachments/{grant['asset_id']}/",
                                        {}, session=False, headers=headers)
        expect(confirmed, 204)
        return grant["asset_id"]

    def download_attachment(self, base: str, work_item_id: str, asset_id: str) -> bytes:
        redirect = self.retrying_get(f"{base}/work-items/{work_item_id}/attachments/{asset_id}/",
                                     session=False, headers=self.api())
        expect(redirect, 302)
        target = urlsplit(redirect.location)
        if target.netloc != self.host:
            raise StepFailed(f"presigned GET names host {target.netloc}, expected {self.host}")
        if self.tls and target.scheme != "https":
            raise StepFailed(f"presigned GET is {target.scheme}, so a browser would refuse it on this https page")
        # Host is part of the signature, so this also proves the ingress preserved it.
        fetched = self.retrying_get(f"{target.path}?{target.query}", session=False, headers={"Accept": "*/*"})
        return expect(fetched, 200).body

    def step_attachment_upload(self, data: dict) -> str:
        content = (f"wayline smoke {self.run_id}\n" + secrets.token_hex(512)).encode()
        self.state["attachment"] = content
        self.state["asset_id"] = self.upload_attachment(self.base(), self.state["work_item_id"], content)
        self.state["attachment_key"] = self.state["last_object_key"]
        data.update(asset_id=self.state["asset_id"], size=len(content), sha256=sha256(content))
        return f"{len(content)} bytes stored"

    def step_attachment_download(self, data: dict) -> str:
        got = self.download_attachment(self.base(), self.state["work_item_id"], self.state["asset_id"])
        want = sha256(self.state["attachment"])
        data.update(expected_sha256=want, actual_sha256=sha256(got))
        if sha256(got) != want:
            raise StepFailed(f"checksum mismatch: {sha256(got)} != {want}")
        return f"sha256 {want[:16]}... matches"

    def step_object_in_silo(self, data: dict) -> str:
        """Straight from Silo, past Traefik and the api: the bytes, in the bucket the contract names."""
        stored = self.cluster.silo_object(self.state["attachment_key"])
        want = sha256(self.state["attachment"])
        data.update(stored, key=self.state["attachment_key"], expected_sha256=want)
        if stored["bucket"] != "uploads":
            raise StepFailed(f"bucket is {stored['bucket']}, and export links need uploads")
        if stored["sha256"] != want:
            raise StepFailed(f"Silo holds different bytes: {stored['sha256']}")
        return f"{stored['size']} bytes in bucket {stored['bucket']}, sha256 matches, buckets: {stored['all_buckets']}"

    def step_uploads_private(self, data: dict) -> str:
        """The bucket has no anonymous policy, because the chart's bucket Job is removed. Keep it so."""
        key = self.state["attachment_key"]
        statuses = {
            "object": self.http.get(f"/uploads/{key}", session=False, headers={"Accept": "*/*"}).status,
            "list": self.http.get("/uploads?list-type=2", session=False, headers={"Accept": "*/*"}).status,
        }
        redirect = self.http.get(f"{self.base()}/work-items/{self.state['work_item_id']}/attachments/{self.state['asset_id']}/",
                                 session=False, headers=self.api())
        where = urlsplit(expect(redirect, 302).location)
        signed = dict(pair.split("=", 1) for pair in where.query.split("&"))
        signature = signed["X-Amz-Signature"]
        signed["X-Amz-Signature"] = ("0" if signature[0] != "0" else "1") + signature[1:]
        statuses["tampered_signature"] = self.http.get(f"{where.path}?{urlencode(signed, safe='%')}", session=False,
                                                       headers={"Accept": "*/*"}).status
        data["statuses"] = statuses
        if any(status != 403 for status in statuses.values()):
            raise StepFailed(f"want 403 for each: {statuses}")
        return f"refused without a valid signature: {statuses}"

    def step_large_upload(self, data: dict) -> str:
        """Past Traefik's 1 MiB in-memory buffer, so the body spills to its temp directory on the way."""
        content = secrets.token_bytes(1024) * (4 * 1024 + 512)  # 4.5 MiB, below FILE_SIZE_LIMIT
        asset_id = self.upload_attachment(self.base(), self.state["work_item_id"], content)
        got = self.download_attachment(self.base(), self.state["work_item_id"], asset_id)
        data.update(size=len(content), matches=sha256(got) == sha256(content))
        if sha256(got) != sha256(content):
            raise StepFailed("the 4.5 MiB attachment came back different")
        return f"{len(content)} bytes up and back through Traefik, sha256 matches"

    def step_oversize_refused(self, data: dict) -> str:
        """The API caps the signed policy at FILE_SIZE_LIMIT whatever size the client claims."""
        content = b"x" * (5 * 1024 * 1024 + 1)
        created = self.http.send_json("POST", f"{self.base()}/work-items/{self.state['work_item_id']}/attachments/",
                                      {"name": "too-big.txt", "type": "text/plain", "size": len(content)},
                                      session=False, headers=self.api())
        if created.status != 200:
            data["api_status"] = created.status
            return f"the api refused the grant with {created.status}"
        upload = created.json()["upload_data"]
        content_type, body = multipart(upload["fields"], "too-big.txt", "text/plain", content)
        posted = self.http.request("POST", urlsplit(upload["url"]).path, session=False, body=body,
                                   headers={"Content-Type": content_type, "Accept": "*/*"})
        data["storage_status"] = posted.status
        if posted.status in (200, 201, 204):
            raise StepFailed("5 MiB + 1 byte was stored, above FILE_SIZE_LIMIT")
        return f"5 MiB + 1 byte refused by the storage policy with {posted.status}"

    def step_asset_duplicate(self, data: dict) -> str:
        """api -> CoreDNS rewrite -> Traefik -> Silo. The only api call that dials its own public host.

        The view answers 200 even when copy_object swallows a ClientError, so only the copied
        bytes count as proof.
        """
        slug, project_id, item_id = self.state["slug"], self.state["project_id"], self.state["work_item_id"]
        response = self.http.send_json("POST", f"/api/assets/v2/workspaces/{slug}/duplicate-assets/{self.state['asset_id']}/",
                                       {"project_id": project_id, "entity_id": item_id, "entity_type": "ISSUE_ATTACHMENT"})
        new_asset = expect(response, 200).json()["asset_id"]
        if new_asset == self.state["asset_id"]:
            raise StepFailed("the duplicate has the same id as the original")
        got = self.download_attachment(self.base(), item_id, new_asset)
        data.update(asset_id=new_asset, actual_sha256=sha256(got), expected_sha256=sha256(self.state["attachment"]))
        if sha256(got) != sha256(self.state["attachment"]):
            raise StepFailed("the duplicate holds different bytes")
        return f"copy_object through the public host worked: {new_asset} holds the same bytes"

    def step_avatar(self, data: dict) -> str:
        """Upload an image, then read it with no credentials, as avatars are read."""
        created = self.http.send_json("POST", "/api/assets/v2/user-assets/",
                                      {"name": "smoke.png", "type": "image/png", "size": len(ONE_PIXEL_PNG),
                                       "entity_type": "USER_AVATAR"})
        grant = expect(created, 200).json()
        upload = grant["upload_data"]
        content_type, body = multipart(upload["fields"], "smoke.png", "image/png", ONE_PIXEL_PNG)
        expect(self.http.request("POST", urlsplit(upload["url"]).path, session=False, body=body,
                                 headers={"Content-Type": content_type}), 204, 201)
        expect(self.http.send_json("PATCH", f"/api/assets/v2/user-assets/{grant['asset_id']}/", {}), 204)
        redirect = expect(self.http.get(f"/api/assets/v2/static/{grant['asset_id']}/", session=False), 302)
        target = urlsplit(redirect.location)
        fetched = expect(self.http.get(f"{target.path}?{target.query}", session=False, headers={"Accept": "*/*"}), 200)
        if fetched.body != ONE_PIXEL_PNG:
            raise StepFailed("the avatar came back different")
        data["asset_id"] = grant["asset_id"]
        return "avatar stored and read back anonymously through its signed redirect"

    def step_export(self, data: dict) -> str:
        """A worker writes to Silo over the in-cluster address and signs a link for the public host.
        This is the path that needs the bucket to be called uploads."""
        slug = self.state["slug"]
        expect(self.http.send_json("POST", f"/api/workspaces/{slug}/export-issues/",
                                   {"provider": "csv", "multiple": False, "project": [self.state["project_id"]]}), 200)
        end = time.monotonic() + self.args.job_timeout
        latest: dict = {}
        while time.monotonic() < end:
            results = expect(self.http.get(f"/api/workspaces/{slug}/export-issues/?per_page=10&cursor=10:0:0"),
                             200).json().get("results", [])
            latest = results[0] if results else {}
            if latest.get("status") in ("completed", "failed"):
                break
            time.sleep(3)
        data["status"] = latest.get("status")
        if latest.get("status") != "completed":
            raise StepFailed(f"export status is {latest.get('status')!r} after {self.args.job_timeout}s")
        target = urlsplit(latest["url"])
        if target.netloc != self.host or not target.path.startswith("/uploads/") or target.path.startswith("/uploads/uploads/"):
            raise StepFailed(f"export link is malformed: {target.netloc}{target.path}")
        fetched = expect(self.http.get(f"{target.path}?{target.query}", session=False, headers={"Accept": "*/*"}), 200)
        with zipfile.ZipFile(io.BytesIO(fetched.body)) as archive:
            names = archive.namelist()
            text = b"".join(archive.read(name) for name in names)
        data.update(zip_bytes=len(fetched.body), files=len(names))
        if self.state["work_item_name"].encode() not in text:
            raise StepFailed("the exported file does not contain the work item")
        return f"export completed, its link downloads, and the {len(fetched.body)} byte zip holds the work item"

    def step_public_board(self, data: dict) -> str:
        """Publish, read as an anonymous visitor, then unpublish, so nothing stays public after the run."""
        slug, project_id = self.state["slug"], self.state["project_id"]
        collection = f"/api/workspaces/{slug}/projects/{project_id}/project-deploy-boards/"
        board = expect(self.http.send_json("POST", collection, {"views": {"list": True, "kanban": True}}), 200).json()
        anchor = board["anchor"]
        try:
            settings = expect(self.http.get(f"/api/public/anchor/{anchor}/settings/", session=False), 200).json()
            data["settings_project"] = settings.get("project")
            issues = expect(self.http.get(f"/api/public/anchor/{anchor}/issues/", session=False), 200)
            if self.state["work_item_name"].encode() not in issues.body:
                raise StepFailed("the public issue list does not show the work item")
            # Server-rendered by space, whose build has an empty API base URL and whose NetworkPolicy
            # has no route to the api. This shows that costs a public page nothing but its metadata.
            page = expect(self.http.get(f"/spaces/issues/{anchor}/", session=False, headers={"Accept": "text/html"}), 200)
            data["page_bytes"] = len(page.body)
            if b"/spaces/assets/" not in page.body:
                raise StepFailed("the public page was not rendered by space")
        finally:
            expect(self.http.request("DELETE", f"{collection}{board['id']}/"), 204)
        gone = self.http.get(f"/api/public/anchor/{anchor}/settings/", session=False).status
        data["after_unpublish"] = gone
        if gone == 200:
            raise StepFailed("the board still answers after unpublishing")
        return f"published: api and space serve it anonymously. Unpublished: {gone}"

    def step_realtime_page(self, data: dict) -> str:
        target = f"/api/workspaces/{self.state['slug']}/projects/{self.state['project_id']}/pages/"
        self.state["page_name"] = f"smoke page {self.run_id}"
        response = self.http.send_json("POST", target, {"name": self.state["page_name"], "access": 0})
        self.state["page_id"] = expect(response, 201).json()["id"]
        data["page_id"] = self.state["page_id"]
        return self.state["page_id"]

    def open_collaboration(self) -> WebSocket:
        query = urlencode({"documentType": "project_page", "projectId": self.state["project_id"],
                           "workspaceSlug": self.state["slug"]})
        cookie = f"session-id={self.http.cookies['session-id']}"
        self.state["cookie"] = cookie
        return WebSocket(self.connect_host, self.connect_port, self.host, f"/live/collaboration?{query}", cookie, tls=self.tls)

    def step_realtime_auth(self, data: dict) -> str:
        ws = self.open_collaboration()
        try:
            token = json.dumps({"id": self.state["user_id"], "cookie": self.state["cookie"]})
            verdict, reason = collaboration_auth(ws, self.state["page_id"], token)
        finally:
            ws.close()
        data.update(verdict=verdict, reason=reason)
        if verdict != "Authenticated":
            raise StepFailed(f"{verdict}: {reason}")
        return f"Authenticated ({reason}): traefik upgrade, live -> api session check"

    def step_realtime_denied(self, data: dict) -> str:
        # Without this, an always-yes server would pass the step above.
        ws = self.open_collaboration()
        try:
            token = json.dumps({"id": str(uuid.uuid4()), "cookie": self.state["cookie"]})
            try:
                verdict, reason = collaboration_auth(ws, self.state["page_id"], token)
            except WsClosed as exc:
                verdict, reason = "PermissionDenied", f"closed with {exc.code}"
        finally:
            ws.close()
        data.update(verdict=verdict)
        if verdict == "Authenticated":
            raise StepFailed("a token naming another user was accepted")
        return f"mismatched user refused: {verdict}"

    def open_collaborator(self) -> Collaborator:
        ws = self.open_collaboration()
        try:
            token = json.dumps({"id": self.state["user_id"], "cookie": self.state["cookie"]})
            verdict, reason = collaboration_auth(ws, self.state["page_id"], token)
            if verdict != "Authenticated":
                raise StepFailed(f"{verdict}: {reason}")
        except BaseException:
            ws.close()
            raise
        return Collaborator(ws, self.state["page_id"])

    def step_realtime_sync(self, data: dict) -> str:
        """Two clients on one page: what one types reaches the other through Traefik and live."""
        self.state["page_marker"] = f"wayline-sync-{self.run_id}-{secrets.token_hex(4)}"
        marker = self.state["page_marker"].encode()
        first = self.open_collaborator()
        second = None
        try:
            second = self.open_collaborator()
            document = first.first_sync()
            second.first_sync()
            # Only live's own read of the page, from the api, can have put this title in the document.
            if self.state["page_name"].encode() not in document:
                raise StepFailed("the document the server sent does not hold the page title")
            data["first_sync_bytes"] = len(document)
            started = time.monotonic()
            first.send_update(yjs_paragraph_update(secrets.randbelow(2**31), self.state["page_marker"]))
            second.wait_for_update(marker)
            data["delivery_ms"] = int((time.monotonic() - started) * 1000)
        finally:
            first.ws.close()
            if second:
                second.ws.close()
        return f"both clients synced, and an update reached the other client in {data['delivery_ms']} ms"

    def step_realtime_persist(self, data: dict) -> str:
        """Through live -> api -> Postgres, then back out in a new connection after the room emptied."""
        marker = self.state["page_marker"]
        target = f"/api/workspaces/{self.state['slug']}/projects/{self.state['project_id']}/pages/{self.state['page_id']}/"
        started = time.monotonic()
        # Hocuspocus stores when the last client leaves, and otherwise after its 10s debounce.
        while marker not in (expect(self.http.get(target), 200).json().get("description_html") or ""):
            if time.monotonic() - started > 45:
                raise StepFailed("description_html has no trace of the update after 45s")
            time.sleep(2)
        data["seconds_until_stored"] = round(time.monotonic() - started, 1)
        binary = expect(self.http.get(f"{target}description/", headers={"Accept": "*/*"}), 200)
        if marker.encode() not in binary.body:
            raise StepFailed("description_binary has no trace of the update")
        third = self.open_collaborator()
        try:
            document = third.first_sync()
        finally:
            third.ws.close()
        if marker.encode() not in document:
            raise StepFailed("a new connection did not receive the stored update")
        data["binary_bytes"] = len(binary.body)
        return (f"stored as HTML and binary in {data['seconds_until_stored']}s, "
                "and a new connection gets it back from the database")

    def step_realtime_soak(self, data: dict) -> str:
        """Idle connections must outlive every timeout on the path, and still deliver afterwards."""
        seconds = self.args.soak_seconds
        marker = f"wayline-soak-{self.run_id}-{secrets.token_hex(4)}"
        clients = [self.open_collaborator()]
        try:
            clients.append(self.open_collaborator())
            for client in clients:
                client.first_sync()
            end = time.monotonic() + seconds
            while time.monotonic() < end:
                readable, _, _ = select.select([client.ws.sock for client in clients], [], [], 1)
                for client in clients:
                    if client.ws.buffer or client.ws.sock in readable:
                        client.ws.sock.settimeout(15)
                        client.ws.read_frame()
            data["pings_answered"] = [client.ws.pings for client in clients]
            clients[0].send_update(yjs_paragraph_update(secrets.randbelow(2**31), marker))
            clients[1].wait_for_update(marker.encode())
        finally:
            for client in clients:
                client.ws.close()
        return f"two connections idle for {seconds}s, pings answered {data['pings_answered']}, then an update got through"

    def require_branded(self, component: str) -> None:
        if component not in self.state["branded"]:
            raise StepSkipped(f"this environment's overlay does not put localhost:5001/wayline/{component} in place, "
                              "so that image does not decide this")

    def step_branding_overlay(self, data: dict) -> str:
        """Whether there is anything to check, and whether what Git names is what is running. Everything after this
        checks a running image, so a rollout still on its way must not read as a broken one. The pod template alone
        cannot show that: Argo CD applies it as the rollout starts, while the old pods still serve."""
        path = overlay_path(self.args.env)
        branded = branded_images(path.read_text())
        self.state["branded"] = branded
        data["branded"] = {component: entry.get("digest") for component, entry in sorted(branded.items())}
        if self.args.branding == "require":
            self.state["branded"] = {component: {} for component in BRANDED_WORKLOADS}
            return "--branding require: checking every image, whatever the overlay says"
        if not branded:
            raise StepSkipped(f"{path.relative_to(ROOT)} names no localhost:5001/wayline image, so this environment "
                              "runs upstream's and has no branding to check. This runs once make promote puts them there")
        deployments = self.cluster.deployments()
        problems = []
        for component, entry in sorted(branded.items()):
            want = f"{entry['newName']}@{entry.get('digest')}"
            for name in BRANDED_WORKLOADS.get(component, []):
                deployment = deployments.get(name, {})
                containers = deployment.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
                images = [container["image"] for container in containers]
                data[name] = images
                unfinished = rollout_unfinished(deployment)
                if want not in images:
                    problems.append(f"{name} is set to {images}, and the overlay names {want}")
                elif unfinished:
                    problems.append(f"{name} is set to the overlay's image, and {unfinished}")
        if problems:
            raise StepBlocked("what is running is not what the overlay names, so a check here would say nothing "
                              f"about this overlay. Is the rollout finished? {'; '.join(problems)}")
        return f"{', '.join(sorted(branded))} run the digests in {path.relative_to(ROOT)}, with every rollout finished"

    def step_branding_web(self, data: dict) -> str:
        self.require_branded("web")
        page = expect(self.http.get("/", session=False, headers={"Accept": "text/html"}), 200)
        html = page.body.decode("utf-8", "replace")
        data["title"] = page_title(html)
        problems = brand_problems("/", html)

        # Upstream's image answers /source with the app's page, 200. Not followed: the repository is private for now,
        # so its answer says nothing about this image. See apps/wayline/README.md.
        repository = configured_source_repo()
        source = self.http.get("/source", session=False, headers={"Accept": "*/*"})
        data.update(source_status=source.status, source_location=source.location)
        commit = re.fullmatch(re.escape(repository) + r"/tree/([0-9a-f]{40})", source.location)
        if source.status != 302 or not commit:
            problems.append(f"/source answered {source.status} to {source.location!r}, want a 302 to {repository}/tree/<commit>")
        else:
            try:
                known = git("cat-file", "-e", f"{commit.group(1)}^{{commit}}").returncode == 0
            except (OSError, subprocess.TimeoutExpired):
                known = None
            data["source_commit_in_this_repository"] = known
            if known is False:
                problems.append(f"/source names commit {commit.group(1)}, which this repository does not have")

        listing = self.http.get("/licenses/", session=False, headers={"Accept": "text/html"})
        data["licenses_status"] = listing.status
        if listing.status != 200:
            problems.append(f"/licenses/ answered {listing.status}")
        missing = [name for name in LICENCE_FILES if f'href="{name}"'.encode() not in listing.body]
        if missing:
            problems.append(f"/licenses/ does not list {missing}")
        licence = self.http.get("/licenses/LICENSE.txt", session=False, headers={"Accept": "*/*"})
        data["license_status"] = licence.status
        if licence.status != 200 or b"GNU AFFERO GENERAL PUBLIC LICENSE" not in licence.body:
            problems.append(f"/licenses/LICENSE.txt answered {licence.status} and is not the AGPL text")
        if problems:
            raise StepFailed("; ".join(problems))
        return (f"title {data['title']!r}, /source 302 to {repository}/tree/{commit.group(1)[:12]}... (not followed: "
                f"the repository is private for now), /licenses/ lists {len(LICENCE_FILES)} files and serves the AGPL")

    def step_branding_page(self, data: dict, component: str, path: str) -> str:
        self.require_branded(component)
        html = expect(self.http.get(path, session=False, headers={"Accept": "text/html"}), 200).body.decode("utf-8", "replace")
        data["title"] = page_title(html)
        problems = brand_problems(path, html)
        if problems:
            raise StepFailed("; ".join(problems))
        return f"{path} title {data['title']!r}, and no upstream brand in the page"

    def step_branding_backend(self, data: dict) -> str:
        """The backend image sets INSTANCE_CHANGELOG_URL empty. An operator may still set their own. Not read from the bare
        path, which after a promotion can still hold the previous image's answer, good or bad: see instance_now. branding-overlay
        has shown that no old pod is left to answer this read."""
        self.require_branded("backend")
        payload = self.instance_now("branding")
        if "instance_changelog_url" not in payload.get("config", {}):
            raise StepFailed("/api/instances/ no longer reports instance_changelog_url, so this check says nothing")
        changelog = payload["config"]["instance_changelog_url"]
        data["instance_changelog_url"] = changelog
        if UPSTREAM_BRAND.search(changelog or ""):
            raise StepFailed(f"the backend reports upstream's changelog: {changelog!r}")
        return f"instance_changelog_url is {changelog!r}, so \"What's new\" shows the local fallback"

    def step_branding_seed(self, data: dict) -> str:
        """What the worker's image writes into a workspace created now. The bot is one user per workspace, named when
        the workspace is seeded, so this needs no clean database: older workspaces keep their bot, this one does not."""
        self.require_branded("backend")
        slug, name = self.state["slug"], self.state["workspace_name"]
        workspace = f"/api/workspaces/{slug}"
        projects = expect(self.http.get(f"{workspace}/projects/"), 200).json()
        projects = projects.get("results", projects) if isinstance(projects, dict) else projects
        seeded = [project["id"] for project in projects if project.get("name") == name]
        if not seeded:
            raise StepFailed(f"no project named after the workspace among {len(projects)}")
        seed = seeded[0]
        issues, pages = f"{workspace}/projects/{seed}/issues", f"{workspace}/projects/{seed}/pages/"
        # The seed task writes pages last, so once one exists the rest is there to read.
        end = time.monotonic() + self.args.job_timeout
        while not expect(self.http.get(pages), 200).json():
            if time.monotonic() > end:
                raise StepFailed(f"no seed page after {self.args.job_timeout}s")
            time.sleep(2)

        bots = [row["member"] for row in expect(self.http.get(f"{workspace}/members/"), 200).json()
                if row.get("member", {}).get("is_bot")]
        data["bots"] = [(bot.get("display_name"), bot.get("first_name")) for bot in bots]
        problems = []
        if [(bot.get("display_name"), bot.get("first_name")) for bot in bots] != [("Wayline", "Wayline")]:
            problems.append(f"want one bot named Wayline in this new workspace, found {data['bots']}")

        listed = expect(self.http.get(f"{issues}/?per_page=100&cursor=100:0:0&group_by=state_id"), 200).json()
        identifiers = [item["id"] for group in listed.get("results", {}).values() for item in group.get("results", [])]
        bodies = [expect(self.http.get(f"{issues}/{identifier}/"), 200).body.decode("utf-8", "replace")
                  for identifier in identifiers]
        bodies.append(expect(self.http.get(pages), 200).body.decode("utf-8", "replace"))
        bodies.append(expect(self.http.get(f"{workspace}/projects/{seed}/cycles/"), 200).body.decode("utf-8", "replace"))
        text = "\n".join(bodies)
        data.update(seed_work_items=len(identifiers), wayline_words=text.count("Wayline"), plane_words=len(UPSTREAM_NAME.findall(text)))
        if not identifiers:
            problems.append("the seed project has no work items to read")
        if data["plane_words"]:
            found = UPSTREAM_NAME.search(text)
            problems.append(f"the seed content names upstream {data['plane_words']} time(s), first: {text[max(0, found.start() - 30):found.end() + 30]!r}")
        if not data["wayline_words"]:
            problems.append("the seed content does not name Wayline, so reading it for upstream's name proves little")
        if problems:
            raise StepFailed("; ".join(problems))
        return (f"the bot of this new workspace is named Wayline, and {len(identifiers)} seed work items, its pages and "
                f"its cycles name Wayline {data['wayline_words']} times and upstream 0")

    def step_branding_fresh_install(self, data: dict) -> str:
        """What register_instance writes when no instance exists: the default name, and telemetry off. Admin setup
        then replaces both with what its form sends, and this test sends company_name=Wayline itself, so afterwards
        the name proves nothing. So this reads the instance as this run first found it, and only a run that found it
        not yet set up can check this. The first smoke after a clean install is that run."""
        self.require_branded("backend")
        instance = self.state["instance"]
        data.update(found_setup_done=bool(instance.get("is_setup_done")), found_name=instance.get("instance_name"),
                    found_telemetry=instance.get("is_telemetry_enabled"), registered_at=instance.get("created_at"))
        if instance.get("is_setup_done"):
            raise StepSkipped(
                f"needs a clean database. This instance was set up before this run, and setup replaces what the image "
                f"registered with what its form sent, so {instance.get('instance_name')!r} now says nothing about the "
                "image. The first smoke after a clean install checks the registered name and telemetry default")
        since = branded_backend_since(self.args.env)
        registered = parse_time(instance.get("created_at") or "")
        if since is None:
            raise StepBlocked("Git cannot say when the Wayline backend reached this overlay, so this cannot tell who registered the instance")
        if registered < since:
            raise StepSkipped(f"needs a clean database. This instance was registered at {registered.isoformat()}, before "
                              f"the Wayline backend reached the overlay at {since.isoformat()}, so upstream's image registered it")
        problems = []
        if instance.get("instance_name") != "Wayline":
            problems.append(f"a new instance is named {instance.get('instance_name')!r}, want 'Wayline'")
        if instance.get("is_telemetry_enabled") is not False:
            problems.append(f"a new instance has telemetry {instance.get('is_telemetry_enabled')!r}, want False")
        if problems:
            raise StepFailed("; ".join(problems))
        return "before setup, the instance this image registered is named Wayline, with telemetry off"

    def drop_older_sentinel(self, data: dict) -> str:
        """make destroy keeps the record, and this run found no admin in this database and made the first one, so the
        database is new and cannot hold it. Reusing it would fail the first smoke after every clean install, the one
        run that can read branding-fresh-install.

        A database lost under the namespace that wrote the record looks the same from here, and that must stay a
        failure. Only there is the namespace older than the record, because make destroy takes the namespace with it.
        Not caught: a record a restore brought onto a newer cluster, if that database is then lost."""
        old = json.loads(self.sentinel_path.read_text())
        namespace = json.loads(self.cluster.run("get", "namespace", self.cluster.namespace, "-o", "json"))
        created = namespace["metadata"]["creationTimestamp"]
        data["older_sentinel"] = {key: old.get(key) for key in ("slug", "work_item_id", "created_at")}
        data["namespace_created_at"] = created
        if parse_time(created) < parse_time(old["created_at"]):
            raise StepFailed(f"this run found the instance not set up, and namespace {self.cluster.namespace}, created "
                             f"{created}, is older than sentinel {old['slug']}, written {old['created_at']}. So this "
                             f"database held that record and no longer does: data was lost. If it was reset on purpose, "
                             f"remove {self.sentinel_path} and run this again")
        self.sentinel_path.unlink()
        return (f"Replaced {self.sentinel_path.name}: this run found the instance not set up, so this new database cannot "
                f"hold sentinel {old['slug']}, written {old['created_at']}. ")

    def create_sentinel(self, data: dict) -> str:
        slug = f"sentinel-{self.run_id}"
        self.create_workspace(f"Sentinel {self.run_id}", slug)
        project_id = self.create_project(slug, "Sentinel")["id"]
        base = f"/api/v1/workspaces/{slug}/projects/{project_id}"
        name = f"persistence-sentinel-{self.args.env}-{uuid.uuid4()}"
        work_item_id = self.create_work_item(base, name)
        content = f"{name}\n{secrets.token_hex(256)}\n".encode()
        asset_id = self.upload_attachment(base, work_item_id, content)
        record = {"environment": self.args.env, "slug": slug, "project_id": project_id,
                  "work_item_id": work_item_id, "name": name, "asset_id": asset_id,
                  "sha256": sha256(content), "created_at": now_iso()}
        write_private(self.sentinel_path, json.dumps(record, indent=2) + "\n")
        data.update(record)
        return work_item_id

    def step_sentinel_create(self, data: dict) -> str:
        """A long-lived record that drills and restores re-read. It is never recreated silently: a missing sentinel
        means data was lost, so that must stay a failure. This step needs instance-setup to have passed, and verify
        mode never runs it, so a restored database, which holds the record and is set up, never reaches the replacement."""
        replaced = ""
        if self.sentinel_path.exists() and not self.args.reset_sentinel:
            if self.state["instance"].get("is_setup_done") is not False:
                return f"reusing existing sentinel {self.sentinel_path.name}"
            replaced = self.drop_older_sentinel(data)
        try:
            return f"{replaced}Created {self.create_sentinel(data)}"
        except Exception as exc:  # Whatever it was, the line has to say that the old file is gone.
            if not replaced:
                raise
            raise StepFailed(f"{replaced}The new record could not be created, so none is on disk now, and the next full run "
                             f"creates one: {type(exc).__name__}: {exc}") from exc

    def sentinel_refused(self, status: int, record: dict) -> str:
        """Plane gives an API key the same answer for a workspace that is not there and for a bad token, so ask what
        else this token can read."""
        me = self.http.get("/api/v1/users/me/", session=False, headers=self.api()).status
        if me != 200:
            return (f"sentinel workspace {record['slug']} answered {status}, and /api/v1/users/me/ with the same token "
                    f"answered {me}: the user or token row is gone, or the token is not this database's")
        return (f"sentinel workspace {record['slug']} answered {status} to a token that works, so this account has no "
                f"such workspace and this database does not hold the record: data was lost, or {self.sentinel_path.name}, "
                f"written {record.get('created_at')}, is from an older database. If this environment was installed after "
                "that, remove the file and run the full smoke test")

    def step_sentinel_reread(self, data: dict) -> str:
        if not self.sentinel_path.exists():
            raise StepBlocked(f"{self.sentinel_path} does not exist. Run the full smoke test first.")
        record = json.loads(self.sentinel_path.read_text())
        data.update(work_item_id=record["work_item_id"], expected_sha256=record["sha256"])
        base = f"/api/v1/workspaces/{record['slug']}/projects/{record['project_id']}"
        response = self.retrying_get(f"{base}/work-items/{record['work_item_id']}/", session=False,
                                     headers=self.api())
        if response.status in (401, 403):
            raise StepFailed(self.sentinel_refused(response.status, record))
        if response.status == 404:
            raise StepFailed("sentinel work item is gone: database content was lost")
        item = expect(response, 200).json()
        if item.get("name") != record["name"]:
            raise StepFailed("sentinel work item name differs from the one recorded")
        got = sha256(self.download_attachment(base, record["work_item_id"], record["asset_id"]))
        data["actual_sha256"] = got
        if got != record["sha256"]:
            raise StepFailed(f"sentinel attachment checksum differs: {got}")
        return "sentinel row and attachment intact"

    def step_job_probe(self, data: dict) -> str:
        """After a broker or worker restart, old rows prove nothing about the async path."""
        record = json.loads(self.sentinel_path.read_text())
        base = f"/api/v1/workspaces/{record['slug']}/projects/{record['project_id']}"
        # The POST publishes to the broker, so it can answer 500 while a restarted broker settles. A
        # retry that lands twice only leaves a second probe item behind.
        end = time.monotonic() + self.deadline_seconds
        while True:
            try:
                work_item_id = self.create_work_item(base, f"job-probe {self.run_id}")
                break
            except (StepFailed, OSError, http.client.HTTPException):
                if time.monotonic() > end:
                    raise
                time.sleep(10)
        seconds = self.wait_for_created_activity(base, work_item_id)
        data["seconds_until_activity"] = round(seconds, 1)
        return f"new work item got its activity in {seconds:.1f}s"

    # -- hosted production: an existing account over https. Creates no user, and never touches the admin sign-up --

    def step_hosted_certificate(self, data: dict) -> str:
        """The handshake a browser would make. A failure here is a FAIL, because the chain or the name is wrong."""
        if self.args.allow_untrusted_certificate:
            raise StepBlocked("--allow-untrusted-certificate is set, so no certificate was checked, and this run cannot read PASS. "
                              "That is what a staging certificate needs")
        with socket.create_connection((self.connect_host, self.connect_port), timeout=self.http.timeout) as raw:
            with self.tls.wrap_socket(raw, server_hostname=self.host) as secured:
                certificate = secured.getpeercert()
                data["tls_version"] = secured.version()
        issuer = dict(item[0] for item in certificate["issuer"])
        days = int((ssl.cert_time_to_seconds(certificate["notAfter"]) - time.time()) // 86400)
        data.update(issuer=issuer.get("organizationName"), issuer_common_name=issuer.get("commonName"), days_left=days)
        if days < 14:
            raise StepFailed(f"the served certificate ends in {days} days, and it renews well before that")
        return f"{data['tls_version']}, issued by {issuer.get('organizationName')}, {days} days left, and valid for {self.host}"

    def step_hosted_redirect(self, data: dict) -> str:
        plain = Http(self.host, self.connect_host, self.args.http_port)
        response = plain.get("/", session=False, headers={"Accept": "text/html"})
        where = urlsplit(response.location)
        data.update(status=response.status, scheme=where.scheme)
        # Traefik names the entrypoint's port if it is told to, and 443 means the same.
        if response.status not in (301, 308) or where.scheme != "https" or where.netloc.removesuffix(":443") != self.host:
            raise StepFailed(f"http answered {response.status} to {response.location!r}, want a permanent redirect to https://{self.host}/")
        return f"http answers {response.status} to https"

    def step_hosted_instance(self, data: dict) -> str:
        """Read only. Sign-up here is off, and an instance with no admin is for a person to claim, through a port-forward."""
        found = self.instance_now("hosted")
        instance, config = found.get("instance", found), found.get("config", {})
        data.update(is_setup_done=instance.get("is_setup_done"), enable_signup=config.get("enable_signup"))
        if not instance.get("is_setup_done"):
            raise StepBlocked("this instance has no admin yet, and this mode never claims it. Create it through a port-forward first")
        if config.get("enable_signup") is True:
            raise StepFailed("sign-up is open on the public host")
        return "set up, and sign-up is off"

    def step_hosted_sign_in(self, data: dict) -> str:
        email, password = self.credentials
        response = self.http.post_form("/auth/sign-in/", {"csrfmiddlewaretoken": self.csrf(), "email": email, "password": password})
        expect(response, 302)
        where = urlsplit(response.location)
        query = parse_qs(where.query)
        if "error_code" in query:
            # A wrong password says nothing about the platform. Sign-in itself answering is what this can show.
            raise StepBlocked(f"this account was refused: {query['error_code'][0]} {query.get('error_message', [''])[0]}")
        if where.scheme == "http":
            raise StepFailed(f"sign-in redirected to {where.scheme}, so the platform does not know it is on https")
        if "session-id" not in self.http.cookies:
            raise StepFailed("sign-in did not set session-id")
        self.redact.add(self.http.cookies["session-id"])
        anonymous = self.http.get("/api/users/me/", session=False)
        data["anonymous_me_status"] = anonymous.status
        if anonymous.status == 200:
            raise StepFailed("/api/users/me/ answered 200 with no session")
        self.state["user_id"] = expect(self.http.get("/api/users/me/"), 200).json()["id"]
        return "session established, anonymous request refused"

    def step_hosted_cookies(self, data: dict) -> str:
        """The chart's http origin removes Secure from these, which is why the overlay replaces it."""
        flags = self.http.cookie_flags
        data["flags"] = flags
        for name in ("session-id", "csrftoken"):
            if name not in flags:
                raise StepFailed(f"{name} was never set")
            if not flags[name]["secure"]:
                raise StepFailed(f"{name} has no Secure flag, so a browser would send it over plain http")
        if not flags["session-id"]["httponly"]:
            raise StepFailed("session-id has no HttpOnly flag")
        return "session-id and csrftoken are Secure, and session-id is HttpOnly"

    def step_hosted_workspace(self, data: dict) -> str:
        listed = expect(self.http.get("/api/users/me/workspaces/"), 200).json()
        listed = listed.get("results", listed) if isinstance(listed, dict) else listed
        slugs = [workspace["slug"] for workspace in listed]
        if self.args.workspace and self.args.workspace not in slugs:
            raise StepBlocked(f"this account is not a member of workspace {self.args.workspace}")
        if not slugs:
            raise StepBlocked("this account has no workspace, and this mode creates none. Make one in the app first")
        self.state["slug"] = self.args.workspace or slugs[0]
        data["slug"] = self.state["slug"]
        return f"using workspace {self.state['slug']}, and leaving it as it was"

    def step_hosted_token(self, data: dict) -> str:
        """Short-lived on purpose, so a run killed before its cleanup leaves nothing that lasts."""
        expires = dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=2)
        response = self.http.send_json("POST", "/api/users/api-tokens/", {
            "label": f"smoke-{self.run_id}", "description": "tests/e2e/smoke.py, removed at the end of its run",
            "expired_at": expires.strftime("%Y-%m-%dT%H:%M:%SZ"),
        })
        created = expect(response, 201).json()
        token = created.get("token")
        if not token:
            raise StepFailed("response has no token")
        self.redact.add(token)
        self.state.update(api_token=token, api_token_id=created["id"])
        return "a token good for 2 hours, removed below"

    def step_hosted_project(self, data: dict) -> str:
        project = self.create_project(self.state["slug"], "Smoke")
        self.state.update(project_id=project["id"], project=project)
        data["project_id"] = project["id"]
        return f"project {project['identifier']}"

    def step_hosted_work_item(self, data: dict) -> str:
        self.state["work_item_id"] = self.create_work_item(self.base(), f"smoke {self.run_id}")
        data["work_item_id"] = self.state["work_item_id"]
        return self.state["work_item_id"]

    def step_hosted_cleanup(self, data: dict) -> str:
        """Everything this run made, whatever else happened. What it could not remove is named, for a person. Each call stands
        alone, so one that fails, or a connection that drops, does not stop the next."""
        left: list[str] = []

        def attempt(what: str, send, *statuses: int) -> Response | None:
            try:
                response = send()
            except (OSError, http.client.HTTPException) as exc:
                left.append(f"{what} ({type(exc).__name__})")
                return None
            data[what] = response.status
            if statuses and response.status not in statuses:
                left.append(f"{what} (HTTP {response.status})")
            return response

        slug, project_id = self.state.get("slug"), self.state.get("project_id")
        if self.state.get("asset_id"):
            attempt("attachment", lambda: self.http.request(
                "DELETE", f"{self.base()}/work-items/{self.state['work_item_id']}/attachments/{self.state['asset_id']}/",
                session=False, headers=self.api()), 204)
        if project_id:
            # Removing the project takes its work items and pages with it.
            target = f"/api/v1/workspaces/{slug}/projects/{project_id}/"
            name = f"project {self.state['project']['identifier']}"
            attempt(name, lambda: self.http.request("DELETE", target, session=False, headers=self.api()), 204)
            after = attempt(f"{name}, read again", lambda: self.http.get(target, session=False, headers=self.api()))
            if after is not None and after.status != 404:
                left.append(f"{name} still answers")
        token_id = self.state.get("api_token_id")
        if token_id:
            name = f"API token smoke-{self.run_id}"
            attempt(name, lambda: self.http.request("DELETE", f"/api/users/api-tokens/{token_id}/"), 204)
            after = attempt(f"{name}, tried again", lambda: self.http.get("/api/v1/users/me/", session=False, headers=self.api()))
            if after is not None and after.status == 200:
                left.append(f"{name} still works, until it expires within 2 hours")
        attempt("sign-out", lambda: self.http.post_form("/auth/sign-out/", {"csrfmiddlewaretoken": self.csrf()}))
        self.http.cookies.pop("session-id", None)
        if left:
            raise StepFailed("could not remove: " + ", ".join(left) + ". Remove them in the app")
        return "attachment, project and token removed, and signed out. Plane soft-deletes, so the rows and the object go at its next hard-delete task"

    def run_hosted(self) -> None:
        self.run("tls-certificate", self.step_hosted_certificate)
        self.run("http-redirect", self.step_hosted_redirect)
        self.run("reachable", self.step_reachable)
        self.run("frontends", self.step_frontends, ("reachable",))
        self.run("routes", self.step_routes, ("reachable",))
        self.run("instance", self.step_hosted_instance, ("reachable",))
        self.run("csrf-enforced", self.step_csrf_enforced, ("reachable",))
        self.run("sign-in", self.step_hosted_sign_in, ("instance",))
        self.run("secure-cookies", self.step_hosted_cookies, ("sign-in",))
        try:
            self.run("workspace", self.step_hosted_workspace, ("sign-in",))
            self.run("api-token", self.step_hosted_token, ("sign-in",))
            self.run("project", self.step_hosted_project, ("workspace", "api-token"))
            self.run("work-item", self.step_hosted_work_item, ("project",))
            self.run("background-job", self.step_background_job, ("work-item",))
            self.run("attachment-upload", self.step_attachment_upload, ("work-item",))
            self.run("attachment-download", self.step_attachment_download, ("attachment-upload",))
            self.run("realtime-page", self.step_realtime_page, ("project",))
            self.run("realtime-auth", self.step_realtime_auth, ("realtime-page",))
            self.run("realtime-denied", self.step_realtime_denied, ("realtime-page",))
            self.run("realtime-sync", self.step_realtime_sync, ("realtime-auth",))
        finally:
            self.run("cleanup", self.step_hosted_cleanup, ("sign-in",))

    # -- plans --

    def run_full(self) -> None:
        self.run("reachable", self.step_reachable)
        self.run("frontends", self.step_frontends, ("reachable",))
        self.run("routes", self.step_routes, ("reachable",))
        self.run("workloads-ready", self.step_workloads)
        self.run("instance-setup", self.step_instance_setup, ("reachable",))
        self.run("csrf-enforced", self.step_csrf_enforced, ("reachable",))
        self.run("sign-in", self.step_sign_in, ("instance-setup",))
        self.run("workspace", self.step_workspace, ("sign-in",))
        self.run("api-token", self.step_api_token, ("sign-in",))
        self.run("project", self.step_project, ("workspace", "api-token"))
        self.run("work-item", self.step_work_item, ("project",))
        self.run("background-job", self.step_background_job, ("work-item",))
        self.run("work-item-list", self.step_list, ("work-item",))
        self.run("read-back", self.step_read_back, ("work-item",))
        self.run("workspace-seed", self.step_workspace_seed, ("workspace",))
        self.run_branding()
        self.run("app-shell", self.step_app_shell, ("project",))
        self.run("admin-sign-in", self.step_admin_sign_in, ("instance-setup",))
        self.run("second-user", self.step_second_user, ("work-item",))
        self.run("celery-consumers", self.step_consumers, ("reachable",))
        self.run("broker-memory", self.step_broker_memory, ("reachable",))
        if self.args.worker_negative_control:
            self.run("worker-negative-control", self.step_worker_negative_control, ("background-job", "celery-consumers"))
        # After the control, because that replaces a worker this would otherwise fail on.
        self.run("worker-clean", self.step_worker_clean, ("celery-consumers",))
        self.run("attachment-upload", self.step_attachment_upload, ("work-item",))
        self.run("attachment-download", self.step_attachment_download, ("attachment-upload",))
        self.run("object-in-silo", self.step_object_in_silo, ("attachment-upload",))
        self.run("uploads-private", self.step_uploads_private, ("attachment-upload",))
        self.run("large-upload", self.step_large_upload, ("attachment-upload",))
        self.run("oversize-refused", self.step_oversize_refused, ("work-item",))
        self.run("asset-duplicate", self.step_asset_duplicate, ("attachment-upload",))
        self.run("avatar", self.step_avatar, ("sign-in",))
        self.run("export", self.step_export, ("work-item",))
        self.run("public-board", self.step_public_board, ("work-item",))
        self.run("realtime-page", self.step_realtime_page, ("project",))
        self.run("realtime-auth", self.step_realtime_auth, ("realtime-page",))
        self.run("realtime-denied", self.step_realtime_denied, ("realtime-page",))
        self.run("realtime-sync", self.step_realtime_sync, ("realtime-auth",))
        self.run("realtime-persist", self.step_realtime_persist, ("realtime-sync",))
        # Not asserted: page versions. track_page_version reads page.description, which the Page
        # model at v1.4.3 does not have, so it logs AttributeError and page_versions stays empty.
        if self.args.soak_seconds:
            self.run("realtime-soak", self.step_realtime_soak, ("realtime-sync",))
        self.run("sentinel-create", self.step_sentinel_create, ("api-token",))
        self.run("sentinel-reread", self.step_sentinel_reread, ("sentinel-create",))

    def run_branding(self) -> None:
        if self.args.branding == "off":
            return
        self.run("branding-overlay", self.step_branding_overlay)
        if "branding-overlay" not in self.passed:
            return
        self.run("branding-web", self.step_branding_web, ("reachable",))
        self.run("branding-admin", lambda data: self.step_branding_page(data, "admin", "/god-mode/"), ("reachable",))
        self.run("branding-space", lambda data: self.step_branding_page(data, "space", "/spaces/"), ("reachable",))
        self.run("branding-backend", self.step_branding_backend, ("reachable",))
        self.run("branding-seed", self.step_branding_seed, ("workspace-seed",))
        self.run("branding-fresh-install", self.step_branding_fresh_install, ("reachable",))

    def run_verify(self) -> None:
        if self.args.env == HOSTED:
            self.run_hosted()
            return
        self.run("reachable", self.step_reachable)
        self.run("sentinel-reread", self.step_sentinel_reread, ("reachable",))
        if self.args.job_probe:
            self.run("job-probe", self.step_job_probe, ("sentinel-reread",))


def sha256(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# --- Offline self-test ---------------------------------------------------------------------------


class StubHosted:
    """What --env hosted --mode verify calls, over real HTTP with no TLS, as the routes read at upstream's v1.4.3. It knows nothing
    else of Plane, and a pass against it says nothing about the real server. What it does show: the order, what is removed, and
    that nothing ever asks for a user or the admin."""

    def __init__(self, *, secure: bool = True, fail_work_item: bool = False, fail_project_delete: bool = False,
                 presign_scheme: str = "https", redirect_only: bool = False, host: str = "hosted.test") -> None:
        self.secure, self.fail_work_item, self.fail_project_delete = secure, fail_work_item, fail_project_delete
        self.presign_scheme, self.redirect_only, self.host = presign_scheme, redirect_only, host
        self.calls: list[str] = []
        self.token_live = self.project_live = self.signed_out = False
        self.asset_deleted = False
        self.stored = b""
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), self.handler())
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def handler(self):
        stub = self
        flags = "; Path=/" + ("; Secure" if stub.secure else "")

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_) -> None:
                pass

            def reply(self, status: int, payload=None, headers: tuple = ()) -> None:
                body = payload if isinstance(payload, bytes) else b"" if payload is None else json.dumps(payload).encode()
                self.send_response(status)
                for name, value in headers:
                    self.send_header(name, value)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def answer(self, method: str) -> None:
                path = urlsplit(self.path).path
                stub.calls.append(f"{method} {path}")
                body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
                if stub.redirect_only:
                    return self.reply(308, headers=(("Location", f"https://{stub.host}/"),))
                if method == "GET" and path == "/":
                    return self.reply(200, b"<html>")
                if path == "/api/instances/":
                    return self.reply(200, {"instance": {"is_setup_done": True}, "config": {"enable_signup": False}})
                if path == "/auth/get-csrf-token/":
                    return self.reply(200, {"csrf_token": "t"}, (("Set-Cookie", f"csrftoken=t{flags}"),))
                if path == "/auth/sign-in/":
                    fields = parse_qs(body.decode())
                    if fields.get("password") != ["right"]:
                        return self.reply(302, headers=(("Location", f"https://{stub.host}/?error_code=5005&error_message=WRONG"),))
                    return self.reply(302, headers=(("Location", f"https://{stub.host}/"), ("Set-Cookie", f"session-id=a-session-value{flags}; HttpOnly")))
                if path == "/auth/sign-out/":
                    stub.signed_out = True
                    return self.reply(302, headers=(("Location", f"https://{stub.host}/"),))
                if path == "/api/users/me/":
                    return self.reply(200, {"id": "u"}) if "session-id" in self.headers.get("Cookie", "") else self.reply(401)
                if path == "/api/users/me/workspaces/":
                    return self.reply(200, [{"slug": "w"}])
                if path == "/api/users/api-tokens/" and method == "POST":
                    stub.token_live = True
                    return self.reply(201, {"id": "t1", "token": "plane_api_secret"})
                if path == "/api/users/api-tokens/t1/" and method == "DELETE":
                    stub.token_live = False
                    return self.reply(204)
                if path == "/api/v1/users/me/":
                    return self.reply(200, {"id": "u"}) if stub.token_live else self.reply(401)
                base = "/api/v1/workspaces/w/projects/"
                if path == base and method == "POST":
                    stub.project_live = True
                    return self.reply(201, {"id": "p1", "identifier": json.loads(body)["identifier"]})
                if path == f"{base}p1/":
                    if method == "DELETE":
                        if stub.fail_project_delete:
                            return self.reply(500)
                        stub.project_live = False
                        return self.reply(204)
                    return self.reply(200, {}) if stub.project_live else self.reply(404)
                item = f"{base}p1/work-items/"
                if path == item and method == "POST":
                    return self.reply(500) if stub.fail_work_item else self.reply(201, {"id": "i1"})
                if path == f"{item}i1/activities/":
                    return self.reply(200, {"results": [{"verb": "created"}]})
                if path == f"{item}i1/attachments/" and method == "POST":
                    return self.reply(200, {"asset_id": "a1", "upload_data": {"url": f"{stub.presign_scheme}://{stub.host}/uploads", "fields": {"key": "k"}}})
                if path == f"{item}i1/attachments/a1/":
                    if method == "GET":
                        return self.reply(302, headers=(("Location", f"{stub.presign_scheme}://{stub.host}/uploads/k?X-Amz-Signature=sig"),))
                    if method == "DELETE":
                        stub.asset_deleted = True
                    return self.reply(204)
                if path == "/uploads":
                    stub.stored = body.split(b"\r\n\r\n")[-1].rsplit(b"\r\n--", 1)[0]
                    return self.reply(204)
                if path == "/uploads/k":
                    return self.reply(200, stub.stored)
                return self.reply(404)

            def do_GET(self) -> None:
                self.answer("GET")

            def do_POST(self) -> None:
                self.answer("POST")

            def do_DELETE(self) -> None:
                self.answer("DELETE")

            def do_PATCH(self) -> None:
                self.answer("PATCH")

        return Handler


def hosted_run(directory: str, password: str = "right", **stub_options) -> tuple[Smoke, StubHosted, str]:
    """One run of the hosted flow against a stub, with what needs a real TLS or WebSocket server left out."""
    plane, plain = StubHosted(**stub_options), StubHosted(redirect_only=True)
    smoke = Smoke(parse_args(["--env", HOSTED, "--mode", "verify", "--host", plane.host, "--connect", f"127.0.0.1:{plane.port}",
                              "--http-port", str(plain.port), "--allow-untrusted-certificate", "--wait-seconds", "1", "--job-timeout", "2",
                              "--accounts", f"{directory}/a.env", "--sentinel", f"{directory}/s.json"]))
    smoke.credentials = ("someone@wayline.test", password)
    smoke.redact.add(password)
    smoke.http = Http(plane.host, "127.0.0.1", plane.port)
    for name in ("step_frontends", "step_routes", "step_csrf_enforced", "step_realtime_page", "step_realtime_auth", "step_realtime_denied", "step_realtime_sync"):
        setattr(smoke, name, lambda _: "left out here")
    with contextlib.redirect_stdout(io.StringIO()) as printed:
        smoke.run_verify()
    plane.server.shutdown()
    plain.server.shutdown()
    return smoke, plane, printed.getvalue()


def hosted_selftest() -> None:
    def status(smoke: Smoke, name: str) -> str:
        return next(step["status"] for step in smoke.steps if step["name"] == name)

    # What a whole run does: everything passes but the certificate, which this cannot check, so the run cannot read PASS.
    with tempfile.TemporaryDirectory() as directory:
        smoke, plane, printed = hosted_run(directory)
        assert status(smoke, "tls-certificate") == "BLOCKED" and smoke.overall() == "BLOCKED", printed
        assert all(step["status"] == "PASS" for step in smoke.steps if step["name"] != "tls-certificate"), printed
        assert not plane.token_live and not plane.project_live and plane.asset_deleted and plane.signed_out, printed
        assert "right" not in printed and "plane_api_secret" not in printed, printed
        forbidden = [call for call in plane.calls if "sign-up" in call or "/admins/" in call or call.endswith("/api/workspaces/")]
        assert not forbidden, forbidden
        assert plane.calls.index("POST /api/v1/workspaces/w/projects/") < plane.calls.index("DELETE /api/v1/workspaces/w/projects/p1/")
        assert not Path(f"{directory}/a.env").exists(), "this mode writes no accounts file"

    # A failure in the middle still removes what was made.
    with tempfile.TemporaryDirectory() as directory:
        smoke, plane, printed = hosted_run(directory, fail_work_item=True)
        assert status(smoke, "work-item") == "FAIL" and status(smoke, "attachment-upload") == "BLOCKED", printed
        assert status(smoke, "cleanup") == "PASS" and not plane.project_live and not plane.token_live, printed
        assert smoke.overall() == "FAIL"

    # What cannot be removed is named, and the rest still goes.
    with tempfile.TemporaryDirectory() as directory:
        smoke, plane, printed = hosted_run(directory, fail_project_delete=True)
        assert status(smoke, "cleanup") == "FAIL" and "could not remove: project" in printed and not plane.token_live, printed

    # The chart's http origin removes Secure, which is the fault this exists to catch.
    with tempfile.TemporaryDirectory() as directory:
        smoke, _, printed = hosted_run(directory, secure=False)
        assert status(smoke, "secure-cookies") == "FAIL" and "Secure" in printed, printed

    # An http presigned URL on an https page is a broken upload in every browser.
    with tempfile.TemporaryDirectory() as directory:
        smoke, plane, printed = hosted_run(directory, presign_scheme="http")
        assert status(smoke, "attachment-upload") == "FAIL" and not plane.project_live, printed

    # A refused account says nothing about the platform, and nothing gets made.
    with tempfile.TemporaryDirectory() as directory:
        smoke, plane, printed = hosted_run(directory, password="wrong")
        assert status(smoke, "sign-in") == "BLOCKED" and smoke.overall() == "BLOCKED" and "wrong" not in printed, printed
        assert not any(call.startswith("POST /api/users/api-tokens") for call in plane.calls), plane.calls

    # Full mode cannot start here, and neither can this flow without its account.
    with contextlib.redirect_stderr(io.StringIO()):
        try:
            parse_args(["--env", HOSTED, "--host", "h"])
        except SystemExit as stopped:
            assert stopped.code == 2
        else:
            raise AssertionError("--env hosted must refuse full mode")
        assert main(["--env", HOSTED, "--mode", "verify", "--host", "h"]) == 2


class StubPlane:
    """Upstream's instance route and admin forms over real HTTP, as far as instance-setup and branding-backend read them.
    GET caches by full path and both POSTs clear the bare key before the view runs, as cache_response and invalidate_cache
    do at v1.4.3. It knows nothing else of Plane, and a pass against it says nothing about the real server."""

    def __init__(self, *, set_up: bool = False, admin_password: str | None = None, changelog: str = "",
                 probe_during_sign_up: bool = False, drop_answer: bool = False) -> None:
        self.instance = {"is_setup_done": set_up, "instance_name": "Wayline", "is_telemetry_enabled": False,
                         "created_at": "2026-01-01T00:00:00Z"}
        self.changelog = changelog
        self.admin_password = admin_password
        self.probe_during_sign_up = probe_during_sign_up
        self.drop_answer = drop_answer
        self.cache: dict[str, bytes] = {}
        self.sign_ups = 0
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), self.handler())
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def answer(self) -> bytes:
        return json.dumps({"config": {"instance_changelog_url": self.changelog}, "instance": self.instance}).encode()

    def handler(self):
        stub = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_) -> None:
                pass

            def reply(self, status: int, body: bytes = b"", headers: tuple = ()) -> None:
                self.send_response(status)
                for name, value in headers:
                    self.send_header(name, value)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self) -> None:
                if self.path == "/auth/get-csrf-token/":
                    self.reply(200, b'{"csrf_token": "stub"}', (("Set-Cookie", "csrftoken=stub; Path=/"),))
                elif self.path.startswith("/api/instances/"):
                    self.reply(200, stub.cache.setdefault(self.path, stub.answer()))
                else:
                    self.reply(200, b"<html></html>")

            def signed_in(self) -> None:
                self.reply(302, headers=(("Location", "http://stub/god-mode/general/"),
                                         ("Set-Cookie", "admin-session-id=stub; Path=/")))

            def refused(self, message: str) -> None:
                self.reply(302, headers=(("Location", f"http://stub/god-mode/?error_code=5000&error_message={message}"),))

            def do_POST(self) -> None:
                fields = parse_qs(self.rfile.read(int(self.headers["Content-Length"])).decode())
                stub.cache.pop("/api/instances/", None)
                if self.path.endswith("/sign-in/"):
                    if stub.admin_password is None:
                        self.refused("ADMIN_USER_DOES_NOT_EXIST")
                    elif fields["password"] == [stub.admin_password]:
                        self.signed_in()
                    else:
                        self.refused("ADMIN_AUTHENTICATION_FAILED")
                    return
                stub.sign_ups += 1
                if stub.probe_during_sign_up:
                    stub.cache["/api/instances/"] = stub.answer()
                if stub.instance["is_setup_done"] or stub.admin_password is not None:
                    self.refused("ADMIN_ALREADY_EXIST")
                    return
                stub.admin_password = fields["password"][0]
                stub.instance.update(is_setup_done=True, instance_name=fields["company_name"][0],
                                     is_telemetry_enabled=fields["is_telemetry_enabled"][0] == "True")
                if stub.drop_answer:
                    self.close_connection = True
                    return
                self.signed_in()

        return Handler


def selftest() -> int:
    """Checks the hand-written protocol code with no cluster. It proves nothing about Plane."""
    # Frame bytes asserted by the research probe, which matched the Hocuspocus source.
    assert auth_frame("d", "t") == bytes([1, 0x64, 2, 0, 1, 0x74])
    assert read_varstring(varstring("x" * 300), 0)[0] == "x" * 300
    # RFC 6455 section 1.3 example.
    assert ws_accept("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    # RFC 6455 section 5.7 masked "Hello".
    assert ws_encode(0x1, b"Hello", bytes.fromhex("37fa213d")) == bytes.fromhex("818537fa213d7f9f4d5158")
    # Bytes from Y.encodeStateAsUpdate in yjs 13.6.27, run in the plane-live v1.4.3 image, for
    # <paragraph>héllo wayline</paragraph> in fragment `default` with client id 1234567.
    assert yjs_paragraph_update(1234567, "h\u00e9llo wayline") == bytes.fromhex(
        "010387ad4b0007010764656661756c740309706172616772617068070087ad4b0006040087ad4b010e68c3a96c6c6f207761796c696e6500"
    )
    assert sync_frame("d", Y_SYNC_STEP1, Y_EMPTY_STATE_VECTOR) == bytes([1, 0x64, 0, 0, 1, 0])

    content_type, body = multipart({"key": "k", "policy": "p"}, "a.txt", "text/plain", b"DATA")
    boundary = content_type.split("boundary=")[1]
    assert body.index(b'name="policy"') < body.index(b'name="file"')
    assert body.endswith(f"--{boundary}--\r\n".encode())

    redact = Redactor()
    redact.add("hunter2hunter2")
    assert "hunter2" not in redact("password=hunter2hunter2")
    assert "abc123" not in redact("token plane_api_abc123")
    assert "SIG" not in redact("http://h/u?X-Amz-Signature=SIG&x=1")
    assert "ROOTUSER" not in redact("<AWSAccessKeyId>ROOTUSER</AWSAccessKeyId>")

    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "accounts.env"
        accounts = Accounts(path, "prod-sim")
        accounts.set(ADMIN_PASSWORD="value")
        assert path.stat().st_mode & 0o777 == 0o600
        assert Accounts(path, "prod-sim").get("ADMIN_PASSWORD") == "value"
        assert Accounts(path, "dev").get("ADMIN_PASSWORD") is None

        # Two runs that both read the file before either wrote it, which used to lose the first one's token.
        first, second = Accounts(path, "dev"), Accounts(path, "prod-sim")
        first.set(API_TOKEN="from-dev")
        second.set(API_TOKEN="from-prod-sim")
        assert Accounts(path, "dev").get("API_TOKEN") == "from-dev"
        assert Accounts(path, "prod-sim").get("API_TOKEN") == "from-prod-sim"
        assert Accounts(path, "prod-sim").get("ADMIN_PASSWORD") == "value"

        # The same, really at once. Each thread opens the lock file itself, so they exclude each other as processes do.
        def write(env: str, number: int) -> None:
            Accounts(path, env).set(**{f"KEY_{number}": str(number)})

        writers = [threading.Thread(target=write, args=(env, number)) for number in range(25) for env in ("dev", "prod-sim")]
        for writer in writers:
            writer.start()
        for writer in writers:
            writer.join()
        for env in ("dev", "prod-sim"):
            assert all(Accounts(path, env).get(f"KEY_{number}") == str(number) for number in range(25)), env
        assert path.stat().st_mode & 0o777 == 0o600

    overlay = """images:
- digest: sha256:aaa
  name: artifacts.plane.so/makeplane/plane-frontend
  newName: localhost:5001/wayline/web
- digest: sha256:bbb
  name: artifacts.plane.so/makeplane/plane-backend
  newName: docker.io/makeplane/plane-backend
  newTag: v1.4.3
"""
    assert set(branded_images("kind: Kustomization\n" + overlay)) == {"web"}
    assert branded_images("kind: Kustomization\n" + overlay)["web"]["digest"] == "sha256:aaa"
    assert parse_overlay_images("kind: Kustomization\n" + overlay)["artifacts.plane.so/makeplane/plane-backend"]["newTag"] == "v1.4.3"
    assert branded_images("kind: Kustomization\n") == {}
    assert configured_source_repo().startswith("https://")

    good = "<head><title>Wayline | Project management</title></head><p>Built on Plane Community Edition</p>"
    assert brand_problems("/", good) == []
    assert any("title" in problem for problem in brand_problems("/", "<title>Plane | Project management</title>"))
    assert any("title" in problem for problem in brand_problems("/", "<title>Wayline, a Plane fork</title>"))
    assert any("does not name" in problem for problem in brand_problems("/", "<p>no title</p>"))
    assert any("upstream brand" in problem for problem in brand_problems("/", "<title>Wayline</title><a href=x>https://plane.so</a>"))
    assert UPSTREAM_NAME.search("plane-dev plane_api plane.dev.localhost Airplane") is None

    # A skipped step counts neither way, and says why.
    with tempfile.TemporaryDirectory() as directory:
        smoke = Smoke(parse_args(["--accounts", f"{directory}/a.env", "--sentinel", f"{directory}/s.json"]))

        def skipped(_: dict) -> str:
            raise StepSkipped("does not apply")

        with contextlib.redirect_stdout(io.StringIO()) as printed:
            smoke.run("passes", lambda _: "ok")
            smoke.run("skipped", skipped)
        assert "SKIP    skipped  does not apply" in printed.getvalue()
        assert smoke.overall() == "PASS"
        assert "skipped" not in smoke.passed
        with contextlib.redirect_stdout(io.StringIO()):
            smoke.run("blocked", lambda _: (_ for _ in ()).throw(StepBlocked("no")))
        assert smoke.overall() == "BLOCKED"

    # Pods of an older template can still serve, whatever the template says now.
    finished = {"metadata": {"generation": 2}, "spec": {"replicas": 1},
                "status": {"observedGeneration": 2, "updatedReplicas": 1, "replicas": 1, "availableReplicas": 1}}
    assert rollout_unfinished(finished) is None
    for field, value, reason in (("observedGeneration", 1, "generation"), ("updatedReplicas", 0, "new template"),
                                 ("replicas", 2, "old replicas"), ("availableReplicas", 0, "available"),
                                 ("terminatingReplicas", 1, "terminating")):
        assert reason in rollout_unfinished({**finished, "status": {**finished["status"], field: value}}), field
    assert rollout_unfinished({**finished, "status": {**finished["status"], "terminatingReplicas": 0}}) is None

    # Which of those will end by waiting, as the Deployment controller and a StatefulSet's revisions say it.
    def progressing(status: str, reason: str) -> dict:
        return {"metadata": {"generation": 2}, "status": {"observedGeneration": 2,
                "conditions": [{"type": "Available", "status": "True", "reason": "MinimumReplicasAvailable"},
                               {"type": "Progressing", "status": status, "reason": reason}]}}

    assert rollout_under_way(progressing("True", "ReplicaSetUpdated"))
    assert not rollout_under_way(progressing("False", "ProgressDeadlineExceeded"))
    assert not rollout_under_way(progressing("True", "NewReplicaSetAvailable"))
    assert rollout_under_way({"metadata": {"generation": 3}, "status": {"observedGeneration": 2}})
    assert rollout_under_way({"kind": "StatefulSet", "status": {"currentRevision": "a", "updateRevision": "b"}})
    assert not rollout_under_way({"kind": "StatefulSet", "status": {"currentRevision": "a", "updateRevision": "a"}})

    # What workloads-ready reads during a rollout, and so what the run does, with kubectl stubbed.
    def workloads_run(web: dict, sync_health: str, operation: dict | None = None, state: dict | None = None,
                      job: dict | None = None) -> tuple[Smoke, str]:
        complete = {"replicas": 1, "readyReplicas": 1, "conditions": [{"type": "Progressing", "status": "True", "reason": "NewReplicaSetAvailable"}]}
        listed = [{"kind": kind, "metadata": {"name": name}, "spec": {"replicas": 1},
                   "status": {**complete, **(web if name == "plane-web-wl" else {})}} for kind, name in WORKLOADS]
        listed.append({"kind": "Job", "metadata": {"name": MIGRATOR_JOB}, "spec": {}, "status": {"succeeded": 1} if job is None else job})
        sync, health = sync_health.split("/")
        app = {**({"operation": operation} if operation else {}), "status": {"sync": {"status": sync}, "health": {"status": health},
                                                                             **({"operationState": state} if state else {})}}

        with tempfile.TemporaryDirectory() as directory:
            smoke = Smoke(parse_args(["--accounts", f"{directory}/a.env", "--sentinel", f"{directory}/s.json"]))
        smoke.cluster.in_namespace = lambda *args, **_: json.dumps({"items": listed if "deployments,statefulsets,jobs" in args else []})
        smoke.cluster.run = lambda *_, **__: json.dumps(app)
        with contextlib.redirect_stdout(io.StringIO()) as printed:
            smoke.run("reachable", lambda _: "ok")
            smoke.run("workloads-ready", smoke.step_workloads)
        return smoke, printed.getvalue()

    rolling = {"conditions": [{"type": "Progressing", "status": "True", "reason": "ReplicaSetUpdated"}]}
    for web, sync_health, operation, verdict in (
        ({}, "Synced/Healthy", None, "PASS"),
        ({"readyReplicas": 2, **rolling}, "Synced/Progressing", None, "BLOCKED"),
        ({"readyReplicas": 0, **rolling}, "Synced/Progressing", {"sync": {}}, "BLOCKED"),
        ({}, "OutOfSync/Healthy", {"sync": {}}, "BLOCKED"),
        ({}, "OutOfSync/Healthy", None, "FAIL"),
        ({"readyReplicas": 0}, "Synced/Progressing", None, "FAIL"),
        ({"conditions": [{"type": "Progressing", "status": "False", "reason": "ProgressDeadlineExceeded"}]}, "Synced/Degraded", {"sync": {}}, "FAIL"),
        ({"readyReplicas": 0, "conditions": [{"type": "Progressing", "status": "False", "reason": "ProgressDeadlineExceeded"}]}, "Synced/Progressing", None, "FAIL"),
    ):
        smoke, printed = workloads_run(web, sync_health, operation)
        assert verdict + " " in printed.splitlines()[-1] and smoke.overall() == verdict, (web, sync_health, printed)

    # Under retry.limit -1 a sync that fails every attempt never closes, so an open one is not always a rollout.
    message = "one or more synchronization tasks completed unsuccessfully"
    hook_failed = {"conditions": [{"type": "Failed", "status": "True", "reason": "BackoffLimitExceeded"}]}
    for web, sync_health, operation, state, job, verdict, says in (
        ({}, "OutOfSync/Healthy", {"sync": {}}, {"phase": "Running"}, None, "BLOCKED", "under way"),
        ({}, "OutOfSync/Healthy", {"sync": {}}, {"phase": "Running", "retryCount": 0}, None, "BLOCKED", "under way"),
        ({}, "OutOfSync/Healthy", {"sync": {}}, {"phase": "Succeeded", "retryCount": 2}, None, "BLOCKED", "under way"),
        ({}, "OutOfSync/Healthy", {"sync": {}}, {"phase": "Running", "retryCount": 9, "message": message}, None, "FAIL", message),
        ({}, "Synced/Healthy", {"sync": {}}, {"phase": "Running", "retryCount": 1}, None, "FAIL", "failed 1 time(s)"),
        ({}, "OutOfSync/Healthy", {"sync": {}}, {"phase": "Running", "retryCount": 3, "message": message}, {}, "FAIL", "has not succeeded"),
        ({}, "OutOfSync/Healthy", {"sync": {}}, {"phase": "Running"}, {}, "BLOCKED", "has not succeeded"),
        ({}, "OutOfSync/Healthy", {"sync": {}}, {"phase": "Running"}, hook_failed, "FAIL", "has not succeeded"),
        ({"readyReplicas": 0, **rolling}, "Synced/Progressing", {"sync": {}}, {"phase": "Running", "retryCount": 2}, None, "FAIL", "0/1 ready"),
    ):
        smoke, printed = workloads_run(web, sync_health, operation, state, job)
        assert verdict + " " in printed.splitlines()[-1] and smoke.overall() == verdict and says in printed, (state, job, printed)

    # The sentinel a clean install finds from before it, with HTTP and kubectl stubbed. It says nothing about Plane.
    def sentinel_run(found: dict, namespace_created: str) -> tuple[Smoke, str, dict]:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sentinel.json"
            path.write_text(json.dumps({"slug": "sentinel-old", "work_item_id": "old", "created_at": "2026-05-01T00:00:00Z"}))
            smoke = Smoke(parse_args(["--accounts", f"{directory}/a.env", "--sentinel", str(path)]))
            smoke.state["instance"] = found
            smoke.cluster.run = lambda *_, **__: json.dumps({"metadata": {"creationTimestamp": namespace_created}})
            smoke.create_workspace = lambda *_: None
            smoke.create_project = lambda *_: {"id": "new-project"}
            smoke.create_work_item = lambda *_: "new"
            smoke.upload_attachment = lambda *_: "new-asset"
            with contextlib.redirect_stdout(io.StringIO()) as printed:
                smoke.run("sentinel-create", smoke.step_sentinel_create)
            return smoke, printed.getvalue(), json.loads(path.read_text())

    newer, older = "2026-06-01T00:00:00Z", "2026-04-01T00:00:00Z"
    _, printed, record = sentinel_run({"is_setup_done": False}, newer)
    assert printed.startswith("PASS") and "Replaced" in printed and "sentinel-old" in printed and record["work_item_id"] == "new", printed
    for found in ({"is_setup_done": True}, {}):
        _, printed, record = sentinel_run(found, newer)
        assert "reusing existing sentinel" in printed and record["work_item_id"] == "old", printed
    smoke, printed, record = sentinel_run({"is_setup_done": False}, older)
    assert printed.startswith("FAIL") and "data was lost" in printed and record["work_item_id"] == "old", printed
    assert smoke.overall() == "FAIL"

    # The old record is gone before the new one is made, so a failure to make it has to say so.
    def refused_workspace(*_) -> None:
        raise StepFailed("POST /api/workspaces/ answered 500")

    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "sentinel.json"
        path.write_text(json.dumps({"slug": "sentinel-old", "work_item_id": "old", "created_at": "2026-05-01T00:00:00Z"}))
        smoke = Smoke(parse_args(["--accounts", f"{directory}/a.env", "--sentinel", str(path)]))
        smoke.state["instance"] = {"is_setup_done": False}
        smoke.cluster.run = lambda *_, **__: json.dumps({"metadata": {"creationTimestamp": newer}})
        smoke.create_workspace = refused_workspace
        with contextlib.redirect_stdout(io.StringIO()) as printed:
            smoke.run("sentinel-create", smoke.step_sentinel_create)
        assert printed.getvalue().startswith("FAIL") and "Replaced" in printed.getvalue() and "sentinel-old" in printed.getvalue(), printed.getvalue()
        assert "answered 500" in printed.getvalue() and not path.exists(), printed.getvalue()

    # The instance route's two-hour key, in each way it goes stale. See StubPlane.
    def setup_run(plane: StubPlane, directory: str) -> tuple[Smoke, str]:
        smoke = Smoke(parse_args(["--connect", f"127.0.0.1:{plane.port}", "--accounts", f"{directory}/a.env",
                                  "--sentinel", f"{directory}/s.json", "--wait-seconds", "1"]))
        with contextlib.redirect_stdout(io.StringIO()) as printed:
            smoke.run("reachable", smoke.step_reachable)
            smoke.run("instance-setup", smoke.step_instance_setup, ("reachable",))
        return smoke, printed.getvalue()

    def stored(directory: str, key: str) -> str | None:
        return Accounts(Path(f"{directory}/a.env"), "dev").get(key)

    with tempfile.TemporaryDirectory() as directory:
        # A probe during this sign-up fills the bare key with the false from before it. The admin exists, so this passes.
        plane = StubPlane(probe_during_sign_up=True)
        smoke, printed = setup_run(plane, directory)
        assert "PASS    instance-setup  admin created" in printed and plane.sign_ups == 1, printed
        assert json.loads(plane.cache["/api/instances/"])["instance"]["is_setup_done"] is False, "the stub lost the race"
        assert stored(directory, "ADMIN_PASSWORD") == plane.admin_password and stored(directory, "ADMIN_PASSWORD_PENDING") is None

        # The next run reads that stale false, and it must not spend the one-shot sign-up or the password on it.
        before = stored(directory, "ADMIN_PASSWORD")
        smoke, printed = setup_run(plane, directory)
        assert "PASS    instance-setup  already set up" in printed and plane.sign_ups == 1, printed
        assert stored(directory, "ADMIN_PASSWORD") == before == plane.admin_password
        assert smoke.state["instance"]["is_setup_done"] is True
        plane.server.shutdown()

        # A refused POST, on a database whose flag and admin disagree. What is stored stays, and nothing waits beside it.
        plane = StubPlane(admin_password=before)
        smoke, printed = setup_run(plane, directory)
        assert "FAIL    instance-setup" in printed and "ADMIN_ALREADY_EXIST" in printed and "keeps what it held" in printed, printed
        assert plane.sign_ups == 1 and stored(directory, "ADMIN_PASSWORD") == before and stored(directory, "ADMIN_PASSWORD_PENDING") is None, printed
        plane.server.shutdown()

    with tempfile.TemporaryDirectory() as directory:
        # A crash right after a sign-up that went through: no answer, and the password is not lost. The next run settles it.
        plane = StubPlane(drop_answer=True)
        smoke, printed = setup_run(plane, directory)
        assert "FAIL    instance-setup" in printed and "pending" in printed and plane.admin_password not in printed, printed
        assert stored(directory, "ADMIN_PASSWORD_PENDING") == plane.admin_password and stored(directory, "ADMIN_PASSWORD") is None
        plane.drop_answer = False
        smoke, printed = setup_run(plane, directory)
        assert "PASS    instance-setup  already set up" in printed and plane.sign_ups == 1, printed
        assert stored(directory, "ADMIN_PASSWORD") == plane.admin_password and stored(directory, "ADMIN_PASSWORD_PENDING") is None
        kept = stored(directory, "ADMIN_PASSWORD")
        plane.server.shutdown()

        # A pending password the instance does not hold is dropped, and what was stored stays.
        Accounts(Path(f"{directory}/a.env"), "dev").set(ADMIN_PASSWORD_PENDING="not-the-password")
        plane = StubPlane(set_up=True, admin_password=kept)
        smoke, printed = setup_run(plane, directory)
        assert "PASS    instance-setup  already set up" in printed and plane.sign_ups == 0, printed
        assert stored(directory, "ADMIN_PASSWORD") == kept and stored(directory, "ADMIN_PASSWORD_PENDING") is None
        plane.server.shutdown()

        # Still not set up after a crash: that sign-up did not go through, so this run makes the admin, and only it is stored.
        Accounts(Path(f"{directory}/a.env"), "dev").set(ADMIN_PASSWORD_PENDING="from-a-run-that-crashed")
        plane = StubPlane()
        smoke, printed = setup_run(plane, directory)
        assert "PASS    instance-setup  admin created" in printed and plane.sign_ups == 1, printed
        assert stored(directory, "ADMIN_PASSWORD") == plane.admin_password != "from-a-run-that-crashed" and stored(directory, "ADMIN_PASSWORD_PENDING") is None
        plane.server.shutdown()

    # branding-backend, with the previous image's answer in the bare key each way round.
    for in_the_bare_key, from_this_image, verdict in (("https://sites.plane.so/x", "", "PASS"), ("", "https://sites.plane.so/x", "FAIL")):
        plane = StubPlane(set_up=True, changelog=from_this_image)
        plane.cache["/api/instances/"] = json.dumps({"instance": plane.instance, "config": {"instance_changelog_url": in_the_bare_key}}).encode()
        with tempfile.TemporaryDirectory() as directory:
            smoke = Smoke(parse_args(["--connect", f"127.0.0.1:{plane.port}", "--accounts", f"{directory}/a.env", "--sentinel", f"{directory}/s.json"]))
        smoke.state["branded"] = {"backend": {}}
        with contextlib.redirect_stdout(io.StringIO()) as printed:
            smoke.run("branding-backend", smoke.step_branding_backend)
        assert printed.getvalue().startswith(verdict), printed.getvalue()
        plane.server.shutdown()

    # A tiny server that plays Hocuspocus, so the client's framing runs over a real socket. It knows
    # nothing of Plane, and a pass here says nothing about the real server.
    server = socket.socket()
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    port = server.getsockname()[1]
    failures: list[str] = []

    def serve() -> None:
        connection, _ = server.accept()
        request = b""
        while b"\r\n\r\n" not in request:
            request += connection.recv(4096)
        key = re.search(rb"Sec-WebSocket-Key: (\S+)", request).group(1).decode()
        connection.sendall(
            ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
             f"Sec-WebSocket-Accept: {ws_accept(key)}\r\n\r\n").encode()
        )
        frame = connection.recv(4096)
        mask, payload = frame[2:6], frame[6:]
        received = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        if received != auth_frame("doc", "tok"):
            failures.append("server received a different auth frame")
        unrelated = varstring("doc") + uvarint(0) + uvarint(0)
        reply = varstring("doc") + uvarint(HP_MSG_AUTH) + uvarint(HP_AUTH_OK) + varstring("read-write")
        connection.sendall(bytes([0x82, len(unrelated)]) + unrelated + bytes([0x82, len(reply)]) + reply)

        def unmask(frame: bytes) -> bytes:
            return bytes(b ^ frame[2 + i % 4] for i, b in enumerate(frame[6:]))

        if unmask(connection.recv(4096)) != sync_frame("doc", Y_SYNC_STEP1, Y_EMPTY_STATE_VECTOR):
            failures.append("server received a different step 1")
        replies = [sync_frame("doc", Y_SYNC_STEP2, b"WHOLE-DOCUMENT"), sync_frame("doc", Y_SYNC_STEP1, b"\x00")]
        for message in replies:
            connection.sendall(bytes([0x82, len(message)]) + message)
        if unmask(connection.recv(4096)) != sync_frame("doc", Y_SYNC_STEP2, Y_EMPTY_UPDATE):
            failures.append("server received a different step 2")
        status = varstring("doc") + uvarint(HP_MSG_SYNC_STATUS) + uvarint(1)
        connection.sendall(bytes([0x82, len(status)]) + status)
        if unmask(connection.recv(4096)) != sync_frame("doc", Y_SYNC_UPDATE, b"U"):
            failures.append("server received a different update")
        connection.sendall(bytes([0x82, len(status)]) + status)
        update = sync_frame("doc", Y_SYNC_UPDATE, b"MARKER")
        connection.sendall(bytes([0x82, len(update)]) + update)
        connection.close()

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    ws = WebSocket("127.0.0.1", port, "plane.dev.localhost", "/live/collaboration", "session-id=x")
    assert collaboration_auth(ws, "doc", "tok") == ("Authenticated", "read-write")
    collaborator = Collaborator(ws, "doc")
    assert collaborator.first_sync(5) == b"WHOLE-DOCUMENT"
    collaborator.send_update(b"U", 5)
    assert collaborator.wait_for_update(b"MARKER", 5) == b"MARKER"
    thread.join(5)
    server.close()
    assert not failures, failures
    hosted_selftest()
    print("selftest ok")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--env", choices=sorted(HOSTS) + [HOSTED], default="dev",
                        help="environment under test (default: dev). hosted needs --mode verify, --host and --credentials-stdin")
    parser.add_argument("--mode", choices=["full", "verify"], default="full",
                        help="full: the whole flow. verify: only re-read the persistence sentinel, or with --env hosted, "
                             "the https flow on an existing account (default: full)")
    parser.add_argument("--evidence", help="where to write the JSON evidence, which holds no secrets "
                                           "(default: .local/evidence-raw/smoke-<env>-<run>.json)")
    parser.add_argument("--host", help="public host override (default: per --env)")
    parser.add_argument("--connect", default="127.0.0.1:80", help="address Traefik is published on (default: %(default)s)")
    parser.add_argument("--accounts", default=str(LOCAL_DIR / "test-accounts.env"),
                        help="credentials file, kept at mode 0600 (default: .local/test-accounts.env)")
    parser.add_argument("--sentinel", help="sentinel record (default: .local/test-sentinel-<env>.json)")
    parser.add_argument("--reset-sentinel", action="store_true", help="replace an existing sentinel with a new one")
    parser.add_argument("--job-probe", action="store_true",
                        help="in verify mode, also create a work item and wait for its background activity")
    parser.add_argument("--soak-seconds", type=int, default=0,
                        help="in full mode, also hold two idle document connections this long, then deliver an update")
    parser.add_argument("--worker-negative-control", action="store_true",
                        help="in full mode, also stop the worker consuming for about 20s and show the job waits for it, "
                             "then replace the worker's pod, because that control leaves it unable to survive a broker reconnect")
    parser.add_argument("--branding", choices=["auto", "require", "off"], default="auto",
                        help="auto: check an image's branding if the environment's overlay names the Wayline image, and SKIP "
                             "otherwise. require: check every image whatever the overlay says, which on upstream's images "
                             "shows these checks can fail. off: leave them out (default: %(default)s)")
    parser.add_argument("--job-timeout", type=int, default=120, help="seconds to wait for a background job (default: 120)")
    parser.add_argument("--wait-seconds", type=int, default=180,
                        help="seconds to tolerate a restarting backend on reads (default: 180)")
    parser.add_argument("--credentials-stdin", action="store_true", help="with --env hosted: read email and password, one line each, from stdin")
    parser.add_argument("--workspace", help="with --env hosted: the workspace to work in, which must exist (default: the account's first)")
    parser.add_argument("--http-port", type=int, default=80, help="with --env hosted: the port the redirect to https answers on (default: %(default)s)")
    parser.add_argument("--ca-file", help="with --env hosted: trust these roots in place of the system's")
    parser.add_argument("--allow-untrusted-certificate", action="store_true",
                        help="with --env hosted: run with a staging certificate. Nothing checks it, so the run cannot read PASS")
    parser.add_argument("--selftest", action="store_true", help="check the protocol code offline, then exit")
    args = parser.parse_args(argv)
    if args.env == HOSTED:
        # Full mode creates users and claims the admin, so it never runs here.
        if args.mode != "verify":
            parser.error("--env hosted runs only --mode verify: full mode creates users and claims the admin")
        if not args.host:
            parser.error("--env hosted needs --host")
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.selftest:
        return selftest()
    if args.env == HOSTED and not args.credentials_stdin:
        print("--env hosted signs in with an existing account, so it needs --credentials-stdin", file=sys.stderr)
        return 2
    smoke = Smoke(args)
    started_at = now_iso()
    print(f"smoke: environment={args.env} host={smoke.host} connect={args.connect} mode={args.mode}", flush=True)
    if args.mode == "verify":
        smoke.run_verify()
    else:
        smoke.run_full()
    smoke.write_evidence(started_at)
    result = smoke.overall()
    print(f"RESULT  {result}", flush=True)
    return {"PASS": 0, "FAIL": 1, "BLOCKED": 2}[result]


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
