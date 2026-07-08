#!/usr/bin/env python3
"""Fake Infisical HTTP API for tests/drills/clean-restore-harness.sh. Its database is $H_STATE/api.json, which a backup
copies and a restore puts back, so a token minted after a dump is not in that dump.

It behaves as the real one does on what the scripts rely on: nothing answers while the server is at zero replicas or
its secret zero is not applied, an unknown or expired token gets 401 on every route that wants one, a password login
checks the password, and only the first admin's org session can mint a token for the instance admin identity."""
import base64, json, os, sys, time, uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlsplit

S = os.environ["H_STATE"]


def st():
    with open(f"{S}/api.json") as f:
        return json.load(f)


def put(d):
    with open(f"{S}/api.json.tmp", "w") as f:
        json.dump(d, f)
    os.replace(f"{S}/api.json.tmp", f"{S}/api.json")


def cluster():
    try:
        with open(f"{S}/cluster.json") as f:
            return json.load(f)
    except FileNotFoundError:
        return {"exists": False}


def log(line):
    with open(f"{S}/calls.log", "a") as f:
        f.write(line + "\n")


def server_up():
    c = cluster()
    return c.get("exists") and not c.get("stopped") and not c.get("infisical_migrating") and "infisical-secrets" in c.get("zero", {}) and c.get("workloads", {}).get("infisical/infisical", 1) > 0


def migrations_go_on():
    """A fresh server answers nothing until its migrations are done. Each look at its status lets them go on a bit."""
    c = cluster()
    if c.get("infisical_migrating") and "infisical-secrets" in c.get("zero", {}):
        c["infisical_migrating"] -= 1
        with open(f"{S}/cluster.json.api", "w") as f:
            json.dump(c, f)
        os.replace(f"{S}/cluster.json.api", f"{S}/cluster.json")


def jwt(claims):
    body = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
    return f"x.{body}.y"


def claims_of(token):
    try:
        part = token.split(".")[1]
        return json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
    except Exception:
        return {}


def sessions():
    try:
        with open(f"{S}/sessions.json") as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def out(self, code, body):
        b = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def bearer(self):
        h = self.headers.get("Authorization", "")
        return h[7:] if h.startswith("Bearer ") else ""

    def identity_ok(self, d):
        t = self.bearer()
        if t not in d.get("tokens", []):
            return False
        exp = claims_of(t).get("exp", 0)
        return not exp or exp > time.time()

    def org_session(self):
        return sessions().get(self.bearer()) == "org"

    def refuse(self):
        return self.out(401, {"message": "Token invalid"})

    def do_GET(self):
        u = urlsplit(self.path)
        q = parse_qs(u.query)
        if u.path == "/fake/argocd":
            return self.out(200 if cluster().get("namespaces") else 503, {})
        if u.path == "/fake/registry":
            return self.out(503 if os.path.exists(f"{S}/registry-down") else 200, {})
        if u.path.startswith("/fake/prometheus"):
            return self.out(200, {"data": {"result": [{"value": [0, "1"]}]}})
        if u.path == "/api/status":
            migrations_go_on()
        if not server_up():
            return self.out(503, {"message": "no available server"})
        d = st()
        if u.path == "/api/status":
            return self.out(200, {"message": "ok"})
        if u.path == "/api/v1/admin/config":
            cfg = {"initialized": d["initialized"]}
            if self.org_session() or self.identity_ok(d):
                cfg["adminIdentityIds"] = [d.get("admin_identity", "adm")]
            return self.out(200, {"config": cfg})
        if u.path == "/api/v1/organization":
            if sessions().get(self.bearer()) not in ("global", "org"):
                return self.refuse()
            return self.out(200, {"organizations": [{"id": d.get("org", "org-old"), "name": "wayline", "slug": "wayline-x"}]})
        if u.path.endswith("/identity-memberships"):
            org = u.path.split("/")[4]
            if not (self.identity_ok(d) or self.org_session()):
                return self.refuse()
            if org != d.get("org"):
                return self.out(403, {"message": "not this organization"})
            return self.out(200, {"identityMemberships": []})
        if u.path == "/api/v4/secrets":
            if not self.identity_ok(d):
                log("api GET secrets refused: token not accepted")
                return self.refuse()
            pid = q["projectId"][0]
            view = q.get("viewSecretValue", ["false"])[0] == "true"
            secs = d["projects"].get(pid, {})
            out = []
            for k, v in sorted(secs.items()):
                item = {"secretKey": k, "version": v["version"], "id": v["id"]}
                if view:
                    item["secretValue"] = v["value"]
                out.append(item)
            log(f"api GET secrets project={pid} view={view}")
            return self.out(200, {"secrets": out, "imports": []})
        if u.path.startswith("/api/v4/secrets/"):
            if not self.identity_ok(d):
                return self.refuse()
            secret = d["projects"].get(q["projectId"][0], {}).get(u.path.split("/")[4])
            if secret is None:
                return self.out(404, {"message": "no such secret"})
            return self.out(200, {"secret": {"secretValue": secret["value"], "version": secret["version"], "id": secret["id"]}})
        self.out(404, {"message": "not stubbed " + u.path})

    def do_POST(self):
        if not server_up():
            return self.out(503, {"message": "no available server"})
        n = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        d = st()
        u = urlsplit(self.path)
        if u.path == "/api/v1/admin/bootstrap":
            log("api POST bootstrap")
            if d["initialized"]:
                return self.out(400, {"message": "Instance has already been set up"})
            d["initialized"] = True
            d["org"] = str(uuid.uuid4())
            d["admin_identity"] = str(uuid.uuid4())
            d["password"] = body["password"]
            token = jwt({"exp": int(time.time()) + 90 * 86400, "identityId": d["admin_identity"], "identityName": "Instance Admin Identity", "orgId": d["org"]})
            d["tokens"] = [token]
            put(d)
            return self.out(200, {"user": {"email": body["email"]}, "organization": {"id": d["org"], "name": "wayline", "slug": "wayline-x"}, "identity": {"id": d["admin_identity"], "name": "Instance Admin Identity", "credentials": {"token": token}}})
        if u.path == "/api/v3/auth/login":
            log("api POST login")
            if body.get("password", "").strip() != d.get("password") or not d.get("password"):
                return self.out(400, {"message": "Invalid credentials"})
            s = sessions()
            t = f"session-{uuid.uuid4()}"
            s[t] = "global"
            with open(f"{S}/sessions.json", "w") as f:
                json.dump(s, f)
            return self.out(200, {"accessToken": t})
        if u.path == "/api/v3/auth/select-organization":
            s = sessions()
            if s.get(self.bearer()) != "global":
                return self.refuse()
            if body.get("organizationId") != d.get("org"):
                return self.out(403, {"message": "not a member"})
            t = f"session-{uuid.uuid4()}"
            s[t] = "org"
            with open(f"{S}/sessions.json", "w") as f:
                json.dump(s, f)
            return self.out(200, {"token": t, "isMfaEnabled": False})
        if u.path.startswith("/api/v1/auth/token-auth/identities/"):
            if not self.org_session():
                return self.refuse()
            identity = u.path.split("/")[6]
            if identity != d.get("admin_identity"):
                return self.out(404, {"message": "no such identity"})
            token = jwt({"exp": int(time.time()) + 90 * 86400, "identityId": identity, "identityName": "Instance Admin Identity", "orgId": d["org"]})
            d["tokens"].append(token)
            put(d)
            log("api POST mint")
            return self.out(200, {"accessToken": token, "tokenData": {"id": str(uuid.uuid4())}})
        if u.path == "/api/v4/secrets/batch":
            if not self.identity_ok(d):
                return self.refuse()
            log(f"api POST secrets/batch n={len(body['secrets'])}")
            p = d["projects"].setdefault(body["projectId"], {})
            for s in body["secrets"]:
                p[s["secretKey"]] = {"value": s["secretValue"], "version": 1, "id": str(uuid.uuid4())}
            put(d)
            return self.out(200, {"secrets": []})
        self.out(404, {"message": "not stubbed"})


HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
