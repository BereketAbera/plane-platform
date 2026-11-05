#!/usr/bin/env python3
"""What a plane-backup Job leaves on the host, from the same YAML, for tests/drills/clean-restore-harness.sh. Fake dumps,
with the real manifest's shape. It runs the lines it finds in that YAML between their markers, as written, on these real
folders: the retention, the comparison of uploaded rows and objects, and what the manifest records of that."""
import hashlib, json, os, re, subprocess, sys

doc = sys.argv[1]
S = os.environ["H_STATE"]
ROOT = os.environ["H_ROOT"]


def jload(name, default):
    try:
        with open(f"{S}/{name}") as f:
            return json.load(f)
    except FileNotFoundError:
        return default


bid = re.search(r'name: BACKUP_ID, value: "([^"]+)"', doc).group(1)
env = re.search(r'name: ENV_NAME, value: "([^"]+)"', doc).group(1)
root = f"{ROOT}/.local/backups/{env}"
d = f"{root}/{bid}"
os.makedirs(f"{d}/postgres")
os.makedirs(f"{d}/objects", exist_ok=True)


def w(p, c):
    with open(f"{d}/{p}", "w") as f:
        f.write(c)


fp = lambda s: hashlib.sha256(s.encode()).hexdigest()[:16]
if env == "infisical":
    w("postgres/infisical.dump", "fake dump")
    w("postgres/rowcounts.tsv", "projects\t6\nsecrets_v2\t18\nusers\t1\n")
    with open(f"{ROOT}/.local/secret-zero/ENCRYPTION_KEY") as f:
        ek = f.read()
    m = {"schema": 1, "kind": "infisical", "env": "infisical", "id": bid, "created_at": "x", "pg_image": "p", "server_image": re.search(r'SERVER_IMAGE, value: "([^"]+)"', doc).group(1), "encryption_key_fp": fp(ek), "files": []}
    # What the database holds at this moment, so a later restore serves exactly this.
    with open(f"{d}/fake-api-dump.json", "w") as f:
        json.dump(jload("api.json", {}), f)
else:
    api = jload("api.json", {})
    project = api["project_ids"][env]
    secret_key = api["projects"][project]["SECRET_KEY"]["value"]
    counts = jload("plane-counts.json", {"users": 23, "workspaces": 16, "projects": 31, "issues": 132, "file_assets": 34})
    w("postgres/plane.dump", "fake dump")
    w("postgres/rowcounts.tsv", "".join(f"{k}\t{v}\n" for k, v in sorted(counts.items())))
    w("objects.lsjson", json.dumps([{"Path": "a/b.txt", "IsDir": False, "MimeType": "text/plain"}]))
    os.makedirs(f"{d}/objects/a", exist_ok=True)
    w("objects/a/b.txt", "hello")
    s = re.search(r'S_SLUG, value: "([^"]*)"', doc).group(1)
    sentinel = None
    if s:
        sentinel = {"environment": env, "slug": s, "project_id": "p", "work_item_id": "w", "name": "n", "asset_id": "a", "sha256": "h"}
    m = {"schema": 1, "kind": "plane", "env": env, "id": bid, "created_at": "x", "plane_version": "1.4.3", "backend_image": "b", "pg_image": "p", "secret_key_fp": fp(secret_key), "objects": {"count": 1, "bytes": 5}, "encrypted_sentinel": "ok", "sentinel": sentinel, "files": []}
    # The scratch restore's list of rows marked uploaded. A scenario can add one that has no object.
    if "uploaded-keys.txt" in doc:
        try:
            with open(f"{S}/uploaded-keys") as f:
                keys = f.read().splitlines()
        except FileNotFoundError:
            keys = ["a/b.txt"]
        w("postgres/uploaded-keys.txt", "".join(k + "\n" for k in sorted(keys)))
    gate = re.search(r"# GATE2 begin.*?\n(.*?)\n\s*# GATE2 end", doc, re.S)
    if gate:
        path = f"{os.environ['H_STUBS']}:{os.environ['PATH']}"
        subprocess.run(["/bin/sh", "-c", "set -eu\n" + gate.group(1)], check=True, stdout=subprocess.DEVNULL, env={**os.environ, "D": d, "PATH": path})
    uploaded = re.search(r"# UPLOADED begin\n(.*?)\n\s*# UPLOADED end", doc, re.S)
    if uploaded and '"uploaded_objects": $UPLOADED' in doc:
        out = subprocess.run(["/bin/sh", "-c", "set -eu\n" + uploaded.group(1) + '\nprintf "%s" "$UPLOADED"'], check=True, cwd=d, capture_output=True, text=True).stdout
        m["uploaded_objects"] = json.loads(out)
w("manifest.json", json.dumps(m))
out = []
for dirpath, _, files in os.walk(d):
    for f in files:
        p = os.path.join(dirpath, f)
        rel = "./" + os.path.relpath(p, d)
        if rel == "./fake-api-dump.json":
            continue
        with open(p, "rb") as fh:
            out.append(f"{hashlib.sha256(fh.read()).hexdigest()}  {rel}\n")
w("SHA256SUMS", "".join(out))

# The Job's own retention lines, on these folders, if the Job has any. Older code has no markers.
lines = re.search(r"# RETENTION begin\n(.*?)\n\s*# RETENTION end", doc, re.S) or re.search(r"(ls -1 \| grep -E .*?\n\s*done)\n", doc, re.S)
if lines:
    keep = re.search(r'name: KEEP, value: "([^"]+)"', doc).group(1)
    script = lines.group(1).replace("/backups/", root + "/")
    subprocess.run(["/bin/sh", "-c", f"set -eu\ncd '{root}'\n{script}"], check=True, stdout=subprocess.DEVNULL, env={**os.environ, "KEEP": keep})
