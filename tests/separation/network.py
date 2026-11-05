#!/usr/bin/env python3
"""Real connection attempts between plane-dev and plane-prod-sim, from real running pods.

Reads pods, Services and pod IPs from the cluster. The only values that leave a pod are verdicts, timings, addresses
and an error class. Every line printed is also scanned for the environments' Secret values.

For each direction:
  1. Every source pod that has a shell or an interpreter dials the other environment's postgres, valkey, rabbitmq (AMQP
     and management) and silo (S3 and console), by Service name and by pod IP.
  2. In the same batch, the same pod dials DNS over TCP, the one thing allow-dns opens to every pod. Six of the ten sources
     have no rule to any data port, so this is what they can all be asked. If it does not connect, that pod's timeouts
     read BLOCKED, so a dead network stack or a broken probe cannot pass as isolation.
  3. At the same time, a pod in the target environment dials the same targets, so a target that is down cannot pass as
     isolation. Except rabbitmq-mgmt and silo-console: policy blocks those two ports from that pod as well, so its reading
     is TIMEOUT whether they are up or not, and nothing in this script shows they are up. That is 4 of the 12 targets each
     source dials, and 80 of the 240 rows across. The other four ports have that proof.
  4. Then api, worker and beat dial their own environment's data tier, which their policy allows on four of those ports.
  5. The real clients the app uses (psycopg, redis-py, amqp, boto3), with the source environment's own credentials,
     dial their own and the other environment's servers.

A deny counts only as a TIMEOUT: refused means the packet arrived. A failed exec, a target or a client that printed no
result, and a failed DNS lookup say nothing either way, so each reads BLOCKED. Exit status: 0 everything passed, 1 something
failed, 2 nothing failed but something could not run.
"""
from __future__ import annotations

import concurrent.futures
import json
import re
import sys

from common import ENVS, Blocked, Report, attempts_printed, credential_values, kubectl, now, read_secrets, require_environments

TIMEOUT = 5
TARGETS = [("postgres", "plane-pgdb", 5432), ("valkey", "plane-redis", 6379), ("rabbitmq-amqp", "plane-rabbitmq", 5672),
           ("rabbitmq-mgmt", "plane-rabbitmq", 15672), ("silo-s3", "plane-minio", 9000), ("silo-console", "plane-minio", 9090)]
POD_OF_SERVICE = {"plane-pgdb": "plane-pgdb-wl-0", "plane-redis": "plane-redis-wl-0", "plane-rabbitmq": "plane-rabbitmq-wl-0",
                  "plane-minio": "plane-minio-wl-0"}
# What every source pod can be asked to reach, in each source's own batch: policy allow-dns, UDP and TCP, in both namespaces.
POSITIVE_CONTROL = {"name": "dns-tcp", "host": "kube-dns.kube-system.svc.cluster.local", "port": 53, "via": "service-dns"}
# Ports the app tier may use in its own environment, per the app-tier-to-data policy.
OWN_ALLOWED = {"postgres", "valkey", "rabbitmq-amqp", "silo-s3"}
SOURCES = [("plane-api-wl", "plane-api", "python"), ("plane-worker-wl", "plane-worker", "python"),
           ("plane-beat-worker-wl", "plane-beat-worker", "python"), ("plane-live-wl", "plane-live", "node"),
           ("plane-space-wl", "plane-space", "node"), ("plane-web-wl", "plane-web", "shell"), ("plane-admin-wl", "plane-admin", "shell"),
           ("plane-pgdb-wl-0", "plane-pgdb", "shell"), ("plane-redis-wl-0", "plane-redis", "shell"), ("plane-rabbitmq-wl-0", "plane-rabbitmq", "shell")]
HEADER = "utc\tdirection\tsource\tsource_ip\thostNetwork\ttarget\thost\tip\tport\tvia\tverdict\tseconds"

PY_PROBE = r"""
import concurrent.futures, json, socket, sys, time
targets = json.load(sys.stdin)
def one(t):
    started = time.monotonic()
    try:
        ip = socket.getaddrinfo(t["host"], t["port"], socket.AF_INET, socket.SOCK_STREAM)[0][4][0]
    except OSError as e:
        return {**t, "ip": None, "verdict": "DNS-FAILED", "seconds": round(time.monotonic() - started, 2), "detail": type(e).__name__}
    s = socket.socket()
    s.settimeout(%(timeout)d)
    started = time.monotonic()
    try:
        s.connect((ip, t["port"]))
        verdict = "CONNECTED"
    except TimeoutError:
        verdict = "TIMEOUT"
    except ConnectionRefusedError:
        verdict = "REFUSED"
    except OSError as e:
        verdict = "ERROR:" + type(e).__name__
    finally:
        s.close()
    return {**t, "ip": ip, "verdict": verdict, "seconds": round(time.monotonic() - started, 2)}
with concurrent.futures.ThreadPoolExecutor(32) as pool:
    print(json.dumps(list(pool.map(one, targets))))
""" % {"timeout": TIMEOUT}

NODE_PROBE = r"""
const net = require("net"), dns = require("dns");
let raw = ""; process.stdin.on("data", d => raw += d); process.stdin.on("end", async () => {
  const targets = JSON.parse(raw);
  const one = t => new Promise(resolve => {
    dns.lookup(t.host, { family: 4 }, (err, ip) => {
      if (err) return resolve({ ...t, ip: null, verdict: "DNS-FAILED", seconds: 0 });
      const started = Date.now();
      const s = net.connect({ host: ip, port: t.port });
      const done = v => { s.destroy(); resolve({ ...t, ip, verdict: v, seconds: (Date.now() - started) / 1000 }); };
      s.setTimeout(%(ms)d, () => done("TIMEOUT"));
      s.on("connect", () => done("CONNECTED"));
      s.on("error", e => done(e.code === "ECONNREFUSED" ? "REFUSED" : "ERROR:" + e.code));
    });
  });
  console.log(JSON.stringify(await Promise.all(targets.map(one))));
});
""" % {"ms": TIMEOUT * 1000}

# busybox nc. -w bounds the connect, and the elapsed time and message separate timeout from refused.
SH_PROBE = r"""
tmp=$(mktemp -d) || exit 125
i=0
while read -r name host port via; do
  [ -n "$name" ] || continue
  i=$((i+1))
  (
    started=$(date +%%s)
    if out=$(nc -w %(timeout)d "$host" "$port" </dev/null 2>&1); then rc=0; else rc=$?; fi
    ended=$(date +%%s)
    printf '%%s %%s %%s %%s %%s %%s %%s\n' "$name" "$host" "$port" "$via" "$rc" "$((ended-started))" "$(printf '%%s' "$out" | tr ' \n' '__' | cut -c1-80)" >"$tmp/$i"
  ) &
done
wait
cat "$tmp"/*
status=$?
rm -rf "$tmp"
exit $status
""" % {"timeout": TIMEOUT}

# The clients the app itself uses, with this pod's own credentials from its environment. argv[1] is the target namespace.
REAL_CLIENTS = r"""
import json, os, sys, time, urllib.parse
ns = sys.argv[1]
host = lambda service: f"{service}.{ns}.svc.cluster.local"
def attempt(name, fn):
    started = time.monotonic()
    try:
        detail = fn()
        verdict = "CONNECTED"
    except BaseException as exc:
        verdict = type(exc).__name__
        detail = str(exc).replace("\n", " ")[:160]
    print(json.dumps({"client": name, "target_namespace": ns, "verdict": verdict, "seconds": round(time.monotonic() - started, 2), "detail": detail}))
def pg():
    import psycopg
    u = urllib.parse.urlsplit(os.environ["DATABASE_URL"])
    with psycopg.connect(host=host("plane-pgdb"), dbname=u.path.lstrip("/"), user=u.username, password=u.password, connect_timeout=%(timeout)d) as c:
        return "SELECT 1 -> %%s" %% c.execute("select 1").fetchone()[0]
def valkey():
    import redis
    return "PING -> %%s" %% redis.Redis(host=host("plane-redis"), port=6379, socket_connect_timeout=%(timeout)d, socket_timeout=%(timeout)d).ping()
def amqp_():
    import amqp
    u = urllib.parse.urlsplit(os.environ["AMQP_URL"])
    c = amqp.Connection(host=host("plane-rabbitmq") + ":5672", userid=urllib.parse.unquote(u.username), password=urllib.parse.unquote(u.password), connect_timeout=%(timeout)d)
    c.connect()
    server = c.server_properties.get("product")
    c.close()
    return "AMQP open, server %%s" %% server
def silo():
    import boto3
    from botocore.config import Config
    s3 = boto3.client("s3", endpoint_url=f"http://{host('plane-minio')}:9000", aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
                      aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"], region_name="us-east-1",
                      config=Config(signature_version="s3v4", connect_timeout=%(timeout)d, read_timeout=%(timeout)d, retries={"total_max_attempts": 1}))
    return "ListBuckets -> %%s" %% [b["Name"] for b in s3.list_buckets()["Buckets"]]
attempt("psycopg", pg)
attempt("redis-py", valkey)
attempt("amqp", amqp_)
attempt("boto3", silo)
""" % {"timeout": TIMEOUT}
REAL_CLIENT_NAMES = re.findall(r'^attempt\("([^"]+)"', REAL_CLIENTS, flags=re.M)

report = Report()


def running_pods(namespace: str) -> dict:
    done = kubectl("-n", namespace, "get", "pods", "-o", "json")
    if done.returncode != 0:
        raise Blocked(f"cannot list pods in {namespace}: {done.stderr.strip()[:200]}")
    return {p["metadata"]["name"]: p for p in json.loads(done.stdout)["items"]
            if p["status"]["phase"] == "Running" and p["metadata"].get("deletionTimestamp") is None}


def named(pods: dict, prefix: str) -> str:
    matches = [name for name in pods if name.startswith(prefix)]
    if not matches:
        raise Blocked(f"no running pod {prefix}")
    return matches[0]


def targets_for(namespace: str, pod_ips: dict) -> list[dict]:
    out = []
    for label, service, port in TARGETS:
        if POD_OF_SERVICE[service] not in pod_ips:
            raise Blocked(f"{POD_OF_SERVICE[service]} has no pod IP in {namespace}")
        out.append({"name": label, "host": f"{service}.{namespace}.svc.cluster.local", "port": port, "via": "service-dns"})
        out.append({"name": label, "host": pod_ips[POD_OF_SERVICE[service]], "port": port, "via": "pod-ip"})
    return out


def probe(namespace: str, pod: str, container: str, kind: str, targets: list[dict]) -> list[dict]:
    if kind == "python":
        done = kubectl("-n", namespace, "exec", "-i", pod, "-c", container, "--", "python", "-c", PY_PROBE, stdin=json.dumps(targets), timeout=90)
    elif kind == "node":
        done = kubectl("-n", namespace, "exec", "-i", pod, "-c", container, "--", "node", "-e", NODE_PROBE, stdin=json.dumps(targets), timeout=90)
    else:
        lines = "\n".join(f"{t['name']} {t['host']} {t['port']} {t['via']}" for t in targets) + "\n"
        done = kubectl("-n", namespace, "exec", "-i", pod, "-c", container, "--", "sh", "-c", SH_PROBE, stdin=lines, timeout=90)
    if done.returncode != 0:
        return [{**t, "ip": None, "verdict": f"EXEC-FAILED rc={done.returncode}", "seconds": 0, "detail": done.stderr.strip()[:120]} for t in targets]
    results = shell_results(done.stdout) if kind == "shell" else json_results(done.stdout)
    # An exec can exit 0 and return less than it was asked, and a target with no result must not just vanish from the run.
    answered = {target_key(result) for result in results}
    detail = done.stderr.strip()[:120] or "the probe exited 0 and returned nothing for this target"
    return results + [{**t, "ip": None, "verdict": "EXEC-FAILED no result", "seconds": 0, "detail": detail}
                      for t in targets if target_key(t) not in answered]


def target_key(item: dict) -> tuple:
    return item["name"], item["host"], item["port"], item["via"]


def json_results(stdout: str) -> list[dict]:
    try:
        return json.loads(stdout)
    except ValueError:
        return []


def shell_results(stdout: str) -> list[dict]:
    results = []
    for line in stdout.splitlines():
        try:
            name, host, port, via, rc, seconds, message = (line.split(" ", 6) + [""])[:7]
            port, seconds = int(port), int(seconds)
        except ValueError:
            continue
        text = message.lower()
        if rc == "0":
            verdict = "CONNECTED"
        elif "refused" in text:
            verdict = "REFUSED"
        elif "bad_address" in text:
            verdict = "DNS-FAILED"
        elif seconds >= TIMEOUT - 1:
            verdict = "TIMEOUT"
        else:
            verdict = f"ERROR:{message}"
        results.append({"name": name, "host": host, "port": port, "via": via, "verdict": verdict, "seconds": seconds, "ip": host if via == "pod-ip" else "-"})
    return results


def row(moment: str, label: str, source_ns: str, source: str, source_ip: str, host_network: bool, result: dict) -> str:
    return "\t".join(str(v) for v in (moment, label, f"{source_ns}/{source}", source_ip, f"hostNetwork={str(host_network).lower()}",
                                      result["name"], result["host"], result.get("ip", ""), result["port"], result["via"], result["verdict"], result["seconds"]))


def judge(result: dict, want: str, line: str) -> None:
    """A failed exec or lookup says nothing about the path, so it is not a result either way."""
    if result["verdict"].startswith("EXEC-FAILED") or result["verdict"] == "DNS-FAILED":
        report.block(f"{line}\t{result.get('detail', '')}")
    else:
        report.check(result["verdict"] == want, f"{line}\twant={want}")


def hang_row(done, line: str, otherwise_as_wanted: bool) -> None:
    """A deny from a client inside a data pod. seconds= is that pod's own clock, and a refused port or a name that does not
    resolve answers at once, so only the time tells either of them from a hang. No time at all means the client did not run."""
    taken = re.search(r"seconds=(\d+)", done.stdout)
    if taken is None:
        report.block(f"{line}\tit printed no time, so it says nothing either way")
    else:
        report.check(otherwise_as_wanted and int(taken.group(1)) >= TIMEOUT - 1, line)


def direction(source_env: str, target_env: str) -> None:
    source_ns, target_ns = ENVS[source_env], ENVS[target_env]
    source_pods, target_pods = running_pods(source_ns), running_pods(target_ns)
    target_ips = {name: p["status"].get("podIP") for name, p in target_pods.items()}
    source_ips = {name: p["status"].get("podIP") for name, p in source_pods.items()}
    other_targets = targets_for(target_ns, target_ips)
    own_targets = targets_for(source_ns, source_ips)
    label = f"{source_env}->{target_env}"
    report.say(f"\n## {label}: every source pod dials the other environment. A pass is a TIMEOUT and nothing else, beside each pod's own {POSITIVE_CONTROL['name']}, which must connect. {now()}")
    report.say(f"verdict {HEADER}")

    def run_source(entry):
        prefix, container, kind = entry
        pod = named(source_pods, prefix)
        moment = now()
        return pod, moment, probe(source_ns, pod, container, kind, [POSITIVE_CONTROL, *other_targets]), source_pods[pod]

    reference = named(target_pods, "plane-api-wl")
    reference_moment = now()
    with concurrent.futures.ThreadPoolExecutor(len(SOURCES) + 1) as pool:
        from_the_target_side = pool.submit(probe, target_ns, reference, "plane-api", "python", other_targets)
        batches = list(pool.map(run_source, SOURCES))
    for pod, moment, results, spec in batches:
        control = next(result for result in results if result["name"] == POSITIVE_CONTROL["name"])
        for result in results:
            line = row(moment, label, source_ns, pod, source_ips[pod], bool(spec["spec"].get("hostNetwork")), result)
            if result is control:
                judge(result, "CONNECTED", line)
            elif result["verdict"] == "TIMEOUT" and control["verdict"] != "CONNECTED":
                report.block(f"{line}\tthis pod's own positive control did not connect, so its timeout proves nothing")
            else:
                judge(result, "TIMEOUT", line)

    # Same moment: the targets answer a pod in their own environment.
    report.say(f"\n## {label}: reference, a pod inside {target_ns} dialled the same targets at the same time. {now()}")
    for result in from_the_target_side.result():
        want = "CONNECTED" if result["name"] in OWN_ALLOWED else "TIMEOUT"
        judge(result, want, row(reference_moment, f"{target_env}->{target_env}", target_ns, reference, target_ips[reference],
                                bool(target_pods[reference]["spec"].get("hostNetwork")), result))

    report.say(f"\n## {label}: reference, the source pods with a data-tier rule dial their own environment. {now()}")
    for prefix, container, kind in SOURCES[:3]:
        pod = named(source_pods, prefix)
        for result in probe(source_ns, pod, container, kind, own_targets):
            want = "CONNECTED" if result["name"] in OWN_ALLOWED else "TIMEOUT"
            judge(result, want, row(now(), f"{source_env}->{source_env}", source_ns, pod, source_ips[pod],
                                    bool(source_pods[pod]["spec"].get("hostNetwork")), result))

    report.say(f"\n## {label}: the real clients, with {source_ns}'s own credentials from the pod's environment. {now()}")
    api = named(source_pods, "plane-api-wl")
    for namespace, want_connected in ((source_ns, True), (target_ns, False), (source_ns, True)):
        done = kubectl("-n", source_ns, "exec", api, "-c", "plane-api", "--", "python", "-c", REAL_CLIENTS, namespace, timeout=120)
        if done.returncode != 0:
            report.block(f"real clients in {api} exited {done.returncode}: {done.stderr.strip()[:200]}")
            continue
        printed = attempts_printed(done.stdout, "client")
        for client in REAL_CLIENT_NAMES:
            record = printed.get(client)
            if record is None:
                report.block(f"{client} from {source_ns}/{api} to {namespace}: the exec exited 0 and printed no result for it, so it says nothing either way")
                continue
            timed_out = record["verdict"] in ("ConnectionTimeout", "ConnectTimeoutError", "TimeoutError", "timeout", "OperationalError") \
                and ("timeout" in record["detail"].lower() or "timed out" in record["detail"].lower() or record["seconds"] >= TIMEOUT - 1)
            ok = record["verdict"] == "CONNECTED" if want_connected else timed_out
            want = "a connection" if want_connected else "a timeout"
            report.check(ok, f"{record['client']} from {source_ns}/{api} to {namespace}: want {want}, " + json.dumps({"utc": now(), **record}))

    # The two binaries the data pods ship, so the attempt is a real protocol client there too.
    report.say(f"\n## {label}: psql and valkey-cli inside {source_ns}'s data pods. {now()}")
    target_pg = f"plane-pgdb.{target_ns}.svc.cluster.local"
    target_valkey = f"plane-redis.{target_ns}.svc.cluster.local"
    command = f'started=$(date +%s); pg_isready -h {target_pg} -t {TIMEOUT}; rc=$?; echo "pg_isready rc=$rc seconds=$(( $(date +%s)-started ))"'
    done = kubectl("-n", source_ns, "exec", "plane-pgdb-wl-0", "-c", "plane-pgdb", "--", "sh", "-c", command, timeout=60)
    # pg_isready gives 2 at once for a closed port and for a name that does not resolve, so the code alone is not a deny.
    hang_row(done, f"{now()} {source_ns}/plane-pgdb-wl-0 -> {target_pg}: want rc=2, no response, after a hang until the timeout: {done.stdout.strip()} {done.stderr.strip()[:100]}",
             "rc=2" in done.stdout)
    command = f'started=$(date +%s); timeout {TIMEOUT} valkey-cli -h {target_valkey} ping; rc=$?; echo "valkey-cli rc=$rc seconds=$(( $(date +%s)-started ))"'
    done = kubectl("-n", source_ns, "exec", "plane-redis-wl-0", "-c", "plane-redis", "--", "sh", "-c", command, timeout=60)
    hang_row(done, f"{now()} {source_ns}/plane-redis-wl-0 -> {target_valkey}: want a hang until the timeout: {done.stdout.strip()} {done.stderr.strip()[:100]}",
             "PONG" not in done.stdout)


def main() -> int:
    report.say(f"# Separation of plane-dev and plane-prod-sim, network. Real attempts from real pods. {now()}")
    report.say("# command: tests/separation/network.py")
    try:
        require_environments()
        report.add_secrets(credential_values(read_secrets()))
        direction("dev", "prod-sim")
        direction("prod-sim", "dev")
    except Blocked as exc:
        report.block(str(exc))
    return report.finish()


if __name__ == "__main__":
    sys.exit(main())
