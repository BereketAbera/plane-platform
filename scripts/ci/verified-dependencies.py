#!/usr/bin/env python3
"""Verify the pinned GitHub release dependencies used by protected Linux CI."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

# Artifact IDs refer to releases in the listed upstream repositories. PGP pins are the
# full fingerprints of the Terraform Registry's publisher keys for these versions.
PROVIDERS = {
    "infisical": ("Infisical/terraform-provider-infisical", "0.20.10", "D05AF39342416209B3629E502513406FB39E8BB6",
                 707315144, 707315197, 707315198, "infisical/terraform"),
    "vercel": ("vercel/terraform-provider-vercel", "5.26.1", "1ADC8CB01C6E6C19532E6EEC6545E9CB7A48C1FA",
               718403993, 718404023, 718404029, "infrastructure/terraform/environments/prod-host"),
    "contabo": ("contabo/terraform-provider-contabo", "0.1.44", "F866F98049C19399BC43F227DF6E61C58DA6E43B",
                479050127, 479050151, 479050154, "infrastructure/terraform/environments/prod-host"),
}
CHARTS = {
    "alloy": ("grafana/helm-charts", "1.15.0", "alloy-1.15.0", 690025641,
              "https://grafana.github.io/helm-charts",
              "2ecc96c05004cc01a45ab23cb390194ad5259ec9d02b42bf148d4468d013aaa3"),
    "loki": ("grafana-community/helm-charts", "20.4.1", "loki-20.4.1", 707532824,
             "https://grafana-community.github.io/helm-charts",
             "fcdc5fb4f1eba9355ce7c848129e40618bec4c9d8db241fafe0581e4e878744b"),
    "argo-cd": ("argoproj/argo-helm", "10.11.7", "argo-cd-10.11.7", 705944956,
                "https://argoproj.github.io/argo-helm",
                "9f24a574ead97a1a68af447ab2678073c5e16a98ff9385aee766daf74361f04e"),
    "kube-prometheus-stack": ("prometheus-community/helm-charts", "92.18.0", "kube-prometheus-stack-92.18.0", 709492850,
                             "https://prometheus-community.github.io/helm-charts",
                             "58d901b4a4e914d17e656d7da4d03ed38220a1d724b9e5e86018e032d2fbb4bb"),
    "metrics-server": ("kubernetes-sigs/metrics-server", "3.14.0", "metrics-server-helm-chart-3.14.0", 520765863,
                      "https://kubernetes-sigs.github.io/metrics-server",
                      "c2ca1185c01e6e7f53dd1b7d131f0c9b3fa50e003ed068b784563a1b5a3422a1"),
}
ALLOWED = {"api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com",
           "github-releases.githubusercontent.com", "prometheus-community.github.io", "kubernetes-sigs.github.io",
           "registry.terraform.io", "grafana-community.github.io", "argoproj.github.io", "grafana.github.io"}


def trusted_url(url):
    u = urlsplit(url)
    if u.scheme != "https" or u.hostname not in ALLOWED or u.username or u.password or u.port not in (None, 443):
        raise ValueError("dependency source is not an approved HTTPS host")


class RestrictedRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        trusted_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch(url, limit, accept):
    trusted_url(url)
    # These upstream releases are public. No API tokens are used on any host or redirect.
    request = Request(url, headers={"Accept": accept, "User-Agent": "platform-dependency-check"})
    try:
        with build_opener(RestrictedRedirect).open(request, timeout=25) as response:
            data = response.read(limit + 1)
    except HTTPError as error:
        raise RuntimeError(f"upstream HTTP {error.code}") from None
    except (TimeoutError, URLError) as error:
        raise RuntimeError(f"upstream connection failed ({type(error).__name__})") from None
    if len(data) > limit:
        raise ValueError("dependency exceeds download size bound")
    return data


def release_asset(repo, tag, ident, name, limit):
    failures = []
    for url in (f"https://api.github.com/repos/{repo}/releases/assets/{ident}?download=1",
                f"https://github.com/{repo}/releases/download/{tag}/{name}"):
        try:
            return fetch(url, limit, "application/octet-stream")
        except RuntimeError as error:
            failures.append(str(error))
    raise RuntimeError(f"{name} unavailable via both official routes: {', '.join(failures)}")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def verify_digest(data, expected, what):
    if not re.fullmatch(r"[0-9a-f]{64}", expected) or sha(data) != expected:
        raise ValueError(f"{what} SHA-256 mismatch")


def version_block(lock, name, version):
    block = re.search(r'(?ms)^provider "registry\.terraform\.io/' + re.escape(f"{name}/{name}") +
                      r'"\s*\{([^}]+)\}', lock)
    if block and re.search(r'(?m)^\s*version\s*=\s*"' + re.escape(version) + r'"\s*$', block[1]):
        return block[1]
    return None


def verify_lock(lock, name, version, digest):
    block = version_block(lock, name, version)
    if block is None or f'"zh:{digest}"' not in block:
        raise ValueError(f"{name} Linux package absent from the committed version lock")


def checked_input(path, loader, validator):
    if path.is_symlink():
        raise ValueError(f"unexpected symlink in dependency cache: {path.name}")
    if path.is_file():
        data = path.read_bytes()
        validator(data)  # Reject corrupt restores instead of executing or repairing them silently.
        return data
    data = loader()
    validator(data)
    atomic(path, data)
    return data


def atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as out:
        tmp = Path(out.name)
        try:
            out.write(data)
            out.close()
            tmp.replace(path)
        finally:
            tmp.unlink(missing_ok=True)


def signed_sum(work, registry, fingerprint, checksums, signature, zipname):
    keys = registry["signing_keys"]["gpg_public_keys"]
    key = next((k for k in keys if k["key_id"].upper() == fingerprint[-16:]), None)
    if not key:
        raise ValueError("Terraform Registry does not list the pinned publisher key")
    # gpgv accepts a binary OpenPGP keyring. Decode the Registry's public ASCII armor only.
    armor = re.fullmatch(r"(?s)\s*-----BEGIN PGP PUBLIC KEY BLOCK-----\s*\n(.*?)-----END PGP PUBLIC KEY BLOCK-----\s*", key["ascii_armor"])
    if not armor:
        raise ValueError("invalid publisher key armor")
    lines = [line.strip() for line in armor[1].splitlines() if line.strip() and ":" not in line and not line.startswith("=")]
    keyring = work / "publisher.gpg"
    keyring.write_bytes(base64.b64decode("".join(lines), validate=True))
    sums, sig = work / "SHA256SUMS", work / "SHA256SUMS.sig"
    sums.write_bytes(checksums)
    sig.write_bytes(signature)
    status = subprocess.run(["gpgv", "--homedir", str(work), "--keyring", str(keyring),
                             "--status-fd", "1", str(sig), str(sums)],
                            capture_output=True, text=True, timeout=15)
    signatures = [s.split() for s in status.stdout.splitlines() if s.startswith("[GNUPG:] VALIDSIG ")]
    if status.returncode or not any(row[-1] == fingerprint or row[2] == fingerprint for row in signatures):
        raise ValueError("provider SHA256SUMS signature not valid for its pinned publisher")
    entries = re.findall(r"(?m)^([a-f0-9]{64}) [ *]" + re.escape(zipname) + r"\s*$", checksums.decode("ascii"))
    if len(entries) != 1 or entries[0] != registry["shasum"]:
        raise ValueError("signed Linux package hash does not match the Terraform Registry")
    return entries[0]


def provider(root, cache, mirror, name):
    repo, version, fingerprint, zipid, sumid, sigid, lockroot = PROVIDERS[name]
    lockfile = root / lockroot / ".terraform.lock.hcl"
    if not lockfile.is_file() or not version_block(lockfile.read_text(), name, version):
        return False  # Changed or removed pins keep using Terraform's normal direct installation.
    # Terraform chooses installation methods by address, not by version. If two roots require
    # different versions of this address, keep direct installation available for both roots.
    declaration = f'provider "registry.terraform.io/{name}/{name}"'
    for directory in (root / "infrastructure/terraform", root / "infisical"):
        for other in directory.rglob(".terraform.lock.hcl"):
            if other == lockfile or ".terraform" in other.parts:
                continue
            contents = other.read_text()
            if declaration in contents and not version_block(contents, name, version):
                return False
    prefix, tag = f"terraform-provider-{name}_{version}", f"v{version}"
    zipname = prefix + "_linux_amd64.zip"
    registry = json.loads(fetch(f"https://registry.terraform.io/v1/providers/{name}/{name}/{version}/download/linux/amd64",
                                100_000, "application/json"))
    expected = f"https://github.com/{repo}/releases/download/{tag}/"
    sumsname = prefix + "_SHA256SUMS"
    for field, suffix in [("download_url", zipname), ("shasums_url", sumsname), ("shasums_signature_url", sumsname+".sig")]:
        if registry[field] != expected + suffix:
            raise ValueError(f"{name} registry coordinates differ from the pinned release")
    with tempfile.TemporaryDirectory() as tmpdir:
        digest = signed_sum(Path(tmpdir), registry, fingerprint,
                            release_asset(repo, tag, sumid, sumsname, 100_000),
                            release_asset(repo, tag, sigid, sumsname + ".sig", 10_000), zipname)
    verify_lock(lockfile.read_text(), name, version, digest)
    data = checked_input(cache / "packages" / zipname,
                         lambda: release_asset(repo, tag, zipid, zipname, 32_000_000),
                         lambda blob: verify_digest(blob, digest, zipname))
    atomic(mirror / "registry.terraform.io" / name / name / zipname, data)
    print(f"verified signed, locked {name}/{name} {version} linux_amd64 {digest}")
    return True


def wanted_chart(root, name, version, repo):
    # Only the checked-in Argo source tuple selects the optimization. Changed or
    # differently formatted sources continue using regular Helm resolution.
    if name == "argo-cd":
        # Local and hosted bootstraps install this chart from the same Terraform resource.
        module = root / "infrastructure/terraform/modules/argocd/main.tf"
        if not module.is_file():
            return False
        release = re.search(r'(?ms)^resource "helm_release" "argocd" \{(.*?)^\}', module.read_text())
        if not release:
            return False
        return all(re.search(r'(?m)^\s*' + field + r'\s*=\s*"' + re.escape(value) + r'"\s*$', release[1])
                   for field, value in [("repository", repo), ("chart", name), ("version", version)])
    sources = [root / "gitops" / "applications" / f"{name}.yaml"]
    sources.extend((root / "gitops" / "clusters").glob(f"*/applications/{name}.yaml"))
    for path in sources:
        if not path.is_file():
            continue
        for source in re.findall(r"(?m)^    - repoURL: ([^\n]+)\n((?:      [^\n]*\n)*)", path.read_text()):
            source_repo, fields = source
            if source_repo.strip().strip("'\"").rstrip("/") != repo:
                continue
            def value(key):
                match = re.search(r"(?m)^      " + key + r":\s*([^\s#]+)", fields)
                return match[1].strip("'\"") if match else None
            if value("chart") == name and value("targetRevision") == version:
                return True
    return False


def chart(root, cache, usable, name):
    repo, version, tag, ident, charts, digest = CHARTS[name]
    if not wanted_chart(root, name, version, charts):
        return
    filename = f"{name}-{version}.tgz"
    url = f"https://github.com/{repo}/releases/download/{tag}/{filename}"
    index = fetch(charts + "/index.yaml", 40_000_000, "application/yaml").decode()
    block = re.search(r"(?ms)^  " + re.escape(name) + r":\n(.*?)(?=^  [\w.-]+:\s*$|\Z)", index)
    entries = re.split(r"(?m)^  - ", block[1]) if block else []
    if not any(re.search(r'(?m)^    version:\s*["\']?' + re.escape(version) + r'["\']?\s*$', e) and
               re.search(r"(?m)^    digest:\s*" + digest + r"\s*$", e) and url in e for e in entries):
        raise ValueError(f"{filename} does not match the publisher's Helm index")
    data = checked_input(cache / "charts" / filename, lambda: release_asset(repo, tag, ident, filename, 12_000_000),
                         lambda blob: verify_digest(blob, digest, filename))
    atomic(usable / filename, data)
    print(f"verified indexed {filename} {digest}")
    return f"{charts}\t{name}\t{version}\t{filename}\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--scope", required=True, choices=["providers", "charts"])
    ap.add_argument("--root", type=Path, default=Path.cwd())
    ap.add_argument("--cache", required=True, type=Path)
    args = ap.parse_args()
    root = args.root.resolve()
    candidate = root / args.cache
    if any(path.is_symlink() for path in (candidate, candidate / "packages", candidate / "charts")):
        raise ValueError("dependency cache directory must not be a symlink")
    cache = candidate.resolve()
    cache.mkdir(parents=True, exist_ok=True)
    if args.scope == "charts":
        # Only archives verified in this invocation are visible to Helm. Restored bytes are untrusted input.
        usable = Path(tempfile.mkdtemp(prefix="helm-verified-", dir=os.environ.get("RUNNER_TEMP")))
        resolved = [chart(root, cache, usable, name) for name in CHARTS]
        atomic(usable / "sources.tsv", "".join(item for item in resolved if item).encode())
        atomic(cache / "helm-charts-dir", (str(usable) + "\n").encode())
        return
    # A newly built mirror cannot select unexpected files from a restored cache. Keep
    # its executable provider packages out of the shared cache; retain only verified ZIPs there.
    mirror = Path(tempfile.mkdtemp(prefix="terraform-verified-", dir=os.environ.get("RUNNER_TEMP")))
    addresses = []
    for name in PROVIDERS:
        if provider(root, cache, mirror, name):
            addresses.append(f"registry.terraform.io/{name}/{name}")
    config = "provider_installation {\n  filesystem_mirror {\n    path = " + json.dumps(str(mirror)) + "\n    include = " + json.dumps(addresses) + "\n  }\n  direct {\n    exclude = " + json.dumps(addresses) + "\n  }\n}\n"
    if not addresses:
        config = "provider_installation {\n  direct {}\n}\n"
    atomic(cache / "terraform.tfrc", config.encode())


if __name__ == "__main__":
    main()
