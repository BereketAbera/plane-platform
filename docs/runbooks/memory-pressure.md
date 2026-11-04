# Memory pressure

The Docker VM can run out before any single container reaches its limit.

Preamble for raw commands:

```bash
export PATH="$PWD/.tools/bin:$PATH" KUBECONFIG="$PWD/.local/kubeconfig"
```

## Why this happens

Memory limits are overcommitted on purpose. Critique section 4 sums limits to about 14.6 GiB, or about 107% of the 13.63 GiB the VM showed. Those are planning figures made before any Plane container ran on this host: an estimate derived from the configured limits and a mix of host measurements, third-party figures and research-report numbers. It says peak use could reach about 9.9 to 13.7 GiB with unrelated containers running.

[[MEASURE: idle and peak VM memory with both environments up]]

The worst case is first boot, so the contract says to bring environments up serially. [[VERIFY: root waves hold plane-prod-sim back until plane-dev's operation ends; integration review M1 found they do not gate children with internal waves]]

| Situation | Requirement, from critique section 4 (recommendation, not a measurement) |
|---|---|
| Unrelated containers stopped | At least 14 GiB for Docker |
| Unrelated containers running | 16 GiB |

`scripts/prereqs.sh` refuses below 13 GiB visible.

## Symptoms

| Symptom | Meaning |
|---|---|
| `VmMemoryLow` | `MemAvailable` below 10% of the node for 5 minutes |
| `ContainerMemorySaturation` | One container above 90% of its limit |
| `PodRestarting`, `lastState.terminated.reason: OOMKilled` | The container hit its cgroup limit, or the kernel chose it |
| Many pods restarting at once, slow API server, liveness failures | The VM is under pressure, not one workload |
| First boot takes very long, and pods flap | Migrations and API boots overlap |
| API requests hang while work items are being created, with nothing in the logs | RabbitMQ memory alarm has blocked publishers. See below |
| `exceeded quota` on a new pod | Namespace ResourceQuota, not VM memory |

## Diagnosis

```bash
make status
docker stats --no-stream
kubectl top pods -A --sort-by=memory | head -25
kubectl get pods -A -o json | jq -r '.items[] | .metadata as $m | .status.containerStatuses[]? | select(.lastState.terminated.reason == "OOMKilled") | "\($m.namespace)/\($m.name) \(.name) \(.lastState.terminated.finishedAt)"'
kubectl -n plane-dev describe resourcequota
```

Decide which case you have:

| Evidence | Case |
|---|---|
| One container is `OOMKilled` and the VM has room | Its limit is too low for its work |
| Several unrelated pods are killed, and VM memory is near full | The VM ran out. Reduce load |
| Memory is fine, and pods are `Pending` or rejected | Quota or scheduling |

Grafana's Platform overview shows "VM memory used" and "Memory by namespace". `kubectl top` needs metrics-server, which is synced at wave -8.

RabbitMQ memory alarm:

```bash
kubectl -n plane-dev exec plane-rabbitmq-wl-0 -c plane-rabbitmq -- rabbitmq-diagnostics alarms
kubectl -n plane-dev exec plane-rabbitmq-wl-0 -c plane-rabbitmq -- rabbitmq-diagnostics memory_breakdown
```

RabbitMQ runs with `vm_memory_high_watermark.absolute = 256Mi` under a 512 MiB limit. The default of 0.4 is unsafe here: if RabbitMQ detects the limit, 0.4 of it sits close to idle use and blocks publishers, which hangs `.delay()`. If it does not detect the limit, 0.4 of the VM's memory ends in an OOM kill. [[VERIFY: rabbitmq-diagnostics shows the 256Mi absolute watermark in effect under the cgroup limit]]

## Fix

**The VM ran out.** In order of cost:

1. Stop unrelated containers, by name, and only ones you own and can restart. Research put them at about 2 GiB on this host, an estimate from one `docker stats` reading.

   ```bash
   docker ps --format '{{.Names}}\t{{.Status}}'
   docker stop <name>
   ```

2. Give Docker more memory: Docker Desktop, Settings, Resources, Memory. Leave enough for macOS.
3. Do not run the branded image build alongside a full cluster. The estimate for its peak is 3 to 5 GiB (`plane-branding.md`, not measured here).
4. Take prod-sim's app tier down through Git, if you do not need it right now. There is no lean overlay in the repo today. The design in critique section 4 says this must be a Git overlay and not `kubectl scale`, or self-heal reverts it.

**One container is too small.** Limits come from contract section 10, which says to change them only with a measurement. Record the measurement, then edit Git:

| Workload | Where |
|---|---|
| Plane | `helm/plane/components/hardening/patches/<workload>.yaml`, then `make render` |
| Platform charts | `helm/values/<chart>.yaml` |
| Exporters, blackbox, sink | `monitoring/manifests/` |

Raising a Plane limit can pass the namespace ResourceQuota, which Terraform computes from its own table. Update `infrastructure/terraform/modules/foundation/main.tf` too, or the rollout fails with `exceeded quota` while old pods keep running. Then commit, `make gitops-publish`, and `terraform apply` for the quota.

Known first candidates, from comments in the code and the integration review:

| Workload | Limit now | Why it is a candidate |
|---|---|---|
| Loki | 640 MiB | Below the chart's example of 2 to 4 GiB |
| Argo CD repo-server | 384 MiB | The integration review saw `helm pull` of the KPS chart reach 194 MiB on macOS. That is an estimate for the Linux pod, and it suggests concurrent renders can pass the limit |
| Plane worker | 768 MiB | `CELERY_WORKER_CONCURRENCY=2` |
| API | 768 MiB | One gunicorn worker, `--max-requests 1200` recycles it |

**First boot.** Wait for it to converge. Retries are unlimited. Infisical runs about 603 migrations on first boot under a 1 GiB limit. If it is killed there, a temporary raise to 1.5 GiB in Git is the documented fallback (critique gate 9). [[VERIFY: Infisical's first boot completes under its configured memory limit]]

## Confirm

```bash
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
kubectl top pods -A --sort-by=memory | head -10
docker stats --no-stream
```

`VmMemoryLow` and `ContainerMemorySaturation` should resolve, and restart counts should stop climbing on the Platform overview's "Most restarted containers" table. Record real numbers in [resource utilization](../resource-utilization.md).

[[MEASURE: per-workload peak working set against the limits in contract section 10]]

## What not to do

| Do not | Why |
|---|---|
| `kubectl scale` or `kubectl set resources` to relieve pressure | Self-heal reverts them in seconds |
| Remove limits | The VM would run out sooner, and the kernel would pick the victim |
| Raise limits with no measurement | Contract section 10. Limits already exceed the VM |
| Raise `vm_memory_high_watermark` to or above the container limit | RabbitMQ then gets OOM killed instead of applying back-pressure |
| Raise `CELERY_WORKER_CONCURRENCY` to clear a backlog on a tight VM | Each fork costs memory. The chart default of 12 is what the contract's budget replaced |
| Start both environments' first boots at the same time | It is the worst case |
| Stop containers that you do not recognise | Other projects on this host share Docker |
| Conclude "the apps leak" from a working-set graph alone | Working set includes page cache. Check for actual OOM kills |
