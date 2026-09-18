# Monitoring a new app

For an app on hosted production's cluster, in a namespace of its own. Everything below shows up at <https://grafana.bereket.dev>, and
`make remote-grafana-admin TARGET=plane-prod VERB=login` gives you the login.

Written while Wayline is the only app here and Frameflow is not deployed, so no app has gone through these steps yet. Frameflow is the example.

## What is automatic

As soon as the app's pods run in its namespace, with nothing added for it:

| You get | From | Where to look |
|---|---|---|
| Logs, kept 7 days | Alloy, which reads every namespace but `kube-system`, `kube-public`, `kube-node-lease` and `restore-test-*` | Grafana, Explore, Loki: `{namespace="frameflow"}` |
| CPU, memory and restarts per pod | The kubelet and kube-state-metrics, neither limited by namespace | Dashboards `Kubernetes / Compute Resources / Namespace (Pods)` and `/ Pod` |
| The namespace's CPU, memory and restarts on the page Grafana opens on | `Platform overview`, for the same namespaces Alloy reads | Its row `Workloads by namespace` |
| An alert on repeated restarts, or a container near its memory limit | `PodRestarting` and `ContainerMemorySaturation`, for the same namespaces Alloy reads | The alert receiver |
| An alert on a crash loop, a pod not ready, a stuck rollout or a failed Job | The chart's `KubePodCrashLooping`, `KubePodNotReady`, `KubeDeploymentRolloutStuck` and `KubeJobFailed`, for any namespace. Each waits about 15 minutes, and reads as a warning | The alert receiver |
| An alert on any certificate of its own | `CertificateExpiringSoon` and `CertificateNotReady`, from cert-manager's metrics | The alert receiver |

The alert receiver is Telegram once `make remote-alerts TARGET=plane-prod VERB=state` says COMPLETE, and until then a log nobody reads.

Prometheus also selects every ServiceMonitor, PodMonitor, Probe and PrometheusRule in any namespace, so what you add below needs no label and no
change to Prometheus.

## What a new app adds

Each of these lives in `gitops/clusters/plane-prod/platform/`. Monitoring objects for an app go in a folder of their own under `monitoring-extras/`,
listed in its `kustomization.yaml`, as `monitoring-extras/plane-prod/` does for Plane.

**1. A way in for Prometheus.** Every namespace here starts at default deny, so a scrape is refused until both halves exist. Its row goes in
`tests/network-policy-matrix-plane-prod.yaml` too. Beside the app's other policies, in `network-policies/`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-prometheus
  namespace: frameflow
spec:
  podSelector: { matchLabels: { app.kubernetes.io/name: frameflow } }
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: monitoring } }
          podSelector: { matchLabels: { app.kubernetes.io/name: prometheus } }
      ports:
        - { protocol: TCP, port: 9090 } # the app's metrics port
```

And in `network-policies/monitoring.yaml`, under Prometheus's egress:

```yaml
    - to:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: frameflow } }
      ports:
        - { protocol: TCP, port: 9090 }
```

**2. A ServiceMonitor for its own metrics,** if it has any. Without one you see its pods from the outside and nothing about what it is doing.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: frameflow
  namespace: frameflow
spec:
  selector:
    matchLabels: { app.kubernetes.io/name: frameflow }
  endpoints:
    - { port: metrics, interval: 30s }
```

**3. A Probe for uptime.** This is what tells you the app answers users, through Traefik and its certificate. Its host needs a line in
`k3s_coredns_rewrites` in `infrastructure/terraform/environments/prod/main.tf`, because blackbox may reach only Traefik's Service. The served-certificate
alert then covers that host by itself, and `Platform overview` shows it in `Probe history`. No alert reads a new Probe, so add a rule like the one in step 5.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Probe
metadata:
  name: frameflow
  namespace: frameflow
spec:
  jobName: frameflow-http
  interval: 30s
  scrapeTimeout: 10s
  module: http_html
  prober:
    url: blackbox.monitoring.svc.cluster.local:9115
    path: /probe
  targets:
    staticConfig:
      static:
        - https://frameflow.bereket.dev/
      labels: { probe: frameflow }
```

**4. A dashboard, if the generic ones are not enough.** Put the JSON in `monitoring-extras/shared/dashboards/` and list it under `configMapGenerator` in
that `kustomization.yaml`, with the label `grafana_dashboard: "1"`. It has to be in namespace `monitoring`, because that is all Grafana's sidecar watches. It
loads within about 30 seconds, with no restart. A datasource of its own is different: it goes in `grafana.datasources` in
`values/kube-prometheus-stack.yaml`, and the change replaces Grafana's pod, which signs everyone out. Nothing reads a ConfigMap labelled
`grafana_datasource`.

**5. Alerts of its own.** A PrometheusRule anywhere is read. Test it in `tests/rules/`.

```yaml
- alert: FrameflowDown
  expr: probe_success{probe="frameflow"} == 0
  for: 2m
  labels: { severity: critical, component: frameflow }
  annotations:
    summary: Frameflow has failed its probe for 2m
```

A public route is a separate change. `policy/hosted.rego` allows Plane's and Grafana's and no other, and a new one starts there.

## What is not covered

- **An app outside this cluster gets only an external probe.** There are no logs, pod metrics or generic alerts for it, because nothing here runs where it
  does. Even that probe needs a rule first: blackbox's policy allows Traefik alone, so a target on another server needs public addresses on 443 added to
  its egress, in the form Alertmanager's policy uses.
- **Logs written to a file.** Alloy reads what a container sends to stdout and stderr.
- **The app's traffic on `Platform overview`.** Its request rate and 5xx panels read Plane's services, so a new app's belong on its own dashboard, in step 4.
- **Anything in the app's own terms,** such as queue depth or failed jobs, until it exports a metric and a rule reads it. A pod can look healthy here while
  the app is broken, which is why step 3 matters most.
- **The node dying.** Nothing on it can report that. Healthchecks does, through Watchdog, once the same command says COMPLETE.
- **History past its retention.** Prometheus keeps 15 days, or 12 GiB, and Loki 7 days. Both are shared with every other app here.
