#!/usr/bin/env python3
"""What Infisical's public route refuses, in every spelling, asked of the pinned Traefik with the manifest in this repository.

Run by tests/routes/infisical-public-route.sh, which starts that Traefik. Standard library only. Requests go out as raw bytes, because any
HTTP client tidies a path before it sends it, and that tidying is what this exists to try without. --selftest checks this file's own
verdicts with no Docker, no Traefik and no Infisical, so CI can run it.

Each row says who answered. A refused path passes when Traefik answers it, and fails when it reaches the backend. With the echo server
behind Traefik, that means the request got through in any shape, which is the proof that nothing refused arrives. With a real Infisical
behind it, that one of its handlers ran: any answer but its router's own "Route <method>:<url> not found", a handler's 404 included. That
run shows what Fastify makes of what does arrive, and it cannot see what Traefik forwarded, so it does not stand in for the echo run.
"""
from __future__ import annotations

import argparse
import base64
import contextlib
import http.client
import http.server
import io
import json
import pathlib
import re
import secrets
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

HOST = "infisical.bereket.dev"
ECHO_MARK = "echo-reached-backend"
FAKE_ID = "00000000-0000-4000-8000-000000000000"

# Everything named here was read from the running server and its web client at v0.167.6. The anonymous table beside this file lists the routes
# with no authentication hook. These are the ones a person's browser does need.
MUST_REACH = [
    ("GET", "/login"),
    ("GET", "/"),
    ("GET", "/login/select-organization"),
    ("GET", f"/mfa-session/{FAKE_ID}"),
    ("GET", "/personal-settings"),
    ("GET", "/admin/setup"),
    ("GET", "/admin/authentication"),
    ("GET", f"/organizations/{FAKE_ID}/projects"),
    ("GET", "/runtime-ui-env.js"),
    ("GET", "/assets/index.js"),
    ("GET", "/locales/en/translations.json"),
    ("GET", "/api/status"),
    ("GET", "/api/v1/admin/config"),
    ("PATCH", "/api/v1/admin/config"),
    ("GET", "/api/v1/user"),
    ("GET", "/api/v1/organization"),
    ("GET", f"/api/v1/organization/{FAKE_ID}"),
    ("GET", "/api/v1/organization/accessible-with-sub-orgs"),
    ("GET", "/api/v1/organizations/memberships/groups"),
    ("GET", f"/api/v1/organizations/{FAKE_ID}/plan"),
    ("GET", "/api/v1/projects"),
    ("GET", "/api/v2/users/me"),
    ("POST", "/api/v2/users/me/mfa/enroll"),
    ("POST", "/api/v2/users/me/mfa/activate"),
    ("POST", "/api/v1/user/me/totp/register"),
    ("GET", "/api/v1/user/me/mfa/recovery-codes"),
    ("GET", f"/api/v2/mfa-sessions/{FAKE_ID}/status"),
    ("GET", "/api/v4/secrets"),
    ("POST", "/api/v4/secrets/batch"),
    ("GET", "/api/v2/folders"),
    ("GET", f"/api/v1/auth/universal-auth/identities/{FAKE_ID}"),
    ("GET", f"/api/v1/auth/kubernetes-auth/identities/{FAKE_ID}"),
    ("GET", f"/api/v1/auth/token-auth/identities/{FAKE_ID}"),
    ("GET", f"/api/v1/auth/token-auth/identities/{FAKE_ID}/tokens"),
    ("POST", f"/api/v1/auth/token-auth/identities/{FAKE_ID}/tokens"),
    ("POST", f"/api/v1/auth/token-auth/tokens/{FAKE_ID}/revoke"),
    ("POST", f"/api/v1/auth/universal-auth/identities/{FAKE_ID}/client-secrets"),
    ("GET", "/api/v2/gateways"),
    ("POST", "/api/v2/service-token"),
    ("DELETE", f"/api/v2/service-token/{FAKE_ID}"),
    ("GET", "/api/v1/sso/config"),
    ("GET", "/api/v1/sso/oidc/config"),
    ("GET", "/api/v1/ldap/config"),
    ("GET", "/api/v2/gateways"),
    ("GET", "/api/v1/relays"),
    ("GET", "/api/v1/cert-manager/instance"),
    ("GET", "/api/v2/secret-scanning/instance"),
    ("GET", "/api/v1/announcement/recent"),
    ("GET", "/api/v1/notifications/user"),
]

# Each of the two limits, and the requests a browser makes against them. They reach the backend until the limit answers.
GUESS_LIMITED = [
    ("POST", "/api/v3/auth/login"),
    ("POST", "/api/v2/auth/mfa/send"),
    ("POST", "/api/v2/auth/mfa/verify"),
    ("POST", "/api/v2/auth/mfa/verify/recovery-code"),
    ("POST", f"/api/v2/mfa-sessions/{FAKE_ID}/verify"),
    ("POST", "/api/v2/password/user/password-reset"),
    ("POST", "/api/v1/password/password-setup"),
    ("POST", "/api/v1/password/email/password-setup"),
]
SESSION_LIMITED = [
    ("POST", "/api/v3/auth/select-organization"),
    ("POST", "/api/v1/auth/token"),
    ("POST", "/api/v1/auth/logout"),
    ("GET", "/api/v2/auth/mfa/check/totp"),
    ("GET", "/api/v2/auth/mfa/check/webauthn"),
]

# What the task of this route is to refuse, by name, beyond the table. Each is tried in every spelling below.
REFUSED_HEADLINE = [
    ("POST", "/api/v1/auth/universal-auth/login"),
    ("POST", "/api/v1/auth/kubernetes-auth/login"),
    ("POST", "/api/v1/auth/aws-auth/login"),
    ("POST", "/api/v1/auth/oidc-auth/login"),
    ("POST", "/api/v1/auth/jwt-auth/login"),
    ("POST", "/api/v1/auth/ldap-auth/login"),
    ("POST", "/api/v1/auth/token/renew"),
    ("POST", "/api/v1/auth/token/revoke"),
    ("POST", "/api/v1/auth/checkAuth"),
    ("POST", "/api/v3/auth/login1"),
    ("POST", "/api/v3/auth/login2"),
    ("POST", "/api/v1/admin/bootstrap"),
    ("POST", "/api/v1/admin/signup"),
    ("POST", "/api/v3/signup/email/signup"),
    ("POST", "/api/v3/signup/complete-account"),
    ("POST", "/api/v1/invite-org/verify"),
    ("POST", "/api/v1/account-recovery/send-email"),
    ("POST", "/api/v2/password/password-reset"),
    ("GET", "/api/docs"),
    ("GET", "/api/docs/json"),
    ("GET", "/api/docs/static/index.html"),
    ("GET", "/api/v1/scim/Users"),
    ("POST", "/api/v1/scim/Users"),
    ("GET", "/api/v1/scim/ServiceProviderConfig"),
    ("POST", "/api/v1/shared-secrets/public"),
    ("POST", "/api/v1/sso/token-exchange"),
    ("GET", "/api/v1/sso/redirect/google"),
    ("POST", f"/api/v1/sso/saml2/{FAKE_ID}"),
    ("POST", "/api/v1/ldap/login"),
    ("POST", "/api/v1/oauth/token"),
    ("POST", "/api/v1/kmip/servers/login"),
    ("POST", "/api/v3/gateways/login"),
    ("POST", "/api/v2/relays/login"),
    ("GET", "/api/v3/secrets/raw"),
    ("GET", "/api/v1/identities/details"),
    ("GET", "/api/v1/organization/agent-proxy-ca"),
    ("POST", "/api/v1/organization/agent-proxy-ca/sign"),
    ("POST", "/api/v2/gateways"),
    ("GET", "/api/v2/service-token"),
    ("HEAD", "/api/v2/service-token"),
    ("GET", "/api/v1/workspace"),
    ("GET", f"/.well-known/est/{FAKE_ID}/cacerts"),
    ("POST", f"/.well-known/est/{FAKE_ID}/simpleenroll"),
    ("POST", f"/scep/{FAKE_ID}/pkiclient.exe"),
    ("POST", "/secret-scanning/webhooks/gitlab"),
    ("GET", "/signup"),
    ("GET", "/signup/sso"),
    ("GET", "/signupinvite"),
    ("GET", "/admin/signup"),
    ("GET", "/requestnewinvite"),
    ("GET", "/account-recovery"),
    ("GET", "/account-recovery-reset"),
    ("GET", "/shared/new"),
    ("GET", f"/shared/secret/{FAKE_ID}"),
    ("GET", f"/secret-request/secret/{FAKE_ID}"),
    ("GET", "/cli-redirect"),
    ("GET", "/login/ldap"),
    ("GET", "/login/saml"),
    ("GET", "/login/oidc"),
]

# Paths that start like something allowed and try to walk to something refused, for what the rules read and what a router reads to differ.
WALKS = [
    (route, target)
    for route, targets in {
        "/api/v1/auth/universal-auth/login": [
            "/api/v1/organization/../auth/universal-auth/login",
            "/api/v1/organization/../../v1/auth/universal-auth/login",
            "/api/v1/organization/..%2fauth/universal-auth/login",
            "/api/v1/organization/..%2Fauth/universal-auth/login",
            "/api/v1/organization/%2e%2e/auth/universal-auth/login",
            "/api/v1/organization/%2E%2E%2Fauth/universal-auth/login",
            "/api/v1/organization/.%2e/auth/universal-auth/login",
            "/api/v1/organization/%2e./auth/universal-auth/login",
            "/api/v1/organization/..;/auth/universal-auth/login",
            "/api/v1/organization/..\\auth/universal-auth/login",
            "/api/v1/organization/%5c..%5cauth/universal-auth/login",
            "/api/v1/organization/%252e%252e/auth/universal-auth/login",
            "/api/v1/organization/..%252fauth/universal-auth/login",
            "/api/v1/organization;/../auth/universal-auth/login",
            "/api/v1/organization%2f..%2fauth/universal-auth/login",
            "/assets/../api/v1/auth/universal-auth/login",
            "/assets/%2e%2e/api/v1/auth/universal-auth/login",
            "/assets/..%2fapi/v1/auth/universal-auth/login",
            "/assets/..%2Fapi%2Fv1%2Fauth%2Funiversal-auth%2Flogin",
        ],
        "/api/v1/admin/bootstrap": [
            "/api/v1/projects/%2e%2e/admin/bootstrap",
            "/api/status/../v1/admin/bootstrap",
            "/api/status/..%2fv1%2fadmin%2fbootstrap",
            "///api/v1/admin/bootstrap",
            "/%2Fapi/v1/admin/bootstrap",
            "/api%2Fv1%2Fadmin%2Fbootstrap",
            "/api/v1%2fadmin/bootstrap",
        ],
        "/api/v1/scim/Users": ["/api/v1/user/../scim/Users"],
        "/api/docs": [
            "/login/../api/docs",
            "/login/..%2fapi%2fdocs",
            "/./api/docs",
            "/.//api/docs",
            "//api/docs",
            "/%2fapi/docs",
            "/%2e/api/docs",
            "/%252fapi/docs",
            "/api%2fdocs",
            "/api%252fdocs",
            "/%61pi/docs",
            "/%41PI/docs",
        ],
        "/signup": ["/login/../signup", "/login/%2e%2e/signup", "/login/..%2fsignup"],
        "/admin/signup": ["/assets/../admin/signup"],
    }.items()
    for target in targets
]


def spellings(path: str) -> dict[str, str]:
    """The same path as a client could write it, and as some router could read it back."""
    head, _, last = path.rpartition("/")
    first_letter = next((i for i, c in enumerate(path) if c.isalpha()), 1)
    last_letter = max(i for i, c in enumerate(path) if c.isalpha())
    encode_at = lambda i, table="%{:02x}": path[:i] + table.format(ord(path[i])) + path[i + 1 :]  # noqa: E731
    every = "".join(f"%{ord(c):02x}" if c.isalnum() else c for c in path)
    every_slash = "".join(f"%{ord(c):02X}" if c != "/" or i else c for i, c in enumerate(path))
    return {
        "as written": path,
        "trailing slash": path + "/",
        "two trailing slashes": path + "//",
        "double slash in front": "/" + path,
        "triple slash in front": "//" + path,
        "double slash at the last step": f"{head}//{last}",
        "every slash doubled": path.replace("/", "//"),
        "upper case": path.upper(),
        "lower case": path.lower(),
        "first letter upper": path[:first_letter] + path[first_letter].upper() + path[first_letter + 1 :],
        "last step upper": f"{head}/{last.upper()}",
        "first letter encoded": encode_at(first_letter),
        "first letter encoded upper hex": encode_at(first_letter, "%{:02X}"),
        "last letter encoded": encode_at(last_letter),
        "every letter encoded": every,
        "everything encoded but the first slash": every_slash,
        "last slash encoded": f"{head}%2f{last}",
        "last slash encoded upper hex": f"{head}%2F{last}",
        "last slash doubly encoded": f"{head}%252f{last}",
        "last slash as a backslash": f"{head}\\{last}",
        "last slash as an encoded backslash": f"{head}%5c{last}",
        "first letter doubly encoded": path[:first_letter] + f"%25{ord(path[first_letter]):02x}" + path[first_letter + 1 :],
        "dot segment in front": "/." + path,
        "dot segment at the last step": f"{head}/./{last}",
        "dot segment at the end": path + "/.",
        "dot dot back at the end": path + "/x/..",
        "dot dot back at the last step": f"{head}/x/../{last}",
        "encoded dot segment": f"{head}/%2e/{last}",
        "encoded dot dot": f"{head}/x/%2e%2e/{last}",
        "encoded dot dot, slash too": f"{head}/x/%2e%2e%2f{last}",
        "semicolon at the end": path + ";",
        "semicolon parameter": path + ";x=1",
        "semicolon parameter then slash": path + ";x=1/",
        "semicolon at the last step": f"{head};x/{last}",
        "encoded semicolon at the end": path + "%3b",
        "encoded question mark at the end": path + "%3f",
        "encoded hash at the end": path + "%23",
        "raw hash at the end": path + "#x",
        "null byte at the end": path + "%00",
        "null byte in front of the last step": f"{head}/%00{last}",
        "overlong encoded dot": f"{head}/x/%c0%ae%c0%ae/{last}",
        "invalid escape": path + "%zz",
        "encoded newline at the end": path + "%0a",
        "encoded tab at the end": path + "%09",
        "space at the end": path + "%20",
        "plus at the end": path + "+",
        "query": path + "?x=1",
        "query with a slash": path + "?x=/",
        "empty query": path + "?",
    }


class Echo(threading.Thread):
    """Answers anything with the request line it received, so a row can say what reached the backend."""

    def __init__(self, port: int):
        super().__init__(daemon=True)
        self.server = socket.create_server(("127.0.0.1", port))
        self.lines: list[str] = []

    def run(self) -> None:
        while True:
            connection, _ = self.server.accept()
            threading.Thread(target=self.answer, args=(connection,), daemon=True).start()

    def answer(self, connection: socket.socket) -> None:
        with connection:
            buffer = b""
            while True:
                try:
                    chunk = connection.recv(65536)
                except OSError:
                    return
                if not chunk:
                    return
                buffer += chunk
                while b"\r\n\r\n" in buffer:
                    head, _, rest = buffer.partition(b"\r\n\r\n")
                    match = re.search(rb"(?i)content-length:\s*(\d+)", head)
                    length = int(match.group(1)) if match else 0
                    if len(rest) < length:
                        break
                    buffer = rest[length:]
                    line = head.split(b"\r\n", 1)[0].decode("latin-1")
                    self.lines.append(line)
                    body = json.dumps({ECHO_MARK: line}).encode()
                    # A header too, because a HEAD's answer carries no body.
                    connection.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Echo-Reached: 1\r\nContent-Length: %d\r\n\r\n%s" % (len(body), body))


class Client:
    def __init__(self, port: int, connect_host: str = "127.0.0.1"):
        self.address = (connect_host, port)
        self.context = ssl.create_default_context()
        self.context.check_hostname = False
        self.context.verify_mode = ssl.CERT_NONE

    def ask(self, method: str, target: str, headers: dict[str, str] | None = None, body: bytes | None = None, version: str = "HTTP/1.1",
            extra: list[tuple[str, str]] | None = None) -> tuple[int, dict[str, str], bytes]:
        lines = [f"{method} {target} {version}", f"Host: {HOST}", "User-Agent: infisical-public-route-test", "Connection: close"]
        for name, value in list((headers or {}).items()) + (extra or []):
            lines.append(f"{name}: {value}")
        if method in ("POST", "PUT", "PATCH") and body is None:
            body = b"{}"
        if body is not None:
            lines += ["Content-Type: application/json", f"Content-Length: {len(body)}"]
        raw = ("\r\n".join(lines) + "\r\n\r\n").encode("latin-1") + (body or b"")
        data = b""
        # Thousands of short connections in a minute can run Docker's published port out of breath, and that says nothing about the route.
        for attempt in range(1, 6):
            try:
                with socket.create_connection(self.address, timeout=20) as plain, self.context.wrap_socket(plain, server_hostname=HOST) as tls:
                    tls.sendall(raw)
                    while True:
                        try:
                            chunk = tls.recv(65536)
                        except (ssl.SSLError, OSError):
                            break
                        if not chunk:
                            break
                        data += chunk
                break
            except OSError:
                if attempt == 5:
                    raise
                time.sleep(attempt)
        head, _, payload = data.partition(b"\r\n\r\n")
        parts = head.split(b"\r\n")
        try:
            status = int(parts[0].split()[1])
        except (IndexError, ValueError):
            return 0, {}, data[:200]
        answered = {}
        for line in parts[1:]:
            name, _, value = line.partition(b":")
            answered[name.decode("latin-1").strip().lower()] = value.decode("latin-1").strip()
        return status, answered, payload


class Report:
    def __init__(self) -> None:
        self.failed = 0
        self.passed = 0
        self.blocked = 0
        self.info = 0
        self.lines: list[str] = []

    def row(self, verdict: str, name: str, detail: str = "") -> None:
        # INFO says what was seen where this test has nothing to hold it to, and counts neither way. BLOCKED says a row could not be asked,
        # which is no pass and says nothing about the route, as in scripts/test.sh.
        if verdict == "FAIL":
            self.failed += 1
        elif verdict == "BLOCKED":
            self.blocked += 1
        elif verdict == "INFO":
            self.info += 1
        else:
            self.passed += 1
        self.lines.append(f"{verdict:5} {name} {detail}".rstrip())
        if verdict in ("FAIL", "BLOCKED"):
            print(self.lines[-1])

    def exit_code(self) -> int:
        """1 when something got through, else 2 when something could not be asked, else 0."""
        return 1 if self.failed else 2 if self.blocked else 0


def infisical_found_no_route(status: int, body: bytes, method: str) -> bool:
    """Fastify's own not-found handler, and nothing else. server/plugins/error-handler.ts at this version writes exactly this message and error,
    with the method and the URL as the server received them. Any other 404 came from a handler that ran, as an unknown CA certificate's does."""
    if status != 404:
        return False
    try:
        answer = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return False
    if not isinstance(answer, dict) or answer.get("error") != "Not Found" or answer.get("statusCode") != 404:
        return False
    found = re.fullmatch(r"Route ([A-Z]+):(/\S*) not found", str(answer.get("message", "")))
    return bool(found) and found.group(1) == method


def who_answered(status: int, headers: dict[str, str], body: bytes, real: bool, method: str) -> str:
    """traefik, limit, backend, or with a real Infisical behind it, infisical-no-route, which is its router finding nothing."""
    text = body.decode("latin-1", "replace")
    if ECHO_MARK in text or headers.get("x-echo-reached") == "1":
        return "backend"
    if status == 429:
        return "limit"
    if not real:
        return "traefik"
    # helmet puts this on everything Infisical sends, and Traefik's own refusals are plain text without it.
    if "x-download-options" not in headers:
        return "traefik"
    if infisical_found_no_route(status, body, method):
        return "infisical-no-route"
    return "backend"


def unsigned_token(payload: dict[str, str]) -> str:
    """A token in the shape Infisical's own: base64url JSON, the keys in the order its code writes them, and a signature that is not one."""
    part = lambda value: base64.urlsafe_b64encode(json.dumps(value, separators=(",", ":")).encode()).rstrip(b"=").decode()  # noqa: E731
    return ".".join([part({"alg": "HS256", "typ": "JWT"}), part(payload), part("not-signed")])


def fastify_reads(forwarded: str) -> str:
    """The path as find-my-way 9.9.0 routes it, with Infisical's ignoreTrailingSlash: everything decoded but the reserved characters, which stay encoded and so
    never become a separator. node_modules/find-my-way/lib/url-sanitizer.js at this image."""
    path = forwarded.split("?", 1)[0].split("#", 1)[0]

    def decode(match: re.Match[str]) -> str:
        value = int(match.group(1), 16)
        return match.group(0) if chr(value) in "#$&+,/:;=?@%" else chr(value)

    path = re.sub(r"%([0-9A-Fa-f]{2})", decode, path)
    return path[:-1] if len(path) > 1 and path.endswith("/") else path


def refused(report: Report, client: Client, method: str, target: str, label: str, real: bool, route: str) -> None:
    status, headers, body = client.ask(method, target)
    who = who_answered(status, headers, body, real, method)
    if real and who == "backend" and method == "HEAD" and status == 404 and not body.strip():
        # A HEAD's answer has no body to say whether a route ran, and Fastify routes HEAD as it routes GET, so the same path as a GET says.
        status, headers, body = client.ask("GET", target)
        who = who_answered(status, headers, body, real, "GET")
    if who != "backend":
        report.row("PASS", f"{method} {target} is refused [{label}]", f"{status} from {who}")
    elif real and status in (401, 403) and fastify_reads(target) != route:
        # A route that wants a session answered, and Fastify's router cannot have read this as the refused path: an encoded slash stays inside one
        # segment, so this is the route above it, with that segment for its parameter.
        report.row("PASS", f"{method} {target} is refused [{label}]", f"{status}: the route Fastify reads as {fastify_reads(target)}, which is not {route}")
    elif real:
        report.row("FAIL", f"{method} {target} is refused [{label}]", f"status {status}, a route of Infisical's answered")
    else:
        line = json.loads(body.decode("latin-1")).get(ECHO_MARK, "") if body.strip() else f"{method} {target} HTTP/1.1"
        forwarded = line.split(" ")[1]
        # What arrives in another shape is no slip if Fastify's router cannot read it as the path this refuses. A real Infisical behind Traefik shows the same from its own side.
        if fastify_reads(forwarded) == route:
            report.row("FAIL", f"{method} {target} is refused [{label}]", f"status {status}, reached the backend as {forwarded}, which Fastify routes as {route}")
        else:
            report.row("PASS", f"{method} {target} is refused [{label}]", f"{status}: forwarded as {forwarded}, which is not {route} to Fastify's router")


def reset_as_malformed(returncode: int, stderr: str) -> bool:
    """Go's HTTP/2 server resets a stream whose :path it cannot read, as one with %zz or no leading slash, before Traefik sees the request,
    and curl says so. curl 8.7.1 against the pinned Traefik: exit 92, "HTTP/2 stream 1 was not closed cleanly: PROTOCOL_ERROR (err 1)".
    That is a refusal, and the same one at every try."""
    return returncode == 92 and "PROTOCOL_ERROR" in stderr


def h2_ask(port: int, target: str, run_command=subprocess.run, pause=time.sleep) -> tuple[int, str, str]:
    """A POST over HTTP/2, as curl's exit status, what it printed, and what it said went wrong. The target goes as the request target itself,
    because curl's URL parser refuses one with no leading slash, which left five rows reading PASS with nothing sent, and drops what follows
    a #. A try that got no answer is made again, as Client.ask makes one, because a refusal is read only from an answer."""
    command = [
        "curl", "-k", "-sS", "--http2", "--max-time", "10", "-o", "-", "-w", "\n%{http_code} %{http_version}", "-D", "-",
        "--resolve", f"{HOST}:{port}:127.0.0.1", "-X", "POST", "-H", "Content-Type: application/json", "--data-binary", "{}",
        "--request-target", target, f"https://{HOST}:{port}/",
    ]
    attempt = 1
    while True:
        answer = run_command(command, capture_output=True, text=True, errors="replace", check=False)
        if answer.returncode == 0 or reset_as_malformed(answer.returncode, answer.stderr) or attempt == 5:
            return answer.returncode, answer.stdout, answer.stderr
        pause(attempt)
        attempt += 1


def h2_verdict(returncode: int, stdout: str, stderr: str, path: str, real: bool, arrived: list[str] | None) -> tuple[str, str]:
    """PASS, FAIL or BLOCKED for one HTTP/2 row, and what it saw. arrived holds the request lines the echo server received while curl asked,
    and is None with a real backend, which cannot show them. Only an answer over HTTP/2 or a stream reset as malformed is a refusal: no
    answer is none, and an answer over HTTP/1.1 says nothing of HTTP/2."""
    output, _, tail = stdout.rpartition("\n")
    code, _, version = tail.partition(" ")
    # -D - and -o - print the headers, a blank line and the body, and -w adds its line after them. Text mode has made each CRLF a LF.
    head, _, payload = output.partition("\n\n")
    lines = list(arrived or [])
    if "x-echo-reached: 1" in head.lower():
        # The echo's own answer too, read as the JSON it is, so a backslash in what it received stays one.
        try:
            lines.append(str(json.loads(payload).get(ECHO_MARK, "")))
        except (ValueError, AttributeError):
            pass
    forwarded = [line.split(" ", 1)[1].rsplit(" ", 1)[0] for line in lines if line.count(" ") >= 2]
    slipped = next((seen for seen in forwarded if fastify_reads(seen) == path), None)
    if slipped is not None:
        return "FAIL", f"reached the backend as {slipped}, which Fastify routes as {path}"
    elsewhere = f", forwarded as {forwarded[0]}, which is not {path} to Fastify's router" if forwarded else ""
    if reset_as_malformed(returncode, stderr):
        return "PASS", f"Traefik's HTTP/2 server reset the stream as malformed{elsewhere}"
    if returncode != 0 or not code.isdigit() or code == "000":
        said = stderr.strip().splitlines()[-1] if stderr.strip() else f"curl exit {returncode}"
        return "BLOCKED", f"no answer over HTTP/2: {said}"
    if version != "2":
        return "BLOCKED", f"{code} over HTTP/{version}, so this row asked nothing of HTTP/2"
    if real and "x-download-options" in head.lower():
        if not infisical_found_no_route(int(code), payload.encode(), "POST"):
            return "FAIL", f"{code} over HTTP/2, and a route of Infisical's answered"
        return "PASS", f"{code} over HTTP/2 from infisical-no-route"
    return "PASS", f"{code} over HTTP/2 from {'backend' if forwarded else 'traefik'}{elsewhere}"


def run(arguments: argparse.Namespace) -> int:
    client = Client(arguments.port)
    real = arguments.backend == "real"
    echo = None
    if not real:
        try:
            echo = Echo(arguments.echo_port)
        except OSError as error:
            # Taken since the preflight, by a run that started at the same moment. Nothing was asked, so this is no exit 1.
            print(f"cannot run: {echo_port_taken(arguments.echo_port, error)}", file=sys.stderr)
            return 2
        echo.start()
    report = Report()

    # The limits come first, while the buckets are full, and the rows below run against them with the buckets empty. With either backend:
    # a try reaches it, as the echo or as an answer of Infisical's own, until the limit answers 429.
    print("== the limits")
    answers, reached = [], []
    for attempt in range(1, 15):
        status, headers, body = client.ask("POST", "/api/v3/auth/login", headers={"X-Forwarded-For": f"203.0.113.{attempt}", "X-Real-IP": f"203.0.113.{attempt}", "CF-Connecting-IP": f"203.0.113.{attempt}"})
        answers.append(status)
        reached.append(who_answered(status, headers, body, real, "POST") == "backend")
    report.row("PASS" if all(reached[:10]) and 429 in answers and reached.count(True) <= 11 else "FAIL", "guessing at the login meets its limit, whatever forwarded header each try sends", f"answers {answers}")
    answers, reached = [], []
    for attempt in range(1, 45):
        status, headers, body = client.ask("POST", "/api/v1/auth/token", headers={"X-Forwarded-For": f"203.0.113.{attempt}"})
        answers.append(status)
        reached.append(who_answered(status, headers, body, real, "POST") == "backend")
    report.row("PASS" if all(reached[:30]) and 429 in answers else "FAIL", "the session routes meet their wider limit", f"{reached.count(True)} reached it, then {answers.count(429)} answered 429")
    # A person's page load is not one of these.
    status, _, _ = client.ask("GET", "/login")
    report.row("PASS" if status == 200 else "FAIL", "with both limits spent, the login page still answers", str(status))
    status, _, _ = client.ask("GET", "/api/v1/admin/config")
    report.row("PASS" if status == 200 else "FAIL", "with both limits spent, the config a sign-in page reads still answers", str(status))

    # What arrived is read from the echo, so this part runs with it alone.
    if not real:
        print("== no spelling of a limited path goes round its limit")
        for method, path in GUESS_LIMITED + SESSION_LIMITED:
            for label, target in spellings(path).items():
                # Those two keep working by design, and only the bare path and a query can reach the route.
                if label in ("query", "query with a slash", "empty query", "as written"):
                    continue
                status, headers, body = client.ask(method, target)
                who = who_answered(status, headers, body, real, method)
                seen = json.loads(body.decode("latin-1")).get(ECHO_MARK, "").split(" ")[1] if who == "backend" else ""
                verdict = "FAIL" if who == "backend" and fastify_reads(seen) == path else "PASS"
                report.row(verdict, f"{method} {target} does not go round the limit [{label}]", f"{status} from {who} {seen}")
    status, _, _ = client.ask("POST", "/api/v3/auth/login?x=1")
    report.row("PASS" if status == 429 else "FAIL", "a query on the login is still under its limit", str(status))
    for method, path in GUESS_LIMITED + SESSION_LIMITED:
        status, headers, body = client.ask("DELETE" if method == "POST" else "POST", path)
        who = who_answered(status, headers, body, real, "DELETE" if method == "POST" else "POST")
        report.row("PASS" if status == 404 and who == "traefik" else "FAIL", f"another method on {path} is refused", f"{status} from {who}")

    print("== what a browser needs still reaches the backend")
    for method, path in MUST_REACH:
        status, headers, body = client.ask(method, path)
        who = who_answered(status, headers, body, real, method)
        if real:
            # Asked with no session, so a page answers 200 and an API route 401 or 400: only Traefik's refusal or a missing route is wrong here.
            good = who == "backend"
        else:
            good = who == "backend" and json.loads(body.decode("latin-1")).get(ECHO_MARK, "").split(" ")[1] == path
        report.row("PASS" if good else "FAIL", f"{method} {path} reaches the backend", f"{status} from {who}")

    print("== refused, in every spelling")
    for method, path in REFUSED_HEADLINE:
        for label, target in spellings(path).items():
            refused(report, client, method, target, label, real, route=path)
    for route, target in WALKS:
        for method in ("GET", "POST"):
            refused(report, client, method, target, "a walk from something allowed", real, route=route)

    print("== every route the server registers with no authentication hook")
    table = pathlib.Path(__file__).with_name("infisical-anonymous-routes.tsv")
    stays = 0
    for line in table.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        decision, method, route = line.split("\t")
        target = re.sub(r":[^/]+", FAKE_ID, route).replace("*", "x")
        if decision == "refused":
            refused(report, client, method, target, "anonymous route", real, route=target)
        else:
            status, headers, body = client.ask(method, target)
            who = who_answered(status, headers, body, real, method)
            stays += 1
            good = who != "traefik"
            report.row("PASS" if good else "FAIL", f"{method} {target} stays, as docs/infisical.md says", f"{status} from {who}")

    print("== every route that takes only a machine's credential")
    for line in pathlib.Path(__file__).with_name("infisical-machine-routes.tsv").read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        decision, method, route = line.split("\t")
        target = re.sub(r":[^/]+", FAKE_ID, route)
        assert decision == "refused", line
        refused(report, client, method, target, "machine route", real, route=target)

    print("== a machine's credential is refused wherever a browser's session is let through")
    # Signed or not, the same words reach Traefik: it reads the header, and refuses before anything checks a signature. Made here, in the
    # shape Infisical signs, so no token-shaped string sits in the repository for a secret scanner to flag.
    identity = unsigned_token({"identityId": FAKE_ID, "authTokenType": "identityAccessToken"})
    person = unsigned_token({"authMethod": "email", "authTokenType": "accessToken", "userId": FAKE_ID})
    machine_headers = [
        ("a machine identity's token", {"Authorization": "Bearer " + identity}),
        ("the same, with the scheme in lower case", {"Authorization": "bearer " + identity}),
        ("the same, after any 7 characters", {"Authorization": "Token: " + identity}),
        ("the same, after two spaces", {"Authorization": "Bearer  " + identity}),
        ("a service token", {"Authorization": "Bearer st.00000000.secret"}),
        ("a service token after any 7 characters", {"Authorization": "1234567st.00000000.secret"}),
        ("a byte outside ASCII before the token", {"Authorization": "\xe9\xe9\xe9\xe9\xe9\xe9\xe9st.00000000.secret"}),
        ("two-byte characters before the token", {"Authorization": "\xc3\xa9\xc3\xa9\xc3\xa9Xst.00000000.secret"}),
        ("a tab before the token", {"Authorization": "Bearer\t" + identity}),
        ("an API key", {"X-Api-Key": "anything"}),
        ("an empty API key", {"X-Api-Key": ""}),
        ("an API key beside a person's session", {"Authorization": "Bearer " + person, "X-Api-Key": "anything"}),
    ]
    browser_calls = [("GET", "/api/v1/organization"), ("GET", "/api/v4/secrets?projectId=x&environment=prod"), ("POST", "/api/v4/secrets/batch"),
                     ("GET", "/api/v1/identities/details"), ("GET", "/api/v2/folders"), ("PATCH", "/api/v1/admin/config")]
    for label, headers in machine_headers:
        for method, path in browser_calls:
            status, answered, body = client.ask(method, path, headers=headers)
            who = who_answered(status, answered, body, real, method)
            report.row("PASS" if who != "backend" else "FAIL", f"{method} {path} with {label} is refused", f"{status} from {who}")
    # Two values of the header. Traefik's HeaderRegexp reads every value, so a machine's token in either place is refused, and Node, which keeps
    # only the first, never sees one.
    status, answered, body = client.ask("GET", "/api/v1/organization", headers={"Authorization": "Bearer " + identity}, extra=[("Authorization", "Bearer " + person)])
    who = who_answered(status, answered, body, real, "GET")
    report.row("PASS" if who != "backend" else "FAIL", "a machine identity's token first and a person's second is refused", f"{status} from {who}")
    status, answered, body = client.ask("GET", "/api/v1/organization", headers={"Authorization": "Bearer " + person}, extra=[("Authorization", "Bearer " + identity)])
    who = who_answered(status, answered, body, real, "GET")
    report.row("PASS" if who != "backend" else "FAIL", "a person's session first and a machine identity's token second is refused too, because Traefik reads every value", f"{status} from {who}")
    for method, path in [("GET", "/api/v1/organization"), ("GET", "/api/v4/secrets?projectId=x&environment=prod"), ("GET", "/api/v1/user")]:
        status, answered, body = client.ask(method, path, headers={"Authorization": "Bearer " + person})
        who = who_answered(status, answered, body, real, method)
        report.row("PASS" if who == "backend" else "FAIL", f"{method} {path} with a person's session reaches the backend", f"{status} from {who}")

    print("== other ways to ask")
    tricks = [
        ("absolute-form request line", "POST", f"https://{HOST}/api/v1/auth/universal-auth/login", {}),
        ("absolute-form, another host in the line", "POST", "http://other.invalid/api/v1/auth/universal-auth/login", {}),
        ("X-Original-URL", "POST", "/login", {"X-Original-URL": "/api/v1/auth/universal-auth/login"}),
        ("X-Rewrite-URL", "POST", "/login", {"X-Rewrite-URL": "/api/v1/auth/universal-auth/login"}),
        ("X-HTTP-Method-Override on a refused method", "GET", f"/api/v1/auth/token-auth/identities/{FAKE_ID}/tokens", {"X-HTTP-Method-Override": "POST"}),
    ]
    for label, method, target, headers in tricks:
        status, answered, body = client.ask(method, target, headers=headers)
        who = who_answered(status, answered, body, real, method)
        seen = ""
        if who == "backend" and not real:
            seen = json.loads(body.decode("latin-1")).get(ECHO_MARK, "")
        if label.startswith("absolute"):
            bad = "universal-auth" in seen or (real and who == "backend")
            report.row("FAIL" if bad else "PASS", f"{label}", f"{status} from {who} {seen}")
        elif not real:
            # Traefik passes these headers on and acts on none of them, so the backend gets the request line as it was sent: the method and
            # path the route read, and not the ones a header names.
            sent = f"{method} {target} HTTP/1.1"
            report.row("PASS" if seen == sent else "FAIL", f"{label} changes nothing Traefik forwards", f"{status} from {who}: {seen or 'nothing arrived'}")
        else:
            # Infisical's own answer, with no session to show a difference. This version's server reads none of these headers, which is read
            # from its code, and so this row holds nothing to a verdict.
            report.row("INFO", f"{label} with Infisical behind the route", f"{status} from {who}")
    status, answered, body = client.ask("POST", "/api/v1/auth/universal-auth/login", version="HTTP/1.0")
    who = who_answered(status, answered, body, real, "POST")
    report.row("FAIL" if who == "backend" else "PASS", "HTTP/1.0 on a refused path", f"{status} from {who}")

    print("== the same spellings over HTTP/2, where the path travels as a header of its own")
    sample = ["/api/v1/auth/universal-auth/login", "/api/docs", "/signup", "/api/v1/admin/bootstrap"]
    asks = [(path, label, target) for path in sample for label, target in spellings(path).items()]
    for index, (path, label, target) in enumerate(asks):
        before = len(echo.lines) if echo is not None else 0
        returncode, stdout, stderr = h2_ask(arguments.port, target)
        verdict, detail = h2_verdict(returncode, stdout, stderr, path, real, echo.lines[before:] if echo is not None else None)
        report.row(verdict, f"h2 POST {target} is refused [{label}]", detail)
        if verdict == "BLOCKED" and index + 1 < len(asks):
            # A Traefik that gave no answer in five tries, or none over HTTP/2, gives the rest none either, and each would wait as long.
            report.row("BLOCKED", f"the {len(asks) - index - 1} HTTP/2 rows after it", "were not asked")
            break

    if echo is not None:
        print(f"the echo server received {len(echo.lines)} requests in all")
    if real and arguments.direct:
        print("== real tokens from this version, made at the backend itself")
        direct_rows(report, client, arguments.direct, arguments.throwaway)

    pathlib.Path(arguments.log).write_text("\n".join(report.lines) + "\n")
    print(f"SUMMARY passed={report.passed} failed={report.failed} blocked={report.blocked} info={report.info}, each row in {arguments.log}")
    return report.exit_code()


class NoAnswer(Exception):
    """The backend itself gave no answer this test can read: nothing listening, a reset, or a success that is not a JSON object."""


def direct_call(base: str, method: str, path: str, body: dict | None = None, token: str = "") -> tuple[int, dict]:
    """A call to the backend itself, past Traefik, as the bootstrap scripts make theirs through a port-forward. A refusal that is not a JSON
    object reads as an empty one. No answer at all raises NoAnswer, so a wrong address or a copy that stops answering is a row that could
    not be asked, and the run still writes its log."""
    headers = {"Content-Type": "application/json", "User-Agent": "infisical-public-route-test"}
    if token:
        headers["Authorization"] = "Bearer " + token
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(base.rstrip("/") + path, data=data, headers=headers, method=method)
    try:
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                status, raw = response.status, response.read()
        except urllib.error.HTTPError as error:
            status, raw = error.code, error.read()
    except (OSError, http.client.HTTPException) as error:
        # URLError is an OSError, as a refused connection, a reset and a timeout are. HTTPException is an answer that is not HTTP.
        raise NoAnswer(f"{method} {path}: {getattr(error, 'reason', None) or error}") from None
    try:
        answer = json.loads(raw or b"{}")
    except ValueError:
        answer = None
    if isinstance(answer, dict):
        return status, answer
    if 200 <= status < 300:
        raise NoAnswer(f"{method} {path} answered {status} with no JSON object")
    return status, {}


def dig(value: object, *keys: str) -> object:
    """value[key][key]..., or None where a level is missing or is not an object, because an answer is whatever the server sent."""
    for key in keys:
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value


def payload_text(token: str) -> str:
    """A token's payload as the JSON text it was signed as, keys in the order the server wrote them."""
    part = token.split(".")[1]
    try:
        return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)).decode("utf-8", "replace")
    except ValueError:
        return ""


def docker_inspect(container: str) -> dict | None:
    """What Docker says of a container on this machine, or None when it knows none by that name."""
    try:
        answer = subprocess.run(["docker", "inspect", "--type", "container", container], capture_output=True, text=True, check=False, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    try:
        found = json.loads(answer.stdout) if answer.returncode == 0 else []
    except ValueError:
        found = []
    return found[0] if isinstance(found, list) and found and isinstance(found[0], dict) else None


def throwaway_refusal(direct: str, container: str, inspect=docker_inspect) -> str:
    """Why direct mode may not claim what answers at direct, or "" when it may. It claims a copy with an admin it never keeps, so a real
    Infisical nobody has claimed yet, as production's is behind scripts/hosted/bootstrap.sh's port-forward until step 6 claims it, would be
    lost to it for good. So it asks only a running container named as a copy to throw away, at the port that container publishes on
    127.0.0.1. Docker holds that address while the container runs, so no port-forward can listen there. A binding on every address would
    not do, because a port-forward on 127.0.0.1 answers before it."""
    if not container:
        return ("direct mode claims the copy it asks, so it asks only a container named as one to throw away: name the container that "
                f"answers at {direct} in INFISICAL_ROUTE_TEST_THROWAWAY")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", container):
        return f"{container!r} is not a container's name"
    found = re.fullmatch(r"http://127\.0\.0\.1:([0-9]{1,5})/?", direct)
    if not found or not 0 < int(found.group(1)) < 65536:
        return f"direct mode asks only http://127.0.0.1:<port>, a port a container publishes on this machine's loopback, and was given {direct}"
    port = str(int(found.group(1)))
    details = inspect(container)
    if details is None:
        return f"Docker knows no container named {container}"
    if dig(details, "State", "Running") is not True:
        return f"container {container} is not running"
    published = dig(details, "NetworkSettings", "Ports")
    bindings = [binding for each in published.values() if isinstance(each, list) for binding in each] if isinstance(published, dict) else []
    if not any(isinstance(binding, dict) and binding.get("HostIp") == "127.0.0.1" and binding.get("HostPort") == port for binding in bindings):
        return f"container {container} does not publish 127.0.0.1:{port}, so what answers at {direct} may be something else"
    return ""


def direct_rows(report: Report, client: Client, direct: str, throwaway: str, inspect=docker_inspect) -> None:
    """real_tokens, with a backend that stops answering read as a row that could not be asked."""
    try:
        real_tokens(report, client, direct, throwaway, inspect)
    except NoAnswer as error:
        report.row("BLOCKED", "real tokens", f"the backend at {direct} gave no answer: {error}")


def real_tokens(report: Report, client: Client, direct: str, throwaway: str, inspect=docker_inspect) -> None:
    """The header refusal reads a machine identity's token by how this version's payload begins, and a person's by how theirs does. Both are
    made here by the server itself, on a copy nobody has claimed: the bootstrap call hands out the instance admin identity's token, and the
    admin it makes signs in. So a version that writes its tokens another way fails here, before the route is moved to it. A copy claimed
    already hands out none, which is a row that could not be asked, and no pass."""
    # Asked again at the claim itself, so whatever calls this cannot claim a target nobody named as a copy to throw away, nor a container
    # that has stopped since the preflight, whose port anything may hold now.
    refusal = throwaway_refusal(direct, throwaway, inspect)
    if refusal:
        report.row("BLOCKED", "real tokens", f"nothing asked or claimed: {refusal}")
        return
    status, config = direct_call(direct, "GET", "/api/v1/admin/config")
    if status != 200 or dig(config, "config", "initialized") is not False:
        said = "is claimed already" if status == 200 else f"answers {status} for its config"
        report.row("BLOCKED", "real tokens", f"the backend at {direct} {said}, so it hands out no token: start a new copy")
        return
    # A throwaway admin for a throwaway copy, made at run time and never printed or kept.
    email = f"route-test-{secrets.token_hex(4)}@example.invalid"
    password = secrets.token_hex(24)
    status, answer = direct_call(direct, "POST", "/api/v1/admin/bootstrap", {"email": email, "password": password, "organization": "route-test"})
    identity = str(dig(answer, "identity", "credentials", "token") or "")
    organization = str(dig(answer, "organization", "id") or "")
    if status != 200 or identity.count(".") != 2 or not organization:
        report.row("FAIL", "the bootstrap call on the backend hands out the instance admin identity's token and its organization", f"status {status}")
        return
    shape = payload_text(identity)
    report.row("PASS" if shape.startswith('{"identityId":') else "FAIL", 'a machine identity\'s real token begins {"identityId":, which the route reads it by', shape[:14])
    for method, path in [("GET", "/api/v1/organization"), ("GET", "/api/v4/secrets?projectId=x&environment=prod"), ("GET", "/api/v2/folders")]:
        status, answered, body = client.ask(method, path, headers={"Authorization": "Bearer " + identity})
        who = who_answered(status, answered, body, True, method)
        report.row("PASS" if who != "backend" else "FAIL", f"{method} {path} with a real machine identity's token is refused", f"{status} from {who}")
    # This version takes a person's session alone at GET /api/v1/organization, verifyAuth(["jwt"]) in its organization router, and answers
    # this token 403 there. The call an identity makes of itself is GET /api/v1/identities/details, which the route refuses by its path.
    status, answer = direct_call(direct, "GET", "/api/v1/identities/details", token=identity)
    belongs = dig(answer, "identityDetails", "organization", "id") == organization
    report.row("PASS" if status == 200 and belongs else "FAIL", "the same token works at the backend itself, as an identity of the organization the bootstrap made, so the refusal above is the route's",
               f"{status}, {'that organization' if belongs else 'not that organization'}")

    status, answer = direct_call(direct, "POST", "/api/v3/auth/login", {"email": email, "password": password})
    first = str(dig(answer, "accessToken") or "") if status == 200 else ""
    session = ""
    if first.count(".") == 2:
        status, answer = direct_call(direct, "POST", "/api/v3/auth/select-organization", {"organizationId": organization}, token=first)
        session = str(dig(answer, "token") or "") if status == 200 else ""
    if session.count(".") != 2:
        report.row("FAIL", "the admin the bootstrap call made signs in at the backend", f"status {status}")
        return
    shape = payload_text(session)
    report.row("PASS" if shape.startswith('{"authMethod":') else "FAIL", 'a person\'s real session begins {"authMethod":, which the route lets through', shape[:14])
    for method, path in [("GET", "/api/v1/organization"), ("GET", "/api/v1/user")]:
        status, answered, body = client.ask(method, path, headers={"Authorization": "Bearer " + session})
        who = who_answered(status, answered, body, True, method)
        report.row("PASS" if who == "backend" and status == 200 else "FAIL", f"{method} {path} with that real session reaches Infisical and is answered", f"{status} from {who}")


def echo_port_taken(port: int, error: OSError) -> str:
    return (f"the echo server cannot listen on 127.0.0.1:{port}: {error.strerror or error}. Another run may hold it: give this one its own "
            "port with INFISICAL_ROUTE_TEST_ECHO_PORT")


def preflight(arguments: argparse.Namespace, inspect=docker_inspect) -> str:
    """Why a run cannot start, or "" when it can. The shell wrapper asks this before it starts Traefik, so a refused run starts nothing."""
    if arguments.backend == "echo":
        if arguments.direct:
            return "INFISICAL_ROUTE_TEST_DIRECT asks a real Infisical past Traefik, and this run's backend is the echo server: set INFISICAL_BACKEND to it too"
        # Another run's echo server here would answer this run's Traefik, and this run's own would then fail to listen with no row asked.
        try:
            socket.create_server(("127.0.0.1", arguments.echo_port)).close()
        except OSError as error:
            return echo_port_taken(arguments.echo_port, error)
    if arguments.throwaway and not arguments.direct:
        return "INFISICAL_ROUTE_TEST_THROWAWAY names a copy for direct mode, and no INFISICAL_ROUTE_TEST_DIRECT says where to ask it"
    if arguments.direct:
        refusal = throwaway_refusal(arguments.direct, arguments.throwaway, inspect)
        if refusal:
            return refusal
        try:
            status, config = direct_call(arguments.direct, "GET", "/api/v1/admin/config")
        except NoAnswer as error:
            return f"the copy at {arguments.direct} gives no answer: {error}"
        if status != 200:
            return f"the copy at {arguments.direct} answers {status} for the config every sign-in page reads, so it is no Infisical this test can ask"
        if dig(config, "config", "initialized") is not False:
            return f"the copy at {arguments.direct} is claimed already, by an earlier run of this test or by someone, so it hands out no token: start a new one"
    return ""


class Copy:
    """For --selftest: a throwaway copy of Infisical v0.167.6, answering the calls real_tokens makes as that version's code does. Read from its
    server: GET /api/v1/organization and GET /api/v1/user take a person's session alone, verifyAuth(["jwt"]), and GET
    /api/v1/identities/details an identity's token alone, verifyAuth(["identityAccessToken"]). Any other kind gets ForbiddenRequestError,
    a 403, and an identity's token is signed with identityId first."""

    ORGANIZATION = {"id": "11111111-1111-4111-8111-111111111111", "name": "route-test", "slug": "route-test"}
    USER = "33333333-3333-4333-8333-333333333333"
    TAKES = {("POST", "/api/v3/auth/select-organization"): "accessToken", ("GET", "/api/v1/organization"): "accessToken",
             ("GET", "/api/v1/user"): "accessToken", ("GET", "/api/v1/identities/details"): "identityAccessToken"}

    def __init__(self, claimed: bool = False, identity_first: str = "identityId", garbled: bool = False) -> None:
        self.claimed = claimed
        self.identity_first = identity_first
        self.garbled = garbled
        self.account: dict = {}
        self.calls: list[str] = []
        self.address = ""

    def answer(self, method: str, target: str, authorization: str = "", body: bytes = b"") -> tuple[int, bytes, str]:
        path = target.split("?", 1)[0]
        token = authorization.partition(" ")[2]
        try:
            kind = str(json.loads(payload_text(token)).get("authTokenType", "")) if token.count(".") == 2 else ""
        except (ValueError, AttributeError):
            kind = ""
        self.calls.append(f"{method} {path} {kind}".rstrip())

        def reply(status: int, value: dict) -> tuple[int, bytes, str]:
            return status, json.dumps(value).encode(), "application/json; charset=utf-8"

        if self.garbled:
            return 200, b"<!doctype html><title>Infisical</title>", "text/html; charset=utf-8"
        if (method, path) == ("GET", "/api/v1/admin/config"):
            return reply(200, {"config": {"initialized": self.claimed, "allowSignUp": not self.claimed}})
        if (method, path) == ("POST", "/api/v1/admin/bootstrap"):
            if self.claimed:
                return reply(400, {"statusCode": 400, "message": "Instance has already been set up", "error": "BadRequest"})
            self.claimed, self.account = True, json.loads(body or b"{}")
            identity = {"identityId": "22222222-2222-4222-8222-222222222222", "identityName": "Instance Admin Identity", "authMethod": "token-auth",
                        "authTokenType": "identityAccessToken"}
            token = unsigned_token({self.identity_first: identity[self.identity_first], **identity})
            return reply(200, {"message": "Successfully bootstrapped instance", "organization": self.ORGANIZATION,
                               "identity": {"id": identity["identityId"], "name": identity["identityName"], "credentials": {"token": token}}})
        if (method, path) == ("POST", "/api/v3/auth/login"):
            given = json.loads(body or b"{}")
            if self.account and (given.get("email"), given.get("password")) == (self.account.get("email"), self.account.get("password")):
                return reply(200, {"accessToken": unsigned_token({"authMethod": "email", "authTokenType": "accessToken", "userId": self.USER})})
            return reply(400, {"statusCode": 400, "message": "Invalid credentials", "error": "BadRequest"})
        takes = self.TAKES.get((method, path))
        if takes and not kind:
            return reply(401, {"statusCode": 401, "message": "Token missing", "error": "UnauthorizedError"})
        if takes and kind != takes:
            return reply(403, {"statusCode": 403, "message": "You are not allowed to access this resource", "error": f"Forbidden access to {target}"})
        if path == "/api/v3/auth/select-organization":
            session = unsigned_token({"authMethod": "email", "authTokenType": "accessToken", "userId": self.USER, "organizationId": self.ORGANIZATION["id"]})
            return reply(200, {"token": session, "isMfaEnabled": False})
        if path == "/api/v1/organization":
            return reply(200, {"organizations": [self.ORGANIZATION]})
        if path == "/api/v1/user":
            return reply(200, {"user": {"id": self.USER}})
        if path == "/api/v1/identities/details":
            return reply(200, {"identityDetails": {"organization": self.ORGANIZATION}})
        if path in ("/api/v4/secrets", "/api/v2/folders") and kind:
            return reply(404, {"statusCode": 404, "message": "Project with ID 'x' not found", "error": "NotFound"})
        return reply(404, {"statusCode": 404, "message": f"Route {method}:{target} not found", "error": "Not Found"})


class Route:
    """For --selftest: Traefik in front of a Copy. A token whose payload begins {"identityId":, which the last lines of route.yaml refuse, gets
    Traefik's 404, and the rest reaches the copy, whose answers carry helmet's header as Infisical's do."""

    def __init__(self, copy: Copy) -> None:
        self.copy = copy

    def ask(self, method: str, target: str, headers: dict[str, str] | None = None, **_: object) -> tuple[int, dict[str, str], bytes]:
        authorization = (headers or {}).get("Authorization", "")
        if re.search(r"[^ -~]|^.{7}st\.|\.eyJpZGVudGl0eUlkIjo", authorization):
            return 404, {"content-type": "text/plain; charset=utf-8"}, b"404 page not found\n"
        status, body, kind = self.copy.answer(method, target, authorization)
        return status, {"content-type": kind, "x-download-options": "noopen"}, body


@contextlib.contextmanager
def serving(copy: Copy):
    """The copy on a loopback port of its own, as a throwaway copy publishes one, for direct_call to ask."""

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_: object) -> None:
            pass

        def answer(self) -> None:
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            status, data, kind = copy.answer(self.command, self.path, self.headers.get("Authorization", ""), body)
            self.send_response(status)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        do_GET = do_POST = answer

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True).start()
    copy.address = f"http://127.0.0.1:{server.server_address[1]}"
    try:
        yield copy
    finally:
        server.shutdown()
        server.server_close()


def selftest() -> int:
    """This file's own verdicts, with no Docker, no Traefik and no Infisical, so CI can run it. It proves nothing about the route. What curl
    prints below is what curl 8.7.1 printed against the pinned Traefik on this machine."""
    traefik_404 = ("HTTP/2 404 \ncontent-type: text/plain; charset=utf-8\nx-content-type-options: nosniff\ncontent-length: 19\n\n"
                   "404 page not found\n\n404 2")
    h1_404 = "HTTP/1.1 404 Not Found\nContent-Type: text/plain; charset=utf-8\nContent-Length: 19\n\n404 page not found\n\n404 1.1"
    refused_connection = "curl: (7) Failed to connect to infisical.bereket.dev port 18543 after 0 ms: Couldn't connect to server\n"
    reset = "curl: (92) HTTP/2 stream 1 was not closed cleanly: PROTOCOL_ERROR (err 1)\n"

    def echoed(line: str) -> str:
        body = json.dumps({ECHO_MARK: line})
        return f"HTTP/2 200 \ncontent-type: application/json\nx-echo-reached: 1\ncontent-length: {len(body)}\n\n{body}\n200 2"

    def infisical(status: int, answer: dict) -> str:
        body = json.dumps(answer)
        return f"HTTP/2 {status} \ncontent-type: application/json; charset=utf-8\nx-download-options: noopen\ncontent-length: {len(body)}\n\n{body}\n{status} 2"

    path = "/api/docs"
    for real in (False, True):
        arrived = None if real else []
        # What once read PASS in both modes: curl's "000 0" when nothing answered.
        assert h2_verdict(7, "\n000 0", refused_connection, path, real, arrived)[0] == "BLOCKED", "no answer is no refusal"
        assert h2_verdict(0, h1_404, "", path, real, arrived)[0] == "BLOCKED", "an answer over HTTP/1.1 says nothing of HTTP/2"
        assert h2_verdict(0, traefik_404, "", path, real, arrived)[0] == "PASS", "Traefik's 404 over HTTP/2 is a refusal"
        assert h2_verdict(92, "\n000 0", reset, path, real, arrived)[0] == "PASS", "a stream reset as malformed is a refusal"
    assert h2_verdict(92, "\n000 0", reset, path, False, [f"POST {path} HTTP/1.1"])[0] == "FAIL", "a reset after it arrived is no refusal"
    assert h2_verdict(0, echoed(f"POST {path}/ HTTP/1.1"), "", path, False, [f"POST {path}/ HTTP/1.1"])[0] == "FAIL", "Fastify routes it as the path"
    assert h2_verdict(0, echoed(f"POST {path} HTTP/1.1"), "", path, False, [])[0] == "FAIL", "the echo's answer counts, should its line be missed"
    assert h2_verdict(0, echoed("POST /api%2Fdocs HTTP/1.1"), "", path, False, ["POST /api%2Fdocs HTTP/1.1"])[0] == "PASS", "one segment to Fastify"
    handler = infisical(401, {"statusCode": 401, "message": "Token missing", "error": "UnauthorizedError"})
    assert h2_verdict(0, handler, "", path, True, None)[0] == "FAIL", "a handler of Infisical's answered"
    no_route = infisical(404, {"statusCode": 404, "message": f"Route POST:{path} not found", "error": "Not Found"})
    assert h2_verdict(0, no_route, "", path, True, None)[0] == "PASS", "Infisical's router found no route"

    class Curl:
        """In place of subprocess.run: each try gets the next of these results, and the last one after that."""

        def __init__(self, *results: tuple[int, str]) -> None:
            self.results = list(results)
            self.commands: list[list[str]] = []

        def __call__(self, command: list[str], **_: object) -> subprocess.CompletedProcess:
            self.commands.append(command)
            returncode, stderr = self.results.pop(0) if len(self.results) > 1 else self.results[0]
            return subprocess.CompletedProcess(command, returncode, traefik_404 if returncode == 0 else "\n000 0", stderr)

    def no_wait(_seconds: float) -> None:
        pass

    flaky = Curl((7, refused_connection), (7, refused_connection), (0, ""))
    assert h2_ask(1, path, flaky, no_wait)[0] == 0 and len(flaky.commands) == 3, "a try with no answer is made again"
    gone = Curl((7, refused_connection))
    assert h2_ask(1, path, gone, no_wait)[0] == 7 and len(gone.commands) == 5, "five tries, and then no answer"
    malformed = Curl((92, reset))
    assert h2_ask(1, "%2fsignup", malformed, no_wait)[0] == 92 and len(malformed.commands) == 1, "a reset is the same answer at every try"
    command = malformed.commands[0]
    assert command[command.index("--request-target") + 1] == "%2fsignup", "the target goes as it is, past curl's URL parser"

    report = Report()
    with contextlib.redirect_stdout(io.StringIO()):
        report.row("PASS", "a row")
        report.row("BLOCKED", "a row that could not be asked")
        assert report.exit_code() == 2, "a row that could not be asked is no pass"
        report.row("FAIL", "a row that got through")
        assert report.exit_code() == 1, "what got through outweighs what could not be asked"

    # Another run's echo server on this run's port, which once ended this run with a traceback and exit 1, as if something got through.
    with socket.create_server(("127.0.0.1", 0)) as held, tempfile.TemporaryDirectory() as directory:
        port = held.getsockname()[1]
        log = pathlib.Path(directory, "rows.log")
        second = argparse.Namespace(port=1, echo_port=port, backend="echo", direct="", throwaway="", log=str(log))
        assert "INFISICAL_ROUTE_TEST_ECHO_PORT" in preflight(second), "the preflight names the port, and how to give this run its own"
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as said:
            assert run(second) == 2, "a port taken after the preflight stops the run as one that could not run"
        assert "INFISICAL_ROUTE_TEST_ECHO_PORT" in said.getvalue() and not log.exists(), said.getvalue()
        assert preflight(argparse.Namespace(echo_port=port, backend="real", direct="", throwaway="")) == "", "a real backend needs no echo server"

    def published(address: str, host_ip: str = "127.0.0.1", running: bool = True):
        """docker inspect for a container that publishes the port of address, as Docker Desktop writes it."""
        port = address.rstrip("/").rsplit(":", 1)[1]
        return lambda _name: {"State": {"Running": running}, "NetworkSettings": {"Ports": {"8080/tcp": [{"HostIp": host_ip, "HostPort": port}]}}}

    def never(_name: str) -> dict:
        raise AssertionError("Docker was asked about a target nobody named")

    def real_token_rows(copy: Copy, address: str = "", throwaway: str = "copy", inspect=None) -> Report:
        address = address or copy.address
        report = Report()
        with contextlib.redirect_stdout(io.StringIO()):
            direct_rows(report, Route(copy), address, throwaway, inspect or published(address))
        return report

    # Direct mode claims what it asks, so it asks only a running container named as a copy to throw away, at the port it publishes on
    # loopback. It once claimed whatever unclaimed Infisical answered there, a port-forward to production's among them.
    direct = "http://127.0.0.1:18210"
    assert "INFISICAL_ROUTE_TEST_THROWAWAY" in throwaway_refusal(direct, "", never), "with no name, nothing is asked"
    for address in ("http://localhost:18210", "https://127.0.0.1:18210", "http://127.0.0.1", "http://127.0.0.1:18210/api", "http://10.0.0.5:18210",
                    "http://127.0.0.1:99999", "http://user@127.0.0.1:18210"):
        assert throwaway_refusal(address, "copy", published(direct)), address
    assert throwaway_refusal(direct, "--format", published(direct)), "a flag is no container's name"
    assert throwaway_refusal(direct, "copy", lambda _name: None), "Docker knows no such container"
    assert throwaway_refusal(direct, "copy", published(direct, running=False)), "a stopped container holds no port"
    assert throwaway_refusal(direct, "copy", published(direct, host_ip="0.0.0.0")), "a port-forward on 127.0.0.1 answers before a binding on every address"
    assert throwaway_refusal(direct, "copy", published("http://127.0.0.1:18211")), "another port is another target"
    assert throwaway_refusal(direct, "copy", published(direct)) == throwaway_refusal(direct + "/", "copy", published(direct)) == ""
    with serving(Copy()) as copy:
        unnamed = argparse.Namespace(backend="real", echo_port=0, direct=copy.address, throwaway="")
        assert "INFISICAL_ROUTE_TEST_THROWAWAY" in preflight(unnamed, never) and copy.calls == [], "an unnamed copy is asked nothing"
        report = real_token_rows(copy, throwaway="", inspect=never)
        assert report.blocked == 1 and copy.calls == [] and not copy.claimed, "the claim refuses it too, whatever called it"
        named = argparse.Namespace(backend="real", echo_port=0, direct=copy.address, throwaway="copy")
        assert preflight(named, published(copy.address)) == "" and copy.calls == ["GET /api/v1/admin/config"] and not copy.claimed
        assert preflight(argparse.Namespace(backend="echo", echo_port=0, direct=copy.address, throwaway="copy")), "the echo server hands out no token"
        assert preflight(argparse.Namespace(backend="real", echo_port=0, direct="", throwaway="copy"), never), "a copy named with nowhere to ask it"
    with serving(Copy(claimed=True)) as copy:
        claimed = argparse.Namespace(backend="real", echo_port=0, direct=copy.address, throwaway="copy")
        assert "claimed already" in preflight(claimed, published(copy.address)), "a copy claimed already stops the run before it starts"

    # The copy answers an identity's token 403 at GET /api/v1/organization, as the image does, so the row that once asked there reads FAIL.
    with serving(Copy()) as copy:
        report = real_token_rows(copy)
        assert (report.passed, report.failed, report.blocked) == (8, 0, 0), report.lines
        assert "GET /api/v1/identities/details identityAccessToken" in copy.calls, copy.calls
    # A version that writes an identity's token another way: its shape, and the three calls the route then lets through.
    with serving(Copy(identity_first="authTokenType")) as copy:
        report = real_token_rows(copy)
        assert report.failed == 4, report.lines
    # A copy claimed already, which once read INFO and exit 0, and one that is not Infisical: neither can be asked, and neither is a pass.
    with serving(Copy(claimed=True)) as copy:
        report = real_token_rows(copy)
        assert (report.blocked, report.failed, report.passed) == (1, 0, 0) and copy.calls == ["GET /api/v1/admin/config"], copy.calls
    with serving(Copy(garbled=True)) as copy:
        report = real_token_rows(copy)
        assert (report.blocked, report.passed) == (1, 0), report.lines
    # An address with nothing behind it, which once ended the run with a traceback before its log was written.
    with socket.create_server(("127.0.0.1", 0)) as nothing:
        address = f"http://127.0.0.1:{nothing.getsockname()[1]}"
    report = real_token_rows(Copy(), address)
    assert (report.blocked, report.passed) == (1, 0) and "gave no answer" in report.lines[0], report.lines
    print("selftest ok")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int)
    parser.add_argument("--echo-port", type=int, default=0)
    parser.add_argument("--backend", choices=["echo", "real"], default="echo")
    # The backend's own address from this machine, past Traefik, and the container that publishes it there, named as a copy to throw away.
    # Given both, on a copy nobody has claimed, real_tokens claims it and asks with what it hands out.
    parser.add_argument("--direct", default="")
    parser.add_argument("--throwaway", default="")
    parser.add_argument("--log")
    # Whether a run could start, and nothing more, so the shell wrapper can ask before it starts Traefik.
    parser.add_argument("--preflight", action="store_true")
    # This file's own verdicts, with nothing started, so CI can run it.
    parser.add_argument("--selftest", action="store_true")
    arguments = parser.parse_args()
    if arguments.selftest:
        return selftest()
    refusal = preflight(arguments)
    if refusal:
        print(f"cannot run: {refusal}", file=sys.stderr)
        return 2
    if arguments.preflight:
        return 0
    if arguments.port is None or not arguments.log:
        parser.error("a run needs --port and --log")
    return run(arguments)


if __name__ == "__main__":
    raise SystemExit(main())
