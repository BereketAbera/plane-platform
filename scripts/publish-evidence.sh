#!/usr/bin/env bash
# Publish raw evidence so the docs can cite it: copy .local/evidence-raw/ to docs/evidence/runs/ under the
# same names, scrub the copies, and fail if gitleaks finds anything in the result. docs/evidence/README.md
# has the rules this follows.
#
# What it copies: every regular file up to 2 MiB that is text, and screenshots (.jpg, .jpeg, .png), which
# cannot be scrubbed, so read them before committing. It prints a line for anything it skips. A directory
# keeps its path under runs/, except scan-images-*, whose home is docs/evidence/security/. File types that
# .gitignore keeps out of Git as secrets or dumps are never copied.
#
# It never deletes a file in docs/evidence/runs/. A raw file that is gone keeps its published copy.
# Each copy is made again from its raw file, so the same input gives the same bytes and a second run
# changes nothing. MANIFEST.tsv records, per file, when the raw file was last written, because Git will
# not keep that, and how many replacements were made.
#
# The scrub replaces exact values with <redacted>, longest first, as bytes. The values come from
# .local/test-accounts.env, every file under .local/secret-zero/, and every Secret in the namespaces below,
# decoded. Under 8 characters, ordinary words, short numbers, timestamps and URLs with no credentials in
# them are not treated as secrets. It prints counts and never a value, and it never passes a value on a
# command line.
#
# Hosted production's evidence lands in the same folder, so its values count too, when this machine has any: its secret zero, the
# owner's files, and what scripts/hosted/scrub-values.sh read from its Secrets. This reaches that cluster no more than any other local
# target does, so make remote-publish-evidence is what refreshes those.
#
# Values stay in .local/evidence-scrub-values (mode 0600). Without that, a stopped cluster, a rotated
# password or a new install would put a value back into the copy the next time its raw file was published.
#
# Exit status: 0 when everything was published and gitleaks found nothing, otherwise 1. A finding leaves
# the copies in place and uncommitted, and prints each file, line and rule, not what matched.
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

guard_disk 1
cd "$ROOT"

RAW_DIR=.local/evidence-raw
RUNS_DIR=docs/evidence/runs
GITLEAKS="$ROOT/.tools/bin/gitleaks"

[[ -d "$RAW_DIR" ]] || die "$RAW_DIR does not exist, so there is nothing to publish."
[[ -x "$GITLEAKS" ]] || die "gitleaks not found. Run: make setup"
command -v python3 >/dev/null 2>&1 || die "python3 not found. Run: make setup"

log "Publishing $RAW_DIR to $RUNS_DIR"
python3 -I -B - "$LOCAL_DIR" "$RAW_DIR" "$RUNS_DIR" <<'PY' || die "publishing stopped before the gitleaks scan. Do not commit $RUNS_DIR"
import base64
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import urllib.parse
from datetime import datetime, timezone

LOCAL, RAW, RUNS = sys.argv[1:4]
NAMESPACES = ("plane-dev", "plane-prod-sim", "infisical", "monitoring", "argocd")
REMEMBERED = os.path.join(LOCAL, "evidence-scrub-values")
HOSTED = os.path.join(LOCAL, "hosted", "plane-prod")
HOSTED_REMEMBERED = os.path.join(HOSTED, "evidence-scrub-values")
HOSTED_FILES = ("restic-password", "ghcr-pull-token")
HOSTED_FILE_PREFIXES = ("alert-", "offsite-s3-")
MANIFEST = "MANIFEST.tsv"
REDACTED = b"<redacted>"
MAX_FILE = 2 * 1024 * 1024
IMAGES = (".jpg", ".jpeg", ".png")
# The same list as .gitignore. Git would ignore such a copy, so it would sit in the tree unseen.
NEVER = (".env", ".pem", ".key", ".dump", ".sql", ".sql.gz")
# A Helm release Secret decodes to half a megabyte of compressed chart, which no command prints.
MAX_VALUE = 64 * 1024
MIN_VALUE = 8

# Redacting these would hide prose, not secrets: POSTGRES_DB in the infisical namespace is the word
# infisical. Random mixed-case letters must not match, because argocd-redis has a password like that.
NOT_SECRET = re.compile(
    rb"(?:[A-Z]?[a-z]{1,16}(?:[-_. ][A-Z]?[a-z]{1,16}){0,7}"  # ordinary words: plane-prod-sim
    rb"|[0-9]{1,15}"  # a short number
    rb"|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z?"  # a timestamp: Argo CD's admin.passwordMtime
    rb"|[a-z][a-z0-9+.-]*://[^\s@?#]+"  # a URL with no credentials or query: http://plane-minio:9000
    rb")\Z"
)

# Identifiers that gitleaks reads as credentials: its generic-api-key shape (a keyword, up to 20 characters,
# then =) with a UUID as the value. These are record ids such as "SECRET_KEY id=<uuid>" and Kubernetes
# uids such as "plane-app-keys uid=<uuid>". Neither is a credential, but allowlisting the shape would
# also let a real key through in the same position.
# A session cookie k6 carried in setup_data. It is in no source the scrub reads, because the test signs in for itself.
SESSION = re.compile(rb'((?:\\?"session(?:[-_]?id)?\\?"\s*:\s*\\?")|(?:session(?:[-_]?id)?=))[A-Za-z0-9_\-]{16,}')

IDENTIFIER = re.compile(
    rb"((?:access|auth|api|credential|creds|key|passw(?:or)?d|secret|token)[ \t\w.-]{0,20}=)"
    rb"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
    re.IGNORECASE,
)
ENV_LINE = re.compile(rb"\s*(?:export\s+)?[A-Za-z_][A-Za-z0-9_]*=(.*)")


def is_secret(value):
    return MIN_VALUE <= len(value) <= MAX_VALUE and b"\0" not in value and not NOT_SECRET.match(value)


def leaves(node):
    if isinstance(node, dict):
        node = list(node.values())
    if isinstance(node, list):
        for child in node:
            yield from leaves(child)
    elif isinstance(node, str):
        yield node.encode()


def values_in_file(path):
    with open(path, "rb") as handle:
        data = handle.read()
    try:
        document = json.loads(data)
    except ValueError:
        document = None
    if isinstance(document, (dict, list)):
        yield from leaves(document)
        return
    lines = data.strip().splitlines()
    assigned = [match.group(1) for match in map(ENV_LINE.fullmatch, lines) if match]
    # A key file holds one value, and a base64 key can look like an assignment.
    if len(lines) == 1 or not assigned:
        yield data
    for value in assigned:
        yield value.strip().strip(b"'\"")


def local_values(notes):
    env_file = os.path.join(LOCAL, "test-accounts.env")
    zero_dir = os.path.join(LOCAL, "secret-zero")
    if os.path.exists(env_file):
        yield from values_in_file(env_file)
    else:
        notes.append(env_file + " does not exist, so it was not read")
    if not os.path.isdir(zero_dir):
        notes.append(zero_dir + " does not exist, so it was not read")
    for directory, _, names in os.walk(zero_dir):
        for name in names:
            yield from values_in_file(os.path.join(directory, name))


def hosted_values(notes):
    """Hosted production's, from files. None on a machine with no hosted state, so the local platform's runs do not change."""
    if not os.path.isdir(HOSTED):
        return
    for directory, _, names in os.walk(os.path.join(HOSTED, "secret-zero")):
        for name in names:
            yield from values_in_file(os.path.join(directory, name))
    for name in sorted(os.listdir(HOSTED)):
        path = os.path.join(HOSTED, name)
        if os.path.isfile(path) and (name in HOSTED_FILES or name.startswith(HOSTED_FILE_PREFIXES)):
            for value in values_in_file(path):
                yield value
                # A Healthchecks URL holds no password, and whoever has it can silence the alarm: the secret is its last part.
                if value.strip().startswith(b"https://"):
                    yield value.strip().rsplit(b"/", 1)[-1]
    try:
        with open(HOSTED_REMEMBERED, "rb") as handle:
            yield from (base64.b64decode(line) for line in handle.read().split())
    except FileNotFoundError:
        notes.append("hosted production's Secrets are not in the scrub yet. Run: make remote-publish-evidence TARGET=plane-prod")


def kubectl(*args):
    command = ["kubectl", "--context", os.environ["KUBE_CONTEXT"], "--request-timeout=15s", *args]
    return subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True, timeout=30).stdout


def cluster_values(notes):
    """Decoded Secret values, read into memory only."""
    found = []
    try:
        kubectl("get", "--raw", "/readyz")
    except (OSError, subprocess.SubprocessError):
        notes.append(
            "the cluster is not reachable, so the scan was limited to local files: test-accounts.env, "
            "secret-zero/, and the values earlier runs left in evidence-scrub-values"
        )
        return found
    unread = []
    for namespace in NAMESPACES:
        try:
            items = json.loads(kubectl("-n", namespace, "get", "secrets", "-o", "json"))["items"]
        except (OSError, ValueError, KeyError, subprocess.SubprocessError):
            unread.append(namespace)
            continue
        for item in items:
            for encoded in (item.get("data") or {}).values():
                found.append(base64.b64decode(encoded))
    if unread:
        notes.append("could not read Secrets in " + ", ".join(unread) + ", so the cluster scan was limited to the rest")
    return found


def url_password(value):
    try:
        password = urllib.parse.urlsplit(value.decode()).password
    except ValueError:  # UnicodeDecodeError is one too
        return None
    return urllib.parse.unquote(password).encode() if password else None


def remembered_values():
    try:
        with open(REMEMBERED, "rb") as handle:
            return {base64.b64decode(line) for line in handle.read().split()}
    except FileNotFoundError:
        return set()


def remember(values):
    text = b"".join(base64.b64encode(value) + b"\n" for value in sorted(values))
    try:
        with open(REMEMBERED, "rb") as handle:
            if handle.read() == text:
                return
    except FileNotFoundError:
        pass
    # mkstemp creates the file with mode 0600, and the rename keeps a crash from truncating it.
    descriptor, tmp = tempfile.mkstemp(dir=LOCAL, prefix=".evidence-scrub-values.")
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(text)
    os.replace(tmp, REMEMBERED)


def collect(notes):
    values = {value for value in remembered_values() if is_secret(value.strip())}
    for value in [*local_values(notes), *cluster_values(notes)]:
        for form in (value, url_password(value)):
            if form is not None and is_secret(form.strip()):
                values.add(form)
    # Apart from the local platform's remembered file, because these stay under .local/hosted/plane-prod.
    hosted = set()
    for value in hosted_values(notes):
        for form in (value, url_password(value)):
            if form is not None and is_secret(form.strip()):
                hosted.add(form)
    if not values and not hosted:
        sys.exit("found no values to scrub with, so a scrub would change nothing. Nothing was published.")
    remember(values)
    return values | hosted


def needles(values):
    """Every form a log can show a value in, longest first. Sorting the rest makes the order stable."""
    forms = set()
    for value in values:
        forms.add(value.strip())
        forms.add(base64.b64encode(value))
        forms.add(base64.b64encode(value.strip()))
    return sorted(forms, key=lambda form: (-len(form), form))


def scrub(data, patterns):
    count = 0
    for pattern in patterns:
        hits = data.count(pattern)
        if hits:
            data = data.replace(pattern, REDACTED)
            count += hits
    data, session_hits = SESSION.subn(lambda match: match.group(1) + REDACTED, data)
    data, hits = IDENTIFIER.subn(lambda match: match.group(1) + REDACTED, data)
    hits += session_hits
    return data, count + hits


def write(path, data):
    """Only when the bytes differ, so a second run touches nothing. Returns whether it wrote."""
    try:
        with open(path, "rb") as handle:
            if handle.read() == data:
                return False
    except FileNotFoundError:
        pass
    os.makedirs(os.path.dirname(path), exist_ok=True)
    descriptor, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".publish-")
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(data)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)
    return True


def raw_files():
    for directory, subdirs, names in os.walk(RAW):
        for subdir in sorted(subdirs):
            if directory == RAW and subdir.startswith("scan-images-"):
                print("  skipped, image scans go to docs/evidence/security/ by hand:", subdir)
                subdirs.remove(subdir)
        subdirs.sort()
        for name in sorted(names):
            yield os.path.join(directory, name)


def published_files():
    for directory, _, names in os.walk(RUNS):
        for name in sorted(names):
            if not name.startswith("."):
                yield os.path.relpath(os.path.join(directory, name), RUNS)


def read_manifest(path):
    rows = {}
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle.read().splitlines()[1:]:
                name, written, size, count = line.split("\t")
                rows[name] = (written, int(size), int(count))
    except FileNotFoundError:
        pass
    return rows


def utc(timestamp):
    return datetime.fromtimestamp(timestamp, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def publish(patterns):
    manifest_path = os.path.join(RUNS, MANIFEST)
    rows = read_manifest(manifest_path)
    done = set()
    written = same = images = scrubbed = replacements = 0

    for path in raw_files():
        name = os.path.relpath(path, RAW)
        try:
            info = os.lstat(path)
            if not stat.S_ISREG(info.st_mode):
                print("  skipped, not a regular file:", name)
                continue
            if os.path.basename(name).startswith(".") or name == MANIFEST:
                print("  skipped, reserved or hidden name:", name)
                continue
            if name.lower().endswith(NEVER):
                print("  skipped, a type that never enters Git:", name)
                continue
            if info.st_size > MAX_FILE:
                print("  skipped, over 2 MiB:", name, "(%d bytes)" % info.st_size)
                continue
            with open(path, "rb") as handle:
                data = handle.read()
        except FileNotFoundError:  # a run that is still writing can rename its temporary files
            print("  skipped, gone while reading:", name)
            continue
        count = 0
        if b"\0" not in data:
            data, count = scrub(data, patterns)
        elif name.lower().endswith(IMAGES):
            images += 1
        else:
            print("  skipped, not text:", name)
            continue
        if write(os.path.join(RUNS, name), data):
            written += 1
        else:
            same += 1
        done.add(name)
        scrubbed += 1 if count else 0
        replacements += count
        rows[name] = (utc(info.st_mtime), len(data), count)

    # A copy whose raw file is gone or skipped stays, and still loses any value learned since.
    for name in published_files():
        if name in done or name == MANIFEST:
            continue
        path = os.path.join(RUNS, name)
        with open(path, "rb") as handle:
            data = handle.read()
        count = 0
        if b"\0" not in data:
            data, count = scrub(data, patterns)
            if count:
                write(path, data)
                scrubbed += 1
                replacements += count
        before = rows.get(name, (utc(os.lstat(path).st_mtime), 0, 0))
        rows[name] = (before[0], len(data), before[2] + count)

    rows = {name: row for name, row in rows.items() if os.path.exists(os.path.join(RUNS, name))}
    lines = ["file\traw_file_last_written_utc\tbytes_published\treplacements"]
    lines += ["%s\t%s\t%d\t%d" % (name, *rows[name]) for name in sorted(rows)]
    write(manifest_path, ("\n".join(lines) + "\n").encode())

    print("  files: %d in runs/, %d new or changed, %d unchanged, %d images not scrubbed" % (len(rows), written, same, images))
    print("  scrub: %d files changed, %d replacements" % (scrubbed, replacements))


def main():
    notes = []
    values = collect(notes)
    for note in notes:
        print("  note:", note)
    publish(needles(values))


main()
PY

# With --redact the report holds the rule, file and line, and never the text that matched. No pipe here:
# this gate is the exit code of gitleaks itself.
report_dir="$(mktemp -d)"
trap 'rm -rf "$report_dir"' EXIT
if ! "$GITLEAKS" dir "$RUNS_DIR" --config .gitleaks.toml --redact --no-banner --log-level warn \
  --exit-code 1 --report-format json --report-path "$report_dir/findings.json"; then
  python3 -I -B - "$report_dir/findings.json" <<'PY' >&2 || warn "gitleaks wrote no report it could read"
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    for finding in json.load(handle):
        print("  %s:%s %s" % (finding["File"], finding["StartLine"], finding["RuleID"]))
PY
  die "gitleaks failed on $RUNS_DIR, so do not commit it. Add a value to the scrub, or a narrow rule to .gitleaks.toml if it is a real false positive."
fi
ok "gitleaks: no findings in $RUNS_DIR"
