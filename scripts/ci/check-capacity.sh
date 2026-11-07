#!/usr/bin/env bash
# Does hosted production still fit its node? Quotas cap rather than reserve, so what keeps one namespace from taking another's room is
# that their caps add up to no more than the node. This sums them from infrastructure/hosted/plane-prod/capacity.yaml, which Terraform
# also applies, with the system's share and the scratch space no quota counts, and fails if they no longer fit. It also fails if what is
# deployed no longer fits its own quota, because that shows up only on the cluster, as a rollout that stops with "exceeded quota".
#
# No cluster and no credentials. SKIP_CHARTS=yes leaves out the third-party charts, which need network, and then the workload
# totals cover only what this repository holds as plain files.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=lib-manifests.sh
source "$(dirname "$0")/lib-manifests.sh"

"$ROOT/scripts/install-tools.sh" yq kustomize helm >/dev/null
cd "$ROOT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

HOSTED=infrastructure/hosted/plane-prod
[[ -f "$HOSTED/capacity.yaml" ]] || die "$HOSTED/capacity.yaml is missing"

mkdir -p "$WORK/manifests" "$WORK/charts"
yq -o=json -I=0 . "$HOSTED/capacity.yaml" >"$WORK/capacity.json"
yq -o=json -I=0 . "$HOSTED/kubelet.conf" >"$WORK/kubelet.json"

# One JSON document to a line, whichever tool produced the YAML.
as_json() { # as_json <yaml file> <output file>
  yq -N -o=json -I=0 'select(.kind != null)' "$1" >"$2"
}

# Each folder as Argo CD reads it: what its kustomization.yaml lists, or else every plain file, in which each object names its own
# namespace. A new app's folder is counted only once it is listed here, and a file its kustomization does not list only once it does. A
# plain file is named by its folder too, because the static sites' folders hold files of the same names, and one would overwrite the other.
for directory in monitoring-extras backup infisical certificates rillmark awushi-cloudgarden frameflow; do
  if [[ -f "$HOSTED_TREE/platform/$directory/kustomization.yaml" ]]; then
    kustomize build "$HOSTED_TREE/platform/$directory" >"$WORK/$directory.yaml"
    as_json "$WORK/$directory.yaml" "$WORK/manifests/$directory.json"
  elif [[ -d "$HOSTED_TREE/platform/$directory" ]]; then
    while read -r file; do
      as_json "$file" "$WORK/manifests/$directory-$(basename "$file" .yaml).json"
    done < <(find "$HOSTED_TREE/platform/$directory" -type f -name '*.yaml' 2>/dev/null | LC_ALL=C sort)
  else
    warn "$HOSTED_TREE/platform/$directory does not exist, so nothing there is counted"
  fi
done
if [[ -f "$HOSTED_ENVIRONMENT/manifests.yaml" ]]; then
  as_json "$HOSTED_ENVIRONMENT/manifests.yaml" "$WORK/manifests/plane-prod-render.json"
else
  warn "$HOSTED_ENVIRONMENT/manifests.yaml does not exist, so Plane's own workloads are not counted"
fi

# Each rendered chart, with the namespace its Application deploys to, because a chart may leave that off its objects.
if [[ "${SKIP_CHARTS:-}" == yes ]]; then
  warn "SKIP_CHARTS=yes: the third-party charts were not rendered, so the workload totals are not complete"
else
  render_hosted_charts "$WORK/charts/rendered"
  while read -r file; do
    name="$(basename "$file" .yaml)"
    application="$HOSTED_TREE/applications/$name.yaml"
    namespace="$name"
    [[ ! -f "$application" ]] || namespace="$(yq -r '.spec.destination.namespace' "$application")"
    mkdir -p "$WORK/charts/$namespace"
    as_json "$file" "$WORK/charts/$namespace/$name.json"
  done < <(find "$WORK/charts/rendered" -type f -name '*.yaml' | LC_ALL=C sort)
  rm -rf "$WORK/charts/rendered"
fi

python3 -I - "$WORK" "infrastructure/terraform/environments/prod/main.tf" <<'PY'
import json
import pathlib
import re
import sys

work = pathlib.Path(sys.argv[1])
terraform_root = pathlib.Path(sys.argv[2])
capacity = json.loads((work / "capacity.json").read_text())
kubelet = json.loads((work / "kubelet.json").read_text())
problems = []

UNITS = {"Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "Ti": 2**40, "k": 10**3, "M": 10**6, "G": 10**9, "T": 10**12, "m": 1e-3, "": 1}


def quantity(text):
    match = re.fullmatch(r"([0-9.]+)(Ki|Mi|Gi|Ti|k|M|G|T|m|)", str(text))
    if not match:
        raise SystemExit(f"cannot read the quantity {text!r}")
    return float(match.group(1)) * UNITS[match.group(2)]


def gib(value):
    return f"{value / 2**30:.2f} GiB"


def mib(value):
    return f"{value / 2**20:.0f} MiB"


def cores(value):
    return f"{value:.2f} CPU"


def require(ok, message):
    if not ok:
        problems.append(message)


node, system = capacity["node"], capacity["system"]
quotas, limit_ranges = capacity["quotas"], capacity["limit_ranges"]
# What a namespace's emptyDirs take of the disk, which no quota here counts.
ephemeral = capacity.get("ephemeral") or {}

# ---- The numbers capacity.yaml copies from elsewhere must still be those numbers.
reserved = (kubelet["kubeReserved"], kubelet["systemReserved"])
require(
    sum(quantity(r["cpu"]) for r in reserved) == quantity(system["cpu"]),
    f"system.cpu is {system['cpu']}, and kubelet.conf reserves {[r['cpu'] for r in reserved]}",
)
eviction = kubelet["evictionHard"]["memory.available"]
require(
    sum(quantity(r["memory"]) for r in reserved) + quantity(eviction) == quantity(system["memory"]),
    f"system.memory is {system['memory']}, and kubelet.conf reserves {[r['memory'] for r in reserved]} and evicts at {eviction}",
)

# ---- Terraform must apply these numbers and hold none of its own, for every namespace it makes.
terraform = terraform_root.read_text()
for reference in ("capacity.yaml", "local.capacity.quotas", "local.capacity.limit_ranges"):
    require(reference in terraform, f"{terraform_root} no longer names {reference}, so the sums here say nothing about the cluster")
block = re.search(r"^  namespaces = \{\n(.*?)^  \}\n", terraform, re.M | re.S)
require(block is not None, f"{terraform_root} has no namespaces block to compare with the quotas")
if block:
    namespaces = set(re.findall(r"^\s+([a-z0-9-]+)\s*=\s*\{\s*enforce", block.group(1), re.M))
    require(namespaces == set(quotas), f"Terraform makes namespaces {sorted(namespaces)}, and capacity.yaml has quotas for {sorted(quotas)}. A namespace with no quota means the sums below do not hold")

# ---- Every namespace is summed the same way, so every quota must bound all six.
for name, hard in quotas.items():
    for key in ("requests.cpu", "requests.memory", "limits.memory", "pods", "persistentvolumeclaims", "requests.storage"):
        require(key in hard, f"quota for {name} sets no {key}, so nothing bounds it and the sums below do not hold")
for name in ephemeral:
    require(name in quotas, f"ephemeral budgets {name}, which has no quota, so it is no namespace Terraform makes")


def total(key):
    return sum(quantity(hard.get(key, 0)) for hard in quotas.values())


scratch = sum(quantity(size) for size in ephemeral.values())
memory_used = total("limits.memory") + quantity(system["memory"])
cpu_used = total("requests.cpu") + quantity(system["cpu"])
disk_used = total("requests.storage") + quantity(system["disk"]) + scratch
# NodeDiskLow warns under 20% free, so a node with every budget full should still be quiet.
disk_ceiling = quantity(node["disk"]) * 0.80

require(memory_used <= quantity(node["memory"]), f"memory: limits {gib(total('limits.memory'))} and system {system['memory']} come to {gib(memory_used)}, and the node has {node['memory']}")
require(cpu_used <= quantity(node["cpu"]), f"CPU: requests {cores(total('requests.cpu'))} and system {system['cpu']} come to {cores(cpu_used)}, and the node has {node['cpu']}")
require(disk_used <= disk_ceiling, f"disk: claims {gib(total('requests.storage'))}, system {system['disk']} and emptyDir scratch {gib(scratch)} come to {gib(disk_used)}, and NodeDiskLow warns past {gib(disk_ceiling)}")

print(f"  memory {gib(memory_used)} of {node['memory']}: limits {gib(total('limits.memory'))}, system {system['memory']}")
print(f"  CPU    {cores(cpu_used)} of {node['cpu']}: requests {cores(total('requests.cpu'))}, system {system['cpu']}")
print(f"  disk   {gib(disk_used)} of {gib(disk_ceiling)}, 80% of {node['disk']}: claims {gib(total('requests.storage'))}, system {system['disk']}, emptyDir scratch {gib(scratch)}")


# ---- What is deployed must fit its own namespace's quota.
def documents():
    for path in sorted((work / "manifests").glob("*.json")):
        default = "plane-prod" if path.name == "plane-prod-render.json" else None
        for line in path.read_text().splitlines():
            if line.strip():
                yield default, json.loads(line)
    for path in sorted((work / "charts").glob("*/*.json")):
        for line in path.read_text().splitlines():
            if line.strip():
                yield path.parent.name, json.loads(line)


def pod_totals(spec, namespace):
    """Requests and limits as admission counts them: the containers together, or the largest init container if that is more."""
    defaults = limit_ranges.get(namespace, {})
    default_request = defaults.get("default_request", {})
    default_limit = defaults.get("default", {})
    ceiling = defaults.get("max", {}).get("memory")

    def read(container):
        resources = container.get("resources") or {}
        requests, limits = resources.get("requests") or {}, resources.get("limits") or {}
        limit = limits.get("memory", default_limit.get("memory", 0))
        return (
            quantity(requests.get("cpu", default_request.get("cpu", 0))),
            quantity(requests.get("memory", default_request.get("memory", limit))),
            quantity(limit),
        )

    for container in spec.get("containers", []) + spec.get("initContainers", []):
        limit = read(container)[2]
        if ceiling and limit > quantity(ceiling):
            problems.append(f"{namespace}: container {container.get('name')} has a memory limit of {mib(limit)}, over the LimitRange's {ceiling}")
    regular = [read(c) for c in spec.get("containers", [])]
    initial = [read(c) for c in spec.get("initContainers", [])]
    return tuple(max(sum(r[i] for r in regular), max((c[i] for c in initial), default=0)) for i in range(3))


usage = {}


def row(namespace):
    return usage.setdefault(namespace, {"cpu": 0.0, "request": 0.0, "limit": 0.0, "pods": 0, "extra": (0.0, 0.0, 0.0), "storage": 0.0, "claims": 0})


def extra(namespace, totals):
    """What one rollout or one Job adds on top. Only the largest counts: more than one at a time wait for room."""
    entry = row(namespace)
    entry["extra"] = tuple(max(a, b) for a, b in zip(entry["extra"], totals))


# cert-manager's defaults for the pod it starts beside a Certificate for each HTTP-01 challenge. The flags that would change them are its
# --acme-http01-solver-resource-*, and values/cert-manager.yaml sets none. No renewal can finish with no room for this pod.
SOLVER = (quantity("10m"), quantity("64Mi"), quantity("64Mi"))


def count_claim(namespace, spec):
    entry = row(namespace)
    entry["storage"] += quantity(spec["resources"]["requests"]["storage"])
    entry["claims"] += 1


for default, document in documents():
    kind = document.get("kind")
    metadata = document.get("metadata") or {}
    namespace = metadata.get("namespace") or default
    spec = document.get("spec") or {}
    if namespace not in quotas:
        continue
    if kind in ("Deployment", "StatefulSet", "DaemonSet"):
        replicas = spec.get("replicas", 1)
        if replicas == 0:
            continue
        totals = pod_totals(spec["template"]["spec"], namespace)
        entry = row(namespace)
        entry["cpu"] += totals[0] * replicas
        entry["request"] += totals[1] * replicas
        entry["limit"] += totals[2] * replicas
        entry["pods"] += replicas
        if kind == "Deployment" and (spec.get("strategy") or {}).get("type", "RollingUpdate") == "RollingUpdate":
            extra(namespace, totals)
        for claim in spec.get("volumeClaimTemplates", []):
            count_claim(namespace, claim["spec"])
    elif kind in ("Job", "CronJob"):
        job = spec["jobTemplate"]["spec"] if kind == "CronJob" else spec
        extra(namespace, pod_totals(job["template"]["spec"], namespace))
    elif kind == "Certificate":
        extra(namespace, SOLVER)
    elif kind == "PersistentVolumeClaim":
        count_claim(namespace, spec)
    elif kind in ("Prometheus", "Alertmanager"):
        # The operator builds these pods, and adds its config reloader, whose size the Prometheus Operator's flags set.
        resources = spec.get("resources") or {}
        requests, limits = resources.get("requests") or {}, resources.get("limits") or {}
        entry = row(namespace)
        entry["cpu"] += quantity(requests.get("cpu", 0)) + quantity("5m")
        entry["request"] += quantity(requests.get("memory", 0)) + quantity("16Mi")
        entry["limit"] += quantity(limits.get("memory", 0)) + quantity("48Mi")
        entry["pods"] += spec.get("replicas", 1)
        claim = ((spec.get("storage") or spec.get("storageSpec") or {}).get("volumeClaimTemplate") or {}).get("spec")
        if claim:
            count_claim(namespace, claim)

for namespace, entry in sorted(usage.items()):
    hard = quotas[namespace]
    needs = [
        ("limits.memory", entry["limit"] + entry["extra"][2], mib, f"{mib(entry['limit'])} steady, and {mib(entry['extra'][2])} for the largest rollout, Job or solver"),
        ("requests.memory", entry["request"] + entry["extra"][1], mib, f"{mib(entry['request'])} steady, and {mib(entry['extra'][1])} for the largest rollout, Job or solver"),
        ("requests.cpu", entry["cpu"] + entry["extra"][0], cores, f"{cores(entry['cpu'])} steady, and {cores(entry['extra'][0])} for the largest rollout, Job or solver"),
        ("requests.storage", entry["storage"], gib, f"{entry['claims']} claims"),
    ]
    for key, need, show, why in needs:
        require(need <= quantity(hard.get(key, 0)), f"{namespace} needs {show(need)} of {key} ({why}), and its quota is {hard.get(key)}")
    require(entry["pods"] + 1 <= int(hard["pods"]), f"{namespace} runs {entry['pods']} pods and needs room for one more, and its quota is {hard['pods']}")
    require(entry["claims"] <= int(hard["persistentvolumeclaims"]), f"{namespace} has {entry['claims']} claims, and its quota is {hard['persistentvolumeclaims']}")
    print(f"  {namespace}: limits {mib(entry['limit'])} + {mib(entry['extra'][2])} of {hard['limits.memory']}, requests {cores(entry['cpu'])} and {mib(entry['request'])}, {entry['pods']} pods, {gib(entry['storage'])} in {entry['claims']} claims")

if problems:
    for problem in problems:
        print(f"\033[1;31mfail\033[0m {problem}", file=sys.stderr)
    print("Change infrastructure/hosted/plane-prod/capacity.yaml, or lower what asked for more, so every quota still fits the node.", file=sys.stderr)
    raise SystemExit(1)
PY
ok "hosted production's quotas fit the node, with the system's share and the scratch no quota counts, and what is deployed fits its quotas"
