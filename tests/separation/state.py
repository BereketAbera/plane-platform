#!/usr/bin/env python3
"""What each environment holds and who it talks to: identity, storage, credentials, data, sessions.

Writes marker data through each environment's real API, then looks for it in both. Every absence is
checked against a positive control in the environment that holds it, using the same query. Secret
values are read into memory only, and everything printed is scanned for them.

Needs both environments Synced and Healthy, and tests/e2e/smoke.py to have run in each, because it signs in with the
accounts that made. Each run leaves one marker workspace in each environment, as a smoke run does.

Exit status: 0 everything passed, 1 something failed, 2 nothing failed but something could not run.
"""
from __future__ import annotations

import json
import re
import secrets
import subprocess
import sys
from urllib.parse import parse_qs, urlsplit

from common import ENVS, NOT_CREDENTIALS as SAME_BY_DESIGN, OTHER, ROOT, SECRET_NAMES, Blocked, Report, attempts_printed, credential_values, kubectl, must, now, read_secrets, require_environments

sys.path.insert(0, str(ROOT / "tests" / "e2e"))
import smoke  # noqa: E402  the project's own client: real HTTP through Traefik, no new protocol code

ACCOUNTS = ROOT / ".local" / "test-accounts.env"
HOSTS = smoke.HOSTS

report = Report()
say = report.say
check = report.check


def psql(namespace: str, sql: str) -> str:
    return must("-n", namespace, "exec", "plane-pgdb-wl-0", "-c", "plane-pgdb", "--", "sh", "-c",
                'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "$1"', "--", sql).strip()


def valkey(namespace: str, *args: str) -> str:
    return must("-n", namespace, "exec", "plane-redis-wl-0", "-c", "plane-redis", "--", "valkey-cli", *args).strip()


def all_pod_ips() -> dict:
    # Running only: a finished backup pod keeps its address, which a running pod elsewhere may have reused.
    listed = json.loads(must("get", "pods", "-A", "-o", "json"))["items"]
    return {p["status"]["podIP"]: f"{p['metadata']['namespace']}/{p['metadata']['name']}" for p in listed
            if p["status"].get("podIP") and p["status"].get("phase") == "Running"}


def run_in_api(env: str, script: str, stdin: dict | None = None, *argv: str) -> str:
    return must("-n", ENVS[env], "exec", "-i", "deploy/plane-api-wl", "-c", "plane-api", "--", "python", "-c", script, *argv,
                stdin=json.dumps(stdin or {}))


# ----------------------------------------------------------------------------------------------- 1

def identity() -> None:
    say(f"\n## 1. Separate servers and separate storage. {now()}")
    identifiers = {}
    for env, namespace in ENVS.items():
        identifiers[env] = psql(namespace, "select system_identifier from pg_control_system()")
        started = psql(namespace, "select pg_postmaster_start_time()")
        say(f"{namespace} postgres system_identifier={identifiers[env]} started={started}")
    check(identifiers["dev"] != identifiers["prod-sim"], "the two Postgres clusters have different system identifiers, so neither is a copy or a shared server")

    run_ids = {}
    for env, namespace in ENVS.items():
        info = valkey(namespace, "INFO", "server")
        run_ids[env] = re.search(r"run_id:(\S+)", info).group(1)
        say(f"{namespace} valkey run_id={run_ids[env][:8]} (first 8 hex of 40) dbsize={valkey(namespace, 'DBSIZE')}")
    check(run_ids["dev"] != run_ids["prod-sim"], "the two Valkey servers have different run ids")

    marker = f"sep-valkey-{secrets.token_hex(6)}"
    valkey("plane-dev", "SET", marker, "dev", "EX", "300")
    in_dev = valkey("plane-dev", "GET", marker)
    in_sim = valkey("plane-prod-sim", "GET", marker)
    say(f"key {marker}: written in plane-dev, reads {in_dev!r} there and {in_sim!r} in plane-prod-sim")
    check(in_dev == "dev" and in_sim == "", "a Valkey key written in dev exists there and not in prod-sim")
    valkey("plane-dev", "DEL", marker)

    probe = 'import boto3,json,os;from botocore.config import Config\ns3=boto3.client("s3",endpoint_url=os.environ["AWS_S3_ENDPOINT_URL"],aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],config=Config(signature_version="s3v4"))\nprint(json.dumps([[b["Name"],b["CreationDate"].isoformat()] for b in s3.list_buckets()["Buckets"]]))'
    buckets = {env: json.loads(run_in_api(env, probe).strip().splitlines()[-1]) for env in ENVS}
    say(f"silo buckets: {json.dumps(buckets)}")
    check(buckets["dev"][0][0] == buckets["prod-sim"][0][0] == "uploads" and buckets["dev"][0][1] != buckets["prod-sim"][0][1],
          "each Silo holds its own bucket uploads, created at different moments")

    pvcs = {}
    for env, namespace in ENVS.items():
        items = json.loads(must("-n", namespace, "get", "pvc", "-o", "json"))["items"]
        for item in items:
            if item["spec"].get("volumeName"):
                volume = json.loads(must("get", "pv", item["spec"]["volumeName"], "-o", "json"))
                path = volume["spec"].get("hostPath", {}).get("path") or volume["spec"].get("local", {}).get("path")
                pvcs[(env, item["metadata"]["name"])] = (item["spec"]["volumeName"], path)
                say(f"{namespace} pvc {item['metadata']['name']} -> {item['spec']['volumeName']} at {path}")
    paths = [v[1] for v in pvcs.values()]
    check(len(paths) == len(set(paths)) and all(ENVS[env] in path or path.startswith(f"/backups/{env}") for (env, _), (_, path) in pvcs.items()),
          f"all {len(paths)} volumes are distinct directories, and each path names its own environment")
    for env, namespace in ENVS.items():
        ip = kubectl("-n", namespace, "get", "pod", "plane-pgdb-wl-0", "-o", "jsonpath={.status.podIP}").stdout
        say(f"{namespace} plane-pgdb-wl-0 pod IP {ip}")


def connected() -> None:
    say(f"\n## 2. Who is really connected, read from the servers and from the node's conntrack table. {now()}")
    ips = all_pod_ips()

    def namespaces_of(addresses) -> dict:
        return {address: ips.get(address, "not a pod") for address in addresses}

    for env, namespace in ENVS.items():
        rows = psql(namespace, "select distinct client_addr from pg_stat_activity where client_addr is not null").split()
        owners = namespaces_of(row.split("/")[0] for row in rows)
        say(f"{namespace} postgres clients: {json.dumps(owners)}")
        check(bool(owners) and all(o.startswith(namespace + "/") for o in owners.values()), f"every Postgres client of {namespace} is a pod in {namespace}")

        clients = valkey(namespace, "CLIENT", "LIST")
        addresses = {m.group(1) for m in re.finditer(r"addr=([0-9.]+):\d+", clients)} - {"127.0.0.1"}
        owners = namespaces_of(addresses)
        say(f"{namespace} valkey clients: {json.dumps(owners)}")
        check(bool(owners) and all(o.startswith(namespace + "/") for o in owners.values()), f"every Valkey client of {namespace} is a pod in {namespace}")

        listed = must("-n", namespace, "exec", "plane-rabbitmq-wl-0", "-c", "plane-rabbitmq", "--", "rabbitmqctl", "-q", "list_connections",
                      "peer_host", "--no-table-headers").split()
        addresses = {row.replace("::ffff:", "") for row in listed}
        owners = namespaces_of(addresses)
        say(f"{namespace} rabbitmq connections: {len(listed)}, from {json.dumps(owners)}")
        check(bool(owners) and all(o.startswith(namespace + "/") for o in owners.values()), f"every AMQP client of {namespace} is a pod in {namespace}")

    try:
        done = subprocess.run(["docker", "exec", "plane-platform-control-plane", "conntrack", "-L", "-p", "tcp"], capture_output=True, text=True, timeout=60, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        report.block(f"could not read the node's conntrack table: {type(exc).__name__}")
        return
    flows = [line for line in done.stdout.splitlines() if line.startswith("tcp")]
    scope = {ip: owner.split("/")[0] for ip, owner in ips.items()}
    crossing = silo = 0
    for line in flows:
        tuples = re.findall(r"src=([0-9.]+) dst=([0-9.]+) sport=\d+ dport=(\d+)", line)
        if len(tuples) < 2:
            continue
        addresses = {tuples[0][0], tuples[0][1], tuples[1][0], tuples[1][1]}
        owners = {scope.get(a) for a in addresses}
        if {"plane-dev", "plane-prod-sim"} <= owners:
            crossing += 1
            say(f"crossing flow: {line[:200]}")
        if "plane-prod-sim" in owners and tuples[0][2] == "9000":
            silo += 1
    say(f"conntrack: {len(flows)} TCP flows on the node, {crossing} between a plane-dev pod and a plane-prod-sim pod, {silo} to prod-sim's Silo port")
    check(len(flows) > 100 and crossing == 0, "no TCP flow in the node's conntrack table joins the two environments")


# ----------------------------------------------------------------------------------------------- 3

CREDENTIAL_ATTEMPTS = r"""
import json, os, sys, urllib.parse
given = json.load(sys.stdin)
def attempt(name, fn):
    try:
        print(json.dumps({"attempt": name, "verdict": "ACCEPTED", "detail": fn()}))
    except Exception as exc:
        code = getattr(exc, "response", {}).get("Error", {}).get("Code") if hasattr(exc, "response") else None
        print(json.dumps({"attempt": name, "verdict": "REFUSED", "error": type(exc).__name__, "code": code, "detail": str(exc).replace("\n", " ")[:170]}))
def pg(password):
    import psycopg
    u = urllib.parse.urlsplit(os.environ["DATABASE_URL"])
    with psycopg.connect(host=u.hostname, dbname=u.path.lstrip("/"), user=u.username, password=password, connect_timeout=5) as c:
        return "SELECT 1 -> %s" % c.execute("select 1").fetchone()[0]
def rabbit(password):
    import amqp
    u = urllib.parse.urlsplit(os.environ["AMQP_URL"])
    c = amqp.Connection(host=u.hostname + ":5672", userid=urllib.parse.unquote(u.username), password=password, connect_timeout=5)
    c.connect()
    c.close()
    return "AMQP opened"
def silo(key, secret):
    import boto3
    from botocore.config import Config
    s3 = boto3.client("s3", endpoint_url=os.environ["AWS_S3_ENDPOINT_URL"], aws_access_key_id=key, aws_secret_access_key=secret, region_name="us-east-1",
                      config=Config(signature_version="s3v4", retries={"total_max_attempts": 1}))
    return "ListBuckets -> %s" % [b["Name"] for b in s3.list_buckets()["Buckets"]]
own = {"pg": urllib.parse.urlsplit(os.environ["DATABASE_URL"]).password, "amqp": urllib.parse.unquote(urllib.parse.urlsplit(os.environ["AMQP_URL"]).password)}
attempt("own postgres password", lambda: pg(own["pg"]))
attempt("other environment's postgres password", lambda: pg(given["pg"]))
attempt("own rabbitmq password", lambda: rabbit(own["amqp"]))
attempt("other environment's rabbitmq password", lambda: rabbit(given["amqp"]))
attempt("own silo keys", lambda: silo(os.environ["AWS_ACCESS_KEY_ID"], os.environ["AWS_SECRET_ACCESS_KEY"]))
attempt("other environment's silo keys", lambda: silo(given["s3_key"], given["s3_secret"]))
"""
CREDENTIAL_ATTEMPT_NAMES = re.findall(r'^attempt\("([^"]+)"', CREDENTIAL_ATTEMPTS, flags=re.M)


def credentials() -> None:
    say(f"\n## 3. Separate credentials. Only same or different is printed, never a value. {now()}")
    stores = read_secrets()
    for name in SECRET_NAMES:
        for key in sorted(stores["dev"][name]):
            left, right = stores["dev"][name].get(key), stores["prod-sim"][name].get(key)
            same = left == right
            kind = "same by design" if (name, key) in SAME_BY_DESIGN else "must differ"
            say(f"{name:26} {key:28} {'same' if same else 'different':10} {kind}")
            if (name, key) in SAME_BY_DESIGN:
                check(same, f"{name}/{key} is the same in both, as the contract fixes it")
            else:
                check(not same, f"{name}/{key} differs between the environments")
                report.add_secrets(v for v in (left, right) if v and len(v) >= 6)
    for env, namespace in ENVS.items():
        app = stores[env]["plane-app-env"]
        hosts = {key: urlsplit(app[key]).hostname for key in ("DATABASE_URL", "REDIS_URL", "AMQP_URL")}
        hosts["live REDIS_URL"] = urlsplit(stores[env]["plane-live-env"]["REDIS_URL"]).hostname
        hosts["AWS_S3_ENDPOINT_URL"] = stores[env]["plane-doc-store"]["AWS_S3_ENDPOINT_URL"]
        say(f"{namespace} connection targets: {json.dumps(hosts)}")
        check(all(namespace in hosts[k] for k in ("DATABASE_URL", "REDIS_URL", "AMQP_URL", "live REDIS_URL")),
              f"every connection string in {namespace} names a server in {namespace}")
    say("")
    say("Real attempts, inside each environment's api pod, where the network allows them: its own credential, then the other environment's.")
    for env in ENVS:
        other = stores[OTHER[env]]
        given = {"pg": urlsplit(other["plane-app-env"]["DATABASE_URL"]).password,
                 "amqp": other["plane-rabbitmq"]["RABBITMQ_DEFAULT_PASS"],
                 "s3_key": other["plane-doc-store"]["AWS_ACCESS_KEY_ID"],
                 "s3_secret": other["plane-doc-store"]["AWS_SECRET_ACCESS_KEY"]}
        printed = attempts_printed(run_in_api(env, CREDENTIAL_ATTEMPTS, given), "attempt")
        for name in CREDENTIAL_ATTEMPT_NAMES:
            record = printed.get(name)
            if record is None:
                report.block(f"{ENVS[env]}: {name}: the exec exited 0 and printed no result for it, so it says nothing either way")
                continue
            say(f"{ENVS[env]} {json.dumps(record)}")
            if record["attempt"].startswith("own"):
                check(record["verdict"] == "ACCEPTED", f"{ENVS[env]}: {record['attempt']} is accepted")
            else:
                refused = record["verdict"] == "REFUSED" and (
                    "password authentication failed" in record["detail"] or record.get("error") == "AccessRefused"
                    or record.get("code") in ("InvalidAccessKeyId", "SignatureDoesNotMatch"))
                check(refused, f"{ENVS[env]}: {record['attempt']} is refused by the server, as an authentication failure")
    # Valkey has no password in either environment, so say so plainly.
    for env, namespace in ENVS.items():
        required = valkey(namespace, "CONFIG", "GET", "requirepass").splitlines()
        say(f"{namespace} valkey requirepass: {'empty, no password' if len(required) < 2 or not required[1] else 'set'}")


# ----------------------------------------------------------------------------------------------- 4

SILO_KEYS = r"""
import boto3, json, os, sys
from botocore.config import Config
from botocore.exceptions import ClientError
given = json.load(sys.stdin)
s3 = boto3.client("s3", endpoint_url=os.environ["AWS_S3_ENDPOINT_URL"], aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
                  aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"], config=Config(signature_version="s3v4"))
bucket = os.environ["AWS_S3_BUCKET_NAME"]
heads = {}
for key in given["keys"]:
    try:
        s3.head_object(Bucket=bucket, Key=key)
        heads[key] = 200
    except ClientError as exc:
        heads[key] = int(exc.response["ResponseMetadata"]["HTTPStatusCode"])
listed = []
for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket):
    listed += [item["Key"] for item in page.get("Contents", [])]
print(json.dumps({"heads": heads, "all_keys": listed}))
"""


class Env:
    def __init__(self, env: str) -> None:
        self.env = env
        self.namespace = ENVS[env]
        self.host = HOSTS[env]
        self.accounts = smoke.Accounts(ACCOUNTS, env)
        self.token = self.accounts.get("API_TOKEN")
        if not (self.token and self.accounts.get("ADMIN_EMAIL") and self.accounts.get("ADMIN_PASSWORD")):
            raise Blocked(f"{ACCOUNTS} has no account for {env}. Run: make test-e2e ENV={env}")
        report.add_secrets([self.token, self.accounts.get("ADMIN_PASSWORD")])
        self.http = smoke.Http(self.host, "127.0.0.1", 80)
        self.marker = f"sep-{env}-{secrets.token_hex(5)}"
        self.slug = self.marker
        self.state: dict = {}

    def key(self) -> dict:
        return {"X-API-Key": self.token}

    def sign_in(self) -> None:
        csrf = smoke.expect(self.http.get("/auth/get-csrf-token/"), 200).json()["csrf_token"]
        response = self.http.post_form("/auth/sign-in/", {"csrfmiddlewaretoken": csrf, "email": self.accounts.get("ADMIN_EMAIL"),
                                                          "password": self.accounts.get("ADMIN_PASSWORD")})
        smoke.expect(response, 302)
        if "error_code" in parse_qs(urlsplit(response.location).query):
            raise Blocked(f"sign-in in {self.env} failed, with the account in {ACCOUNTS}")

    def create(self) -> None:
        self.sign_in()
        smoke.expect(self.http.send_json("POST", "/api/workspaces/", {"name": self.marker, "slug": self.slug, "organization_size": "1-10"}), 201)
        identifier = "S" + secrets.token_hex(3).upper()
        project = smoke.expect(self.http.send_json("POST", f"/api/v1/workspaces/{self.slug}/projects/", {"name": f"Sep {identifier}", "identifier": identifier},
                                                   session=False, headers=self.key()), 201).json()
        base = f"/api/v1/workspaces/{self.slug}/projects/{project['id']}"
        item = smoke.expect(self.http.send_json("POST", f"{base}/work-items/", {"name": f"{self.marker} item"}, session=False, headers=self.key()), 201).json()
        content = f"{self.marker}\n{secrets.token_hex(64)}\n".encode()
        grant = smoke.expect(self.http.send_json("POST", f"{base}/work-items/{item['id']}/attachments/", {"name": "sep.txt", "type": "text/plain", "size": len(content)},
                                                 session=False, headers=self.key()), 200).json()
        upload = grant["upload_data"]
        content_type, body = smoke.multipart(upload["fields"], "sep.txt", "text/plain", content)
        smoke.expect(self.http.request("POST", urlsplit(upload["url"]).path, session=False, body=body, headers={"Content-Type": content_type}), 204, 201)
        smoke.expect(self.http.send_json("PATCH", f"{base}/work-items/{item['id']}/attachments/{grant['asset_id']}/", {}, session=False, headers=self.key()), 204)
        self.state.update(project=project["id"], item=item["id"], base=base, key=upload["fields"]["key"], asset=grant["asset_id"], item_name=f"{self.marker} item")
        say(f"{self.namespace}: created workspace {self.slug}, project {project['id']}, work item {item['id']} and an attachment at key {upload['fields']['key']}")


def dump_count(namespace: str, needle: str) -> tuple[int, int]:
    """Every table's data, as pg_dump writes it. Prints the dump's exit status, so a failed dump cannot read as zero."""
    script = ('f=$(mktemp); pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --data-only >"$f"; rc=$?; '
              'lines=$(wc -l <"$f"); hits=$(grep -c -- "$1" "$f"); rm -f "$f"; echo "$rc $lines $hits"')
    printed = must("-n", namespace, "exec", "plane-pgdb-wl-0", "-c", "plane-pgdb", "--", "sh", "-c", script, "--", needle, timeout=180).split()
    if printed[0] != "0":
        raise Blocked(f"pg_dump in {namespace} exited {printed[0]}")
    return int(printed[2]), int(printed[1])


def data() -> None:
    say(f"\n## 4. Data created in one environment does not appear in the other. {now()}")
    envs = {env: Env(env) for env in ENVS}
    for item in envs.values():
        item.create()
    # Background work may still be writing activity rows, and that only adds to the holder's count.
    for source, holder in envs.items():
        reader = envs[OTHER[source]]
        say(f"\nmarker {holder.marker}, created in {holder.namespace}:")
        for sql, label in ((f"select count(*) from workspaces where slug = '{holder.slug}'", "workspaces.slug"),
                           (f"select count(*) from issues where name = '{holder.state['item_name']}'", "issues.name"),
                           (f"select count(*) from issues where id = '{holder.state['item']}'", "issues.id"),
                           (f"select count(*) from file_assets where id = '{holder.state['asset']}'", "file_assets.id")):
            mine, theirs = psql(holder.namespace, sql), psql(reader.namespace, sql)
            say(f"  sql {label}: {holder.namespace}={mine} {reader.namespace}={theirs}")
            check(mine == "1" and theirs == "0", f"{label} of {holder.marker} is found in {holder.namespace} and not in {reader.namespace}")
        mine, mine_lines = dump_count(holder.namespace, holder.marker)
        theirs, their_lines = dump_count(reader.namespace, holder.marker)
        say(f"  whole-database scan, pg_dump --data-only: {holder.namespace} {mine} lines of {mine_lines} hold the marker, {reader.namespace} {theirs} of {their_lines}")
        check(mine >= 2 and theirs == 0 and their_lines > 100, f"a scan of every table finds {holder.marker} in {holder.namespace} and nowhere in {reader.namespace}")

        target = f"{holder.state['base']}/work-items/{holder.state['item']}/"
        own = holder.http.get(target, session=False, headers=holder.key()).status
        other = reader.http.get(target, session=False, headers=reader.key()).status
        workspace_own = holder.http.get(f"/api/workspaces/{holder.slug}/").status
        reader.sign_in()
        workspace_other = reader.http.get(f"/api/workspaces/{holder.slug}/").status
        say(f"  api: work item with {holder.env}'s key on {holder.host} {own}; the same path with {reader.env}'s key on {reader.host} {other}; "
            f"workspace by session, {holder.host} {workspace_own}, {reader.host} {workspace_other}")
        check(own == 200 and other in (403, 404), f"{holder.marker}'s work item is served by {holder.host} and refused by {reader.host}")
        check(workspace_own == 200 and workspace_other in (403, 404), f"{holder.marker}'s workspace is served by {holder.host} and not by {reader.host}")

        key = holder.state["key"]
        heads = {env: json.loads(run_in_api(env, SILO_KEYS, {"keys": [key]}).strip().splitlines()[-1])["heads"][key] for env in (holder.env, reader.env)}
        say(f"  silo: HEAD {key}: {holder.namespace} {heads[holder.env]}, {reader.namespace} {heads[reader.env]}")
        check(heads[holder.env] == 200 and heads[reader.env] == 404, f"{holder.marker}'s object is in {holder.namespace}'s Silo and not in {reader.namespace}'s")

        redirect = smoke.expect(holder.http.get(f"{holder.state['base']}/work-items/{holder.state['item']}/attachments/{holder.state['asset']}/", session=False, headers=holder.key()), 302)
        signed = urlsplit(redirect.location)
        own_fetch = holder.http.get(f"{signed.path}?{signed.query}", session=False, headers={"Accept": "*/*"}).status
        other_fetch = reader.http.get(f"{signed.path}?{signed.query}", session=False, headers={"Accept": "*/*"}).status
        say(f"  presigned link from {holder.host}: there {own_fetch}, replayed against {reader.host} {other_fetch}")
        check(own_fetch == 200 and other_fetch in (403, 404), f"a presigned link from {holder.host} does not open anything on {reader.host}")

    say("\nWhole-set overlap between the two environments, every row and object, counts only:")
    for sql, label in (("select slug from workspaces", "workspace slugs"), ("select id from users", "user ids"), ("select id from workspaces", "workspace ids"),
                       ("select id from projects", "project ids"), ("select id from issues", "issue ids"), ("select id from file_assets", "file asset ids"),
                       ("select md5(token) from api_tokens", "API tokens, compared by md5"), ("select instance_id from instances", "instance ids"),
                       ("select md5(session_key) from sessions", "session keys, compared by md5")):
        left = set(psql("plane-dev", sql).split())
        right = set(psql("plane-prod-sim", sql).split())
        say(f"  {label}: plane-dev {len(left)}, plane-prod-sim {len(right)}, in both {len(left & right)}")
        check(len(left) > 0 and len(right) > 0 and not left & right, f"no {label} in common")
    keys = {env: set(json.loads(run_in_api(env, SILO_KEYS, {"keys": []}).strip().splitlines()[-1])["all_keys"]) for env in ENVS}
    say(f"  silo object keys: plane-dev {len(keys['dev'])}, plane-prod-sim {len(keys['prod-sim'])}, in both {len(keys['dev'] & keys['prod-sim'])}")
    check(len(keys["dev"]) > 0 and len(keys["prod-sim"]) > 0 and not keys["dev"] & keys["prod-sim"], "no object key in common")

    say(f"\n## 5. Sessions, keys and accounts do not cross hosts. {now()}")
    instance = {env: smoke.expect(envs[env].http.get("/api/instances/", session=False), 200).json() for env in ENVS}
    ids = {env: instance[env].get("instance", instance[env]).get("instance_id") for env in ENVS}
    say(f"instance id: {HOSTS['dev']} {ids['dev']}, {HOSTS['prod-sim']} {ids['prod-sim']}")
    check(ids["dev"] != ids["prod-sim"], "the two hosts report different instance ids")
    for env, item in envs.items():
        other = envs[OTHER[env]]
        own_key = item.http.get("/api/v1/users/me/", session=False, headers=item.key()).status
        crossed_key = other.http.get("/api/v1/users/me/", session=False, headers=item.key()).status
        # Plane answers 403 to any key it does not know, so the proof is the same answer as a made-up key gets.
        made_up = other.http.get("/api/v1/users/me/", session=False, headers={"X-API-Key": "plane_api_" + secrets.token_hex(16)}).status
        say(f"{env}'s API key: on {item.host} {own_key}, on {other.host} {crossed_key}; a made-up key on {other.host} {made_up}")
        check(own_key == 200 and crossed_key in (401, 403) and crossed_key == made_up,
              f"{env}'s API key works on its own host, and {other.host} treats it as a key it has never seen")

        session = item.http.cookies.get("session-id")
        own_session = item.http.get("/api/users/me/").status
        crossed = smoke.Http(other.host, "127.0.0.1", 80)
        crossed.cookies["session-id"] = session
        crossed_session = crossed.get("/api/users/me/").status
        say(f"{env}'s session cookie: on {item.host} {own_session}, replayed on {other.host} {crossed_session}")
        check(own_session == 200 and crossed_session == 401, f"{env}'s session works on its own host and is refused on {other.host}")

        attempt = smoke.Http(other.host, "127.0.0.1", 80)
        csrf = smoke.expect(attempt.get("/auth/get-csrf-token/"), 200).json()["csrf_token"]
        response = attempt.post_form("/auth/sign-in/", {"csrfmiddlewaretoken": csrf, "email": item.accounts.get("ADMIN_EMAIL"), "password": item.accounts.get("ADMIN_PASSWORD")})
        codes = parse_qs(urlsplit(response.location).query).get("error_code", ["none"])
        say(f"{env}'s admin password, same email address, signing in on {other.host}: HTTP {response.status}, error_code {codes[0]}, session cookie {'set' if 'session-id' in attempt.cookies else 'not set'}")
        check(codes[0] != "none" and "session-id" not in attempt.cookies, f"{env}'s admin password does not sign in on {other.host}")
    same_password = envs["dev"].accounts.get("ADMIN_PASSWORD") == envs["prod-sim"].accounts.get("ADMIN_PASSWORD")
    check(not same_password, "the two generated admin passwords differ")


# ----------------------------------------------------------------------------------------------- 6

def infisical() -> None:
    say(f"\n## 6. Infisical project, identity and Kubernetes permissions. {now()}")
    for env, namespace in ENVS.items():
        statics = json.loads(must("-n", namespace, "get", "infisicalstaticsecrets", "-o", "json"))["items"]
        slugs = sorted({ref.get("projectSlug") for item in statics for ref in item["spec"].get("secretsScope", {}).get("sources", item["spec"].get("sources", []))} - {None})
        if not slugs:
            slugs = sorted(set(re.findall(r"projectSlug: (\S+)", must("-n", namespace, "get", "infisicalstaticsecrets", "-o", "yaml"))))
        ready = [(item["metadata"]["name"], next((c["status"] for c in item.get("status", {}).get("conditions", []) if c["type"].endswith("LastReconcileStatus")), "?")) for item in statics]
        say(f"{namespace}: {len(statics)} InfisicalStaticSecrets, project slugs {slugs}, status {ready}")
        check(slugs == [namespace], f"every InfisicalStaticSecret in {namespace} reads only project {namespace}")
    pairs = [("iso-dev-controller-manager", "plane-dev"), ("iso-prod-sim-controller-manager", "plane-prod-sim")]
    for account, namespace in pairs:
        other = "plane-prod-sim" if namespace == "plane-dev" else "plane-dev"
        user = f"system:serviceaccount:{namespace}:{account}"
        results = {}
        for verb, resource, target in (("get", "secrets", namespace), ("get", "secrets", other), ("create", "secrets", other),
                                       ("list", "secrets", "infisical"), ("patch", "deployments", other)):
            done = kubectl("auth", "can-i", verb, resource, "-n", target, f"--as={user}")
            results[f"{verb} {resource} in {target}"] = done.stdout.strip()
        say(f"{user}: {json.dumps(results)}")
        check(results[f"get secrets in {namespace}"] == "yes" and results[f"get secrets in {other}"] == "no" and results[f"create secrets in {other}"] == "no"
              and results["list secrets in infisical"] == "no" and results[f"patch deployments in {other}"] == "no",
              f"the {namespace} operator can read Secrets at home and do nothing in {other} or infisical")
    for namespace, other in (("plane-dev", "plane-prod-sim"), ("plane-prod-sim", "plane-dev")):
        for account in ("plane", "plane-infisical-auth", "default"):
            user = f"system:serviceaccount:{namespace}:{account}"
            results = {target: kubectl("auth", "can-i", "get", "secrets", "-n", target, f"--as={user}").stdout.strip() for target in (namespace, other)}
            say(f"{user}: get secrets {json.dumps(results)}")
            check(results[other] == "no", f"{namespace}/{account} cannot read Secrets in {other}")
    for project in ("plane-dev", "plane-prod-sim"):
        spec = json.loads(must("-n", "argocd", "get", "appproject", project, "-o", "json"))["spec"]
        say(f"AppProject {project}: destinations {json.dumps(spec.get('destinations'))}, clusterResourceWhitelist {json.dumps(spec.get('clusterResourceWhitelist'))}, "
            f"blacklist {json.dumps(spec.get('namespaceResourceBlacklist'))}")
        check([d.get("namespace") for d in spec.get("destinations", [])] == [project], f"AppProject {project} may deploy only to {project}")


# ----------------------------------------------------------------------------------------------- 7

GAP = r"""
import http.client, json, sys
results = {}
for host in ("plane.prod-sim.localhost", "plane.dev.localhost"):
    for path in ("/api/instances/", "/api/users/me/", "/uploads?list-type=2"):
        c = http.client.HTTPConnection("traefik.traefik.svc.cluster.local", 80, timeout=10)
        c.request("GET", path, headers={"Host": host, "Accept": "application/json"})
        r = c.getresponse()
        body = r.read()
        entry = {"status": r.status}
        if path == "/api/instances/" and r.status == 200:
            payload = json.loads(body)
            entry["instance_id"] = payload.get("instance", payload).get("instance_id")
        results[f"{host}{path}"] = entry
print(json.dumps(results))
"""


def known_gap() -> None:
    say(f"\n## 7. What is shared on purpose, and the known gap. {now()}")
    say("Shared by both environments: the one node, Traefik, CoreDNS, Argo CD, the Infisical server (separate projects), Prometheus and Loki.")
    for env, namespace in ENVS.items():
        results = json.loads(run_in_api(env, GAP).strip().splitlines()[-1])
        say(f"from {namespace}'s api pod through Traefik, which its policy allows for copy_object: {json.dumps(results)}")
        other = HOSTS[OTHER[env]]
        check(results[f"{other}/api/users/me/"]["status"] == 401 and results[f"{other}/uploads?list-type=2"]["status"] == 403,
              f"that path gives {namespace}'s api only {other}'s public surface: no session 401, bucket listing 403")
    say("So the api of one environment can reach the other's public HTTP surface, as any browser can. It cannot reach a data port. The network policy file records this as a known gap.")
    worker = must("-n", "plane-dev", "exec", "deploy/plane-worker-wl", "-c", "plane-worker", "--", "python", "-c",
                  'import socket,time\ns=socket.socket();s.settimeout(5);t=time.monotonic()\ntry:\n s.connect(("traefik.traefik.svc.cluster.local",80));print("CONNECTED")\nexcept TimeoutError:\n print("TIMEOUT",round(time.monotonic()-t,2))')
    say(f"reference, plane-dev's worker to Traefik, which has no such rule: {worker.strip()}")
    check(worker.startswith("TIMEOUT"), "plane-dev's worker cannot reach Traefik, so that path is the api's alone")


def main() -> int:
    say(f"# Separation of plane-dev and plane-prod-sim, state and data. {now()}")
    say("# command: tests/separation/state.py")
    try:
        require_environments()
        # Known before any section prints, and not only from section 3 on, so the scan's last line covers every line.
        report.add_secrets(credential_values(read_secrets()))
        envs_accounts = [smoke.Accounts(ACCOUNTS, env) for env in ENVS]
        report.add_secrets(v for accounts in envs_accounts for v in (accounts.get("ADMIN_PASSWORD"), accounts.get("API_TOKEN")))
        identity()
        connected()
        credentials()
        data()
        infisical()
        known_gap()
    except (Blocked, smoke.StepFailed, smoke.StepBlocked, OSError) as exc:
        report.block(f"{type(exc).__name__}: {exc}")
    return report.finish()


if __name__ == "__main__":
    sys.exit(main())
