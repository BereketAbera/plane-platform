#!/usr/bin/env python3
"""Regenerate tools.lock from upstream release metadata.

Maintainer tool: run it when bumping a version in TOOLS below. Hashes come from
each project's own release metadata (GitHub asset digests, HashiCorp SHA256SUMS,
dl.k8s.io and get.helm.sh checksum files). install-tools.sh enforces them.
"""
import json, subprocess, sys, urllib.request

PLATFORMS = ["darwin_arm64", "linux_amd64", "linux_arm64"]

def http(url):
    with urllib.request.urlopen(url, timeout=60) as r:
        return r.read().decode()

def gh_digests(repo, tag):
    out = subprocess.check_output(["gh", "api", f"repos/{repo}/releases/tags/{tag}"], text=True)
    return {a["name"]: (a["browser_download_url"], (a.get("digest") or "").removeprefix("sha256:"))
            for a in json.loads(out)["assets"]}

GH = {
    "kind": ("kubernetes-sigs/kind", "v0.33.0", {"darwin_arm64": "kind-darwin-arm64", "linux_amd64": "kind-linux-amd64", "linux_arm64": "kind-linux-arm64"}, "kind"),
    "kustomize": ("kubernetes-sigs/kustomize", "kustomize/v5.8.3", {"darwin_arm64": "kustomize_v5.8.3_darwin_arm64.tar.gz", "linux_amd64": "kustomize_v5.8.3_linux_amd64.tar.gz", "linux_arm64": "kustomize_v5.8.3_linux_arm64.tar.gz"}, "kustomize"),
    "yq": ("mikefarah/yq", "v4.53.2", {"darwin_arm64": "yq_darwin_arm64", "linux_amd64": "yq_linux_amd64", "linux_arm64": "yq_linux_arm64"}, "yq"),
    "kubeconform": ("yannh/kubeconform", "v0.8.0", {"darwin_arm64": "kubeconform-darwin-arm64.tar.gz", "linux_amd64": "kubeconform-linux-amd64.tar.gz", "linux_arm64": "kubeconform-linux-arm64.tar.gz"}, "kubeconform"),
    "conftest": ("open-policy-agent/conftest", "v0.71.1", {"darwin_arm64": "conftest_0.71.1_Darwin_arm64.tar.gz", "linux_amd64": "conftest_0.71.1_Linux_x86_64.tar.gz", "linux_arm64": "conftest_0.71.1_Linux_arm64.tar.gz"}, "conftest"),
    "trivy": ("aquasecurity/trivy", "v0.76.1", {"darwin_arm64": "trivy_0.76.1_macOS-ARM64.tar.gz", "linux_amd64": "trivy_0.76.1_Linux-64bit.tar.gz", "linux_arm64": "trivy_0.76.1_Linux-ARM64.tar.gz"}, "trivy"),
    "hadolint": ("hadolint/hadolint", "v2.15.1", {"darwin_arm64": "hadolint-macos-arm64", "linux_amd64": "hadolint-linux-x86_64", "linux_arm64": "hadolint-linux-arm64"}, "hadolint"),
    "actionlint": ("rhysd/actionlint", "v1.7.12", {"darwin_arm64": "actionlint_1.7.12_darwin_arm64.tar.gz", "linux_amd64": "actionlint_1.7.12_linux_amd64.tar.gz", "linux_arm64": "actionlint_1.7.12_linux_arm64.tar.gz"}, "actionlint"),
    "zizmor": ("zizmorcore/zizmor", "v1.32.0", {"darwin_arm64": "zizmor-aarch64-apple-darwin.tar.gz", "linux_amd64": "zizmor-x86_64-unknown-linux-gnu.tar.gz", "linux_arm64": "zizmor-aarch64-unknown-linux-gnu.tar.gz"}, "zizmor"),
    "shellcheck": ("koalaman/shellcheck", "v0.11.0", {"darwin_arm64": "shellcheck-v0.11.0.darwin.aarch64.tar.xz", "linux_amd64": "shellcheck-v0.11.0.linux.x86_64.tar.xz", "linux_arm64": "shellcheck-v0.11.0.linux.aarch64.tar.xz"}, "shellcheck-v0.11.0/shellcheck"),
    "gitleaks": ("gitleaks/gitleaks", "v8.30.1", {"darwin_arm64": "gitleaks_8.30.1_darwin_arm64.tar.gz", "linux_amd64": "gitleaks_8.30.1_linux_x64.tar.gz", "linux_arm64": "gitleaks_8.30.1_linux_arm64.tar.gz"}, "gitleaks"),
    "tflint": ("terraform-linters/tflint", "v0.65.0", {"darwin_arm64": "tflint_darwin_arm64.zip", "linux_amd64": "tflint_linux_amd64.zip", "linux_arm64": "tflint_linux_arm64.zip"}, "tflint"),
    # Hosted production only: reads the purchased VPS from Contabo's API. Never needed for the local platform.
    "cntb": ("contabo/cntb", "v1.7", {"darwin_arm64": "cntb_v1.7_darwin_arm64.tar.gz", "linux_amd64": "cntb_v1.7_linux_amd64.tar.gz", "linux_arm64": "cntb_v1.7_linux_arm64.tar.gz"}, "cntb"),
    # Hosted production only: seals the recovery bundle. One archive holds both binaries.
    "age": ("FiloSottile/age", "v1.3.2", {"darwin_arm64": "age-v1.3.2-darwin-arm64.tar.gz", "linux_amd64": "age-v1.3.2-linux-amd64.tar.gz", "linux_arm64": "age-v1.3.2-linux-arm64.tar.gz"}, "age/age"),
    "age-keygen": ("FiloSottile/age", "v1.3.2", {"darwin_arm64": "age-v1.3.2-darwin-arm64.tar.gz", "linux_amd64": "age-v1.3.2-linux-amd64.tar.gz", "linux_arm64": "age-v1.3.2-linux-arm64.tar.gz"}, "age/age-keygen"),
    "k6": ("grafana/k6", "v2.3.0", {"darwin_arm64": "k6-v2.3.0-macos-arm64.zip", "linux_amd64": "k6-v2.3.0-linux-amd64.tar.gz", "linux_arm64": "k6-v2.3.0-linux-arm64.tar.gz"}, "k6"),
    # Ships only inside the Prometheus tarball, about 110 MB. Keep the version the same as the
    # Prometheus image in helm/values/kube-prometheus-stack.yaml, so it reads rules as that does.
    "promtool": ("prometheus/prometheus", "v3.15.1", {"darwin_arm64": "prometheus-3.15.1.darwin-arm64.tar.gz", "linux_amd64": "prometheus-3.15.1.linux-amd64.tar.gz", "linux_arm64": "prometheus-3.15.1.linux-arm64.tar.gz"}, "promtool"),
}

rows = []
for name, (repo, tag, assets, member) in GH.items():
    digests = gh_digests(repo, tag)
    version = tag.split("/")[-1]
    for plat in PLATFORMS:
        asset = assets[plat]
        if asset not in digests:
            sys.exit(f"{name}: asset {asset} not in {repo}@{tag}")
        url, sha = digests[asset]
        if not sha:
            sys.exit(f"{name}: no digest published for {asset}")
        # Archive members can sit under a platform-specific directory; resolved at install time.
        rows.append((name, version, plat, url, sha, member))

# kubectl: dl.k8s.io publishes a checksum per binary
KUBECTL = "v1.36.6"
for plat in PLATFORMS:
    os_, arch = plat.split("_")
    url = f"https://dl.k8s.io/release/{KUBECTL}/bin/{os_}/{arch}/kubectl"
    rows.append(("kubectl", KUBECTL, plat, url, http(url + ".sha256").strip().split()[0], "kubectl"))

# helm: get.helm.sh
HELM = "v4.3.1"
for plat in PLATFORMS:
    os_, arch = plat.split("_")
    url = f"https://get.helm.sh/helm-{HELM}-{os_}-{arch}.tar.gz"
    rows.append(("helm", HELM, plat, url, http(url + ".sha256sum").strip().split()[0], f"{os_}-{arch}/helm"))

# terraform: HashiCorp SHA256SUMS
TF = "1.17.1"
sums = dict(reversed(l.split()) for l in http(f"https://releases.hashicorp.com/terraform/{TF}/terraform_{TF}_SHA256SUMS").splitlines())
for plat in PLATFORMS:
    zipname = f"terraform_{TF}_{plat}.zip"
    rows.append(("terraform", TF, plat, f"https://releases.hashicorp.com/terraform/{TF}/{zipname}", sums[zipname], "terraform"))

rows.sort()
with open("tools.lock", "w") as f:
    f.write("# Pinned CLI tools. Generated by scripts/tools/update-lock.py. Do not edit by hand.\n")
    f.write("# name\tversion\tplatform\turl\tsha256\tarchive-member\n")
    for r in rows:
        f.write("\t".join(r) + "\n")
print(f"wrote tools.lock with {len(rows)} entries for {len(set(r[0] for r in rows))} tools")
