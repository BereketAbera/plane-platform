#!/usr/bin/env python3
"""End-to-end smoke test of a running Plane environment, through Traefik, over real HTTP.

Standard library only, so it runs on a clean host and in any CI image.

Every line of output is PASS, FAIL or BLOCKED. BLOCKED means a step could not run because
something it depends on did not pass, so it is neither evidence of working nor of broken.

Exit status: 0 all passed, 1 at least one FAIL, 2 no FAIL but something was BLOCKED.

Generated credentials go only to .local/test-accounts.env (mode 0600). They are never printed
and never written to the evidence file.
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import http.client
import json
import os
import re
import secrets
import socket
import struct
import sys
import tempfile
import threading
import time
import uuid
from http.cookies import SimpleCookie
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlsplit

ROOT = Path(__file__).resolve().parents[2]
LOCAL_DIR = ROOT / ".local"
HOSTS = {"dev": "plane.dev.localhost", "prod-sim": "plane.prod-sim.localhost"}
ADMIN_EMAIL = "smoke-admin@wayline.test"

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
# Hocuspocus 2.15 wire values, confirmed against its source in the research.
HP_MSG_AUTH = 2
HP_AUTH_TOKEN = 0
HP_AUTH_DENIED = 1
HP_AUTH_OK = 2
CSRF_FAILURE_TITLE = b"CSRF Verification Failed"


class StepFailed(Exception):
    """The step ran and the system misbehaved."""


class StepBlocked(Exception):
    """The step cannot run, which says nothing about the system under test."""


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


class Http:
    """A small client that always dials the Traefik address, whatever host a URL names.

    A presigned URL carries the public host, and the signature covers it, so the Host header
    must stay as signed while the TCP connection goes to the published port.
    """

    def __init__(self, host: str, connect_host: str, connect_port: int, timeout: float = 30) -> None:
        self.host = host
        self.connect_host = connect_host
        self.connect_port = connect_port
        self.timeout = timeout
        self.cookies: dict[str, str] = {}

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

    def request(self, method: str, target: str, *, headers: dict | None = None, body: bytes | None = None,
                session: bool = True, host: str | None = None) -> Response:
        request_headers = {"Host": host or self.host, "User-Agent": "wayline-smoke/1", "Connection": "close",
                           "Accept": "application/json"}
        request_headers.update(headers or {})
        if session and self.cookies:
            request_headers["Cookie"] = self.cookie_header()
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
        headers = {"Content-Type": "application/x-www-form-urlencoded", "Origin": f"http://{self.host}",
                   "Referer": f"http://{self.host}/", **kwargs.pop("headers", {})}
        return self.request("POST", target, headers=headers, body=urlencode(fields).encode(), **kwargs)


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
                 timeout: float = 15) -> None:
        self.sock = socket.create_connection((connect_host, connect_port), timeout=timeout)
        self.buffer = b""
        key = base64.b64encode(secrets.token_bytes(16)).decode()
        request = (
            f"GET {target} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nOrigin: http://{host}\r\n"
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

    def receive(self) -> bytes:
        message = b""
        while True:
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
                self.sock.sendall(ws_encode(0xA, payload))
                continue
            if opcode == 0xA:
                continue
            message += payload
            if fin:
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


# --- Local state ---------------------------------------------------------------------------------


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
    """KEY=value file holding generated test credentials for both environments."""

    def __init__(self, path: Path, env: str) -> None:
        self.path = path
        self.prefix = "PLANE_" + env.upper().replace("-", "_") + "_"
        self.values: dict[str, str] = {}
        if path.exists():
            if path.stat().st_mode & 0o077:
                os.chmod(path, 0o600)
            for line in path.read_text().splitlines():
                key, separator, value = line.partition("=")
                if separator and not key.startswith("#"):
                    self.values[key] = value

    def get(self, key: str) -> str | None:
        return self.values.get(self.prefix + key)

    def set(self, **pairs: str) -> None:
        for key, value in pairs.items():
            self.values[self.prefix + key] = value
        lines = ["# Generated by tests/e2e/smoke.py. Test credentials only. Never commit."]
        lines += [f"{key}={value}" for key, value in sorted(self.values.items())]
        write_private(self.path, "\n".join(lines) + "\n")


# --- The run -------------------------------------------------------------------------------------


class Smoke:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.host = args.host or HOSTS[args.env]
        connect_host, _, connect_port = args.connect.partition(":")
        self.connect_host = connect_host
        self.connect_port = int(connect_port or 80)
        self.http = Http(self.host, self.connect_host, self.connect_port)
        self.redact = Redactor()
        self.accounts = Accounts(Path(args.accounts), args.env)
        self.redact.add(self.accounts.get("ADMIN_PASSWORD"))
        self.redact.add(ADMIN_EMAIL)
        self.redact.add(self.accounts.get("ADMIN_EMAIL"))
        self.redact.add(self.accounts.get("API_TOKEN"))
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
        counts = {s: sum(1 for step in self.steps if step["status"] == s) for s in ("PASS", "FAIL", "BLOCKED")}
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

    def csrf(self) -> str:
        """The cookie is HttpOnly in a browser, so the token comes from this endpoint."""
        response = expect(self.http.get("/auth/get-csrf-token/"), 200)
        token = response.json().get("csrf_token")
        if not token or "csrftoken" not in self.http.cookies:
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

    # -- steps --

    def step_reachable(self, data: dict) -> str:
        web = self.retrying_get("/", session=False)
        expect(web, 200)
        instance = self.retrying_get("/api/instances/", session=False)
        expect(instance, 200)
        payload = instance.json()
        self.state["instance"] = payload.get("instance", payload)
        data["web_status"], data["instances_status"] = web.status, instance.status
        return f"web 200, /api/instances/ 200 via {self.host}"

    def step_instance_setup(self, data: dict) -> str:
        instance = self.state["instance"]
        data["was_setup_done"] = bool(instance.get("is_setup_done"))
        if instance.get("is_setup_done"):
            if not (self.accounts.get("ADMIN_EMAIL") and self.accounts.get("ADMIN_PASSWORD")):
                raise StepBlocked(
                    "instance is already set up and .local/test-accounts.env has no credentials for it. "
                    "Admin sign-up is one-shot, so restore that file or reset this environment."
                )
            return "already set up, reusing stored admin"

        # Saved before the POST: sign-up is one-shot, so a crash right after it must not lose them.
        password = secrets.token_hex(24)
        self.redact.add(password)
        self.accounts.set(ADMIN_EMAIL=ADMIN_EMAIL, ADMIN_PASSWORD=password)

        # Telemetry defaults to on and reports to telemetry.plane.so. The UI always submits true,
        # so only this path can turn it off at creation.
        response = self.http.post_form("/api/instances/admins/sign-up/", {
            "csrfmiddlewaretoken": self.csrf(), "email": ADMIN_EMAIL, "password": password,
            "first_name": "Smoke", "last_name": "Admin", "company_name": "Wayline",
            "is_telemetry_enabled": "False",
        })
        # Form endpoints always answer 302, and report failure only in the Location query string.
        expect(response, 302)
        self.assert_no_auth_error(response)
        if not urlsplit(response.location).path.endswith("/god-mode/general/"):
            raise StepFailed(f"unexpected redirect target: {urlsplit(response.location).path}")
        if "admin-session-id" not in self.http.cookies:
            raise StepFailed("sign-up did not set admin-session-id")

        after = expect(self.http.get("/api/instances/", session=False), 200).json()
        after = after.get("instance", after)
        if not after.get("is_setup_done"):
            raise StepFailed("is_setup_done is still false after admin sign-up")
        data["is_telemetry_enabled"] = after.get("is_telemetry_enabled")
        if after.get("is_telemetry_enabled") is not False:
            raise StepFailed(f"telemetry should be off, instance reports {after.get('is_telemetry_enabled')!r}")
        return "admin created, telemetry off"

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

    def create_project(self, slug: str, label: str) -> str:
        # Not the first five letters of the workspace name: the workspace_seed task takes that
        # identifier for itself and would race this request.
        identifier = "P" + secrets.token_hex(3).upper()
        response = self.http.send_json("POST", f"/api/v1/workspaces/{slug}/projects/",
                                       {"name": f"{label} {identifier}", "identifier": identifier},
                                       session=False, headers=self.api())
        return expect(response, 201).json()["id"]

    def create_work_item(self, base: str, name: str) -> str:
        response = self.http.send_json("POST", f"{base}/work-items/", {"name": name},
                                       session=False, headers=self.api())
        return expect(response, 201).json()["id"]

    def step_project(self, data: dict) -> str:
        self.state["project_id"] = self.create_project(self.state["slug"], "Platform")
        data["project_id"] = self.state["project_id"]
        return self.state["project_id"]

    def step_work_item(self, data: dict) -> str:
        self.state["work_item_id"] = self.create_work_item(self.base(), f"smoke {self.run_id}")
        data["work_item_id"] = self.state["work_item_id"]
        return self.state["work_item_id"]

    def step_list(self, data: dict) -> str:
        results = expect(self.http.get(f"{self.base()}/work-items/", session=False, headers=self.api()), 200).json()
        ids = [item["id"] for item in results.get("results", [])]
        data["listed"] = len(ids)
        if self.state["work_item_id"] not in ids:
            raise StepFailed(f"new work item missing from the list of {len(ids)}")
        return f"new work item is among {len(ids)} listed"

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
        target = urlsplit(upload["url"])
        if target.netloc != self.host:
            raise StepFailed(f"presigned POST names host {target.netloc}, expected {self.host}")
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
        # Host is part of the signature, so this also proves the ingress preserved it.
        fetched = self.retrying_get(f"{target.path}?{target.query}", session=False, headers={"Accept": "*/*"})
        return expect(fetched, 200).body

    def step_attachment_upload(self, data: dict) -> str:
        content = (f"wayline smoke {self.run_id}\n" + secrets.token_hex(512)).encode()
        self.state["attachment"] = content
        self.state["asset_id"] = self.upload_attachment(self.base(), self.state["work_item_id"], content)
        data.update(asset_id=self.state["asset_id"], size=len(content), sha256=sha256(content))
        return f"{len(content)} bytes stored"

    def step_attachment_download(self, data: dict) -> str:
        got = self.download_attachment(self.base(), self.state["work_item_id"], self.state["asset_id"])
        want = sha256(self.state["attachment"])
        data.update(expected_sha256=want, actual_sha256=sha256(got))
        if sha256(got) != want:
            raise StepFailed(f"checksum mismatch: {sha256(got)} != {want}")
        return f"sha256 {want[:16]}... matches"

    def step_realtime_page(self, data: dict) -> str:
        target = f"/api/workspaces/{self.state['slug']}/projects/{self.state['project_id']}/pages/"
        response = self.http.send_json("POST", target, {"name": "smoke", "access": 0})
        self.state["page_id"] = expect(response, 201).json()["id"]
        data["page_id"] = self.state["page_id"]
        return self.state["page_id"]

    def open_collaboration(self) -> WebSocket:
        query = urlencode({"documentType": "project_page", "projectId": self.state["project_id"],
                           "workspaceSlug": self.state["slug"]})
        cookie = f"session-id={self.http.cookies['session-id']}"
        self.state["cookie"] = cookie
        return WebSocket(self.connect_host, self.connect_port, self.host, f"/live/collaboration?{query}", cookie)

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

    def step_sentinel_create(self, data: dict) -> str:
        """A long-lived record that drills and restores re-read. It is never recreated silently:
        a missing sentinel means data was lost, so that must stay a failure."""
        if self.sentinel_path.exists() and not self.args.reset_sentinel:
            return f"reusing existing sentinel {self.sentinel_path.name}"
        slug = f"sentinel-{self.run_id}"
        self.create_workspace(f"Sentinel {self.run_id}", slug)
        project_id = self.create_project(slug, "Sentinel")
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
        return f"created {work_item_id}"

    def step_sentinel_reread(self, data: dict) -> str:
        if not self.sentinel_path.exists():
            raise StepBlocked(f"{self.sentinel_path} does not exist. Run the full smoke test first.")
        record = json.loads(self.sentinel_path.read_text())
        data.update(work_item_id=record["work_item_id"], expected_sha256=record["sha256"])
        base = f"/api/v1/workspaces/{record['slug']}/projects/{record['project_id']}"
        response = self.retrying_get(f"{base}/work-items/{record['work_item_id']}/", session=False,
                                     headers=self.api())
        if response.status in (401, 403):
            raise StepFailed(f"API token refused with {response.status}: the user or token row is gone")
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

    # -- plans --

    def run_full(self) -> None:
        self.run("reachable", self.step_reachable)
        self.run("instance-setup", self.step_instance_setup, ("reachable",))
        self.run("csrf-enforced", self.step_csrf_enforced, ("reachable",))
        self.run("sign-in", self.step_sign_in, ("instance-setup",))
        self.run("workspace", self.step_workspace, ("sign-in",))
        self.run("api-token", self.step_api_token, ("sign-in",))
        self.run("project", self.step_project, ("workspace", "api-token"))
        self.run("work-item", self.step_work_item, ("project",))
        self.run("work-item-list", self.step_list, ("work-item",))
        self.run("background-job", self.step_background_job, ("work-item",))
        self.run("attachment-upload", self.step_attachment_upload, ("work-item",))
        self.run("attachment-download", self.step_attachment_download, ("attachment-upload",))
        self.run("realtime-page", self.step_realtime_page, ("project",))
        self.run("realtime-auth", self.step_realtime_auth, ("realtime-page",))
        self.run("realtime-denied", self.step_realtime_denied, ("realtime-page",))
        self.run("sentinel-create", self.step_sentinel_create, ("api-token",))
        self.run("sentinel-reread", self.step_sentinel_reread, ("sentinel-create",))

    def run_verify(self) -> None:
        self.run("reachable", self.step_reachable)
        self.run("sentinel-reread", self.step_sentinel_reread, ("reachable",))
        if self.args.job_probe:
            self.run("job-probe", self.step_job_probe, ("sentinel-reread",))


def sha256(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# --- Offline self-test ---------------------------------------------------------------------------


def selftest() -> int:
    """Checks the hand-written protocol code with no cluster. It proves nothing about Plane."""
    # Frame bytes asserted by the research probe, which matched the Hocuspocus source.
    assert auth_frame("d", "t") == bytes([1, 0x64, 2, 0, 1, 0x74])
    assert read_varstring(varstring("x" * 300), 0)[0] == "x" * 300
    # RFC 6455 section 1.3 example.
    assert ws_accept("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    # RFC 6455 section 5.7 masked "Hello".
    assert ws_encode(0x1, b"Hello", bytes.fromhex("37fa213d")) == bytes.fromhex("818537fa213d7f9f4d5158")

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

    # A tiny server that plays Hocuspocus, so the client's framing runs over a real socket.
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
        connection.close()

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    ws = WebSocket("127.0.0.1", port, "plane.dev.localhost", "/live/collaboration", "session-id=x")
    assert collaboration_auth(ws, "doc", "tok") == ("Authenticated", "read-write")
    thread.join(5)
    server.close()
    assert not failures, failures
    print("selftest ok")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--env", choices=sorted(HOSTS), default="dev", help="environment under test (default: dev)")
    parser.add_argument("--mode", choices=["full", "verify"], default="full",
                        help="full: the whole flow. verify: only re-read the persistence sentinel (default: full)")
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
    parser.add_argument("--job-timeout", type=int, default=120, help="seconds to wait for a background job (default: 120)")
    parser.add_argument("--wait-seconds", type=int, default=180,
                        help="seconds to tolerate a restarting backend on reads (default: 180)")
    parser.add_argument("--selftest", action="store_true", help="check the protocol code offline, then exit")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.selftest:
        return selftest()
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
