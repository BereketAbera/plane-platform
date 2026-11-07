# Hosted apps: Rillmark, Awushi Cloudgarden and Frameflow

Three apps run on hosted production beside Wayline, on the same K3s node and the same platform services, each in a namespace,
AppProject and Argo CD Application of its own. This is how each is deployed, promoted, rolled back, checked and fixed.

**Status.** This was written with the change that adds the two static sites, before it was applied, so nothing below has run on the VPS
yet. Frameflow is not deployed: its sections say what already exists for it and are marked to be completed by the change that deploys it.

Commands below run from the root of the checkout that holds `.local/hosted/plane-prod/`, which is the main one, because Terraform's state
and the kubeconfig live there and nowhere else. The raw `kubectl` lines use this helper, as [scripts/hosted/README.md](../scripts/hosted/README.md)
does:

```bash
kc() { .tools/bin/kubectl --kubeconfig .local/hosted/plane-prod/kubeconfig --context plane-prod "$@"; }
make remote-tunnel TARGET=plane-prod     # if it is not up. Every script and session here shares it, so leave it running
```

## The apps

| | Rillmark | Awushi Cloudgarden | Frameflow |
|---|---|---|---|
| What it is | The documentation site and playground of the Rillmark React design system: a static Vite build | "Awushi's DevOps World", a browser 3D game on a simulated delivery stack: a static Vite build | Video upload and processing: a Next.js web app, an API, Hatchet workers running FFmpeg, its own Silo and Hatchet |
| Code and CI | [BereketAbera/rillmark](https://github.com/BereketAbera/rillmark): `ci.yml` checks, `images.yml` builds the image | [BereketAbera/awushi-cloudgarden](https://github.com/BereketAbera/awushi-cloudgarden): the same two workflows | [BereketAbera/frameflow](https://github.com/BereketAbera/frameflow): to be completed when it deploys |
| Images | `ghcr.io/bereketabera/rillmark/web` | `ghcr.io/bereketabera/awushi-cloudgarden/web` | `ghcr.io/bereketabera/frameflow/web` and `/backend` |
| Host | <https://rillmark.bereket.dev> | <https://devops.bereket.dev> | <https://frameflow.bereket.dev>, not serving yet |
| Namespace, AppProject, Application | `rillmark`, all three. Wave 1, with a finalizer | `awushi-cloudgarden`, all three. Wave 1, with a finalizer | `frameflow`. Wave 2, no finalizer, `PruneLast=true`, when it deploys |
| Certificate and its Secret | `rillmark-tls` | `devops-tls` | `frameflow-tls`, when it deploys |
| Runs | One nginx-unprivileged pod, `web`, on 8080, behind Service `rillmark` on 80 | The same, behind Service `awushi-cloudgarden` | To be completed when it deploys |

Each app's code and CI stay in its own repository, and nothing there can change this one. What runs where is configuration here.

### Where each piece lives

| Piece | Rillmark | Awushi Cloudgarden | Owner |
|---|---|---|---|
| Workloads, Service, route | `gitops/clusters/plane-prod/platform/rillmark/` | `.../platform/awushi-cloudgarden/` | Argo CD, Application of the same name |
| Application | `gitops/clusters/plane-prod/applications/rillmark.yaml` | `.../applications/awushi-cloudgarden.yaml` | Argo CD's root |
| NetworkPolicies | `.../platform/network-policies/rillmark.yaml` | `.../network-policies/awushi-cloudgarden.yaml` | Argo CD, `network-policies` |
| Certificate | `.../platform/certificates/rillmark-tls.yaml` | `.../certificates/devops-tls.yaml` | Argo CD, `certificates` |
| Probe | `.../platform/monitoring-extras/rillmark/` | `.../monitoring-extras/awushi-cloudgarden/` | Argo CD, `monitoring-extras` |
| Namespace (PSA `restricted`), quota `budget`, LimitRange `defaults` | `infrastructure/terraform/environments/prod/main.tf` and `infrastructure/hosted/plane-prod/capacity.yaml` | the same | Terraform, through `make remote-bootstrap` |
| AppProject | `gitops/clusters/plane-prod/bootstrap-chart/templates/appprojects.yaml` | the same | Terraform, through `make remote-bootstrap` |
| DNS A record | `vercel_dns_record.rillmark` in `infrastructure/terraform/environments/prod-host` | `vercel_dns_record.cloudgarden` | Terraform, through `scripts/hosted/host-terraform.sh` |
| Image pins | the manifest, and the same line in `policy/hosted-images.txt` | the same | a promotion pull request |

Each AppProject deploys to its own namespace only, may create nothing cluster-scoped, and may not create a NetworkPolicy, ResourceQuota,
LimitRange or any of cert-manager's kinds, so an app cannot widen what contains it or ask for another host's certificate. Its certificate
comes from the `certificates` Application instead. `policy/hosted.rego`'s `app_routes` table binds each host to its namespace and its
certificate, both ways, and its route to its own Services, each of which must select the pods of one component and send to their port.

## What they share with Wayline, and what they do not

They share the platform services and nothing of Wayline's data plane: no database, credentials, Silo or Infisical project crosses between
any two apps.

| Service | What an app gets from it | What has to be in place |
|---|---|---|
| Traefik | One IngressRoute per host, on `websecure` only. TLS 1.2 and up, with `sniStrict`, so a host with no certificate is refused at the handshake. `readTimeout: 180s` covers a request's body | The namespace in both of Traefik's provider lists, `gitops/clusters/plane-prod/values/traefik.yaml`. Changing those rolls Traefik once, a brief outage of every host |
| cert-manager | Its certificate from `letsencrypt-production`, by HTTP-01 through Traefik, renewed by itself | DNS first, the CoreDNS rewrite, the solver's policies and quota room: see [Certificates](#certificates) |
| Argo CD | One Application, reading `platform/<app>/` from `deploy/plane-prod`, under the app's own AppProject | The namespace and the AppProject, from Terraform, before the Application exists |
| Infisical | Nothing, for the static sites, which have no secrets. Frameflow gets its own project | To be completed when Frameflow deploys |
| Monitoring | Logs, pod metrics and the generic alerts with nothing added, and a Probe with `RillmarkDown` or `CloudgardenDown` (critical, 2m) and a `...NotWatched` rule. `CertificateNotWatched` names both certificates. [monitoring-new-app.md](monitoring-new-app.md) | The host's CoreDNS rewrite, because blackbox reaches only Traefik's Service |
| Backups | Nothing, for the static sites: see [Backups and recovery](#backups-and-recovery) | To be completed when Frameflow deploys |
| DNS | An A record to the VPS, TTL 60, in Vercel's `bereket.dev` zone | `infrastructure/terraform/environments/prod-host`, applied from this machine. The zone's wildcard otherwise points every name at Vercel |
| The edge firewall | 80 and 443, which are open per port and not per host, so no change | Nothing |
| CoreDNS | A rewrite of the host to Traefik's Service, so pods reach it without leaving the node | `k3s_coredns_rewrites` in `infrastructure/terraform/environments/prod/main.tf` |

## Deploying an app

### How a new version reaches the VPS

1. **The app's repository builds it.** On a push to its `main`, `images.yml` builds linux/amd64 and linux/arm64 without emulation,
   and pushes them to GHCR as one index, tagged with the commit's first 12 characters. Then it pulls the linux/amd64 image back
   by digest, smoke-tests and scans that digest, and only then records the digests in the run's summary and in its `image-digests` artifact,
   kept 90 days. So a digest with no record did not pass.
2. **A promotion pull request here moves the pin.** `promote-app.yml` points the app's manifest and its line in `policy/hosted-images.txt`
   at that digest, runs `scripts/ci/validate-manifests.sh`, and opens a pull request from `promote/<app>`. Promote the **linux/amd64**
   digest, the manifest the run pulled back, smoke-tested and scanned, so the node runs exactly that. The tag names the index, which holds
   it beside its linux/arm64 sibling.
   ```bash
   gh workflow run promote-app.yml -R BereketAbera/plane-platform -f app=rillmark -f component=web \
     -f digest=sha256:<the linux/amd64 digest> -f tag=<the commit's first 12 characters>
   gh run list -R BereketAbera/plane-platform -w promote-app.yml -L 1    # then gh run watch <id> -R BereketAbera/plane-platform
   ```
   Without `tag` the tag stays as it is, and may then name the commit of the image before. A dispatch for an app that already runs that
   image opens nothing. A second dispatch for the same app replaces the open pull request's change with its own.
3. **Merging is the approval.** GitHub cannot enforce it on this plan: see [.github/workflows/README.md](../.github/workflows/README.md).
   Check the digest before merging, as the next section says, because nothing else does: `publish-release.sh` confirms Wayline's digests
   on GHCR and no others.
4. **The release.** The merge to `main` runs `ci.yml`, and its `release-plane-prod` job moves `deploy/plane-prod` once the other jobs
   pass. A red `main` releases nothing, and production keeps what it ran.
5. **Argo CD syncs that app alone.** It polls `deploy/plane-prod`, with no webhook, so this takes a few minutes. The pull request changed
   only that app's folder and one line of the list, so only its Application has anything to sync. The Deployment rolls with `maxSurge: 1`
   and `maxUnavailable: 0`: the new pod starts beside the old one, which serves until the new one is ready, and then has 5 seconds to finish
   what Traefik still sends it.

Every app moves on its own, then, and only one thing ties them: a merge releases everything on `main`. A promotion merged after an
unrelated change ships that change too, and a red `main` holds every app's promotion back.

### Checking a digest

`promote-app.yml` cannot do this: the packages are private, and its token can read none of them. Do it before merging, with your own
logins. First, the run that published it, on the app's `main`, and what it recorded:

```bash
gh run list -R BereketAbera/rillmark -w images.yml -b main -L 5
dir="$(mktemp -d)" && gh run download <run id> -R BereketAbera/rillmark -n image-digests -D "$dir" && cat "$dir/digests.tsv"
```

It names the commit, the tag, the index digest and the linux/amd64 digest. The digest in the pull request must be that linux/amd64 digest,
from the commit you mean to ship. Then that GHCR serves it, under that tag's index:

```bash
gh auth refresh -h github.com -s read:packages       # once, if gh's token cannot read packages
gh auth token | docker login ghcr.io --username BereketAbera --password-stdin
docker buildx imagetools inspect ghcr.io/bereketabera/rillmark/web:<the tag>
```

Its `linux/amd64` entry must be the digest in the pull request. The token goes through a pipe into Docker's credential store and is never
printed. `docker logout ghcr.io` takes it out again.

### Promoting from this machine instead

`make promote-app` is the same script as the workflow, run here, and it commits nothing:

```bash
make promote-app APP=rillmark COMPONENT=web DIGEST=sha256:<the linux/amd64 digest> TAG=<the commit's first 12 characters>
SKIP_CHARTS=yes scripts/ci/validate-manifests.sh      # what the workflow runs before it opens the pull request
git switch -c promote/rillmark
git add gitops/clusters/plane-prod/platform/rillmark policy/hosted-images.txt
git commit -F .build/promote-app-message.txt
git push -u origin promote/rillmark && gh pr create --fill
```

Stage the two paths by name: `.tools` is an untracked symlink, and a tracked one makes the release refuse after the merge.
`make promote-app` refuses to start with uncommitted changes in those two paths, so nothing else rides along. A pull request a person
opens runs `ci.yml`, which one opened with `GITHUB_TOKEN` does not until someone approves that run.

`scripts/ci/promote-app.sh` refuses unless the app's folder names the image as exactly one string, however many containers run it,
nothing else hosted Argo CD reads names it, and the list holds it once. It also refuses the placeholder digest of zeros, and a tag of
`PLACEHOLDER` with no `TAG` to replace it.

## The first deploy

Order matters, and it takes two merges. Terraform's state and the kubeconfig live in this checkout, which applies what `main` holds, and
Argo CD must find the namespaces, projects and pull Secrets that the apply makes before it reads the apps' manifests. Every step but the
two merges runs from this machine.

1. **The images.** Each app's `images.yml` has run on its `main`, and the pins here name those digests and not the placeholder.
   `validate-manifests.sh` refuses the placeholder digest of zeros anywhere in `gitops/clusters/plane-prod/` or `policy/hosted-images.txt`,
   so the manifests' pull request stays red until a promotion replaces each.
2. **The first merge: what Terraform and the bootstrap read.** `infrastructure/hosted/plane-prod/`, both Terraform roots, the AppProjects
   in the bootstrap chart, `policy/` and its checks, and `scripts/hosted/pull-secrets.sh` with the bootstrap step and the make target that
   run it. Argo CD reads none of it: the release copies the bootstrap chart onto `deploy/plane-prod`, and only Terraform installs that.
   Then pull `main` into this checkout.
3. **DNS.** `vercel dns ls bereket.dev` first, because a record made by hand would sit beside Terraform's. Then plan, which should add the
   three app records and change nothing else, and apply with `EXPECT` set to what the plan printed. `apply` makes its own plan again, and
   applies nothing unless that plan's changes are exactly the ones in `EXPECT`:
   ```bash
   TARGET=plane-prod scripts/hosted/host-terraform.sh plan
   TARGET=plane-prod CONFIRM=plane-prod \
     EXPECT='create vercel_dns_record.cloudgarden, create vercel_dns_record.frameflow, create vercel_dns_record.rillmark' \
     scripts/hosted/host-terraform.sh apply
   ```
   Wait until `dig +short rillmark.bereket.dev` and `dig +short devops.bereket.dev` print only `5.253.234.127`.
   [Its README](../infrastructure/terraform/environments/prod-host/README.md) has the rest.
4. **The cluster.** Namespaces, quotas, LimitRanges, the CoreDNS rewrites and the AppProjects come from Terraform, and Secret `ghcr-pull`
   in both sites' namespaces from `scripts/hosted/pull-secrets.sh`, all through `make remote-bootstrap TARGET=plane-prod CONFIRM=plane-prod`.
   It applies with `-auto-approve` and shows no plan, so read one first, as
   [`environments/prod/README.md`](../infrastructure/terraform/environments/prod/README.md) says, and expect `0 to destroy`. Terraform's
   state exists once, in this checkout, and an apply from a tree that lacks another change on `main` reverts it. Then
   `make remote-bundle TARGET=plane-prod`, because the state changed. Before the next merge, see that what it waits for is there:
   ```bash
   kc -n rillmark get secret ghcr-pull && kc -n awushi-cloudgarden get secret ghcr-pull
   kc -n argocd get appproject rillmark awushi-cloudgarden frameflow
   ```
   Without the Secret a site's first pod fails its pull with `401`, and its Application reads Progressing, then Degraded once the
   Deployment passes its progress deadline, which fails the root's sync at wave 1, until `make remote-pull-secrets TARGET=plane-prod
   CONFIRM=plane-prod` runs.
5. **The second merge: the manifests.** Only now, because Argo CD must find the namespaces, projects and Secrets, and cert-manager the DNS
   records. Root syncs in waves: `network-policies` at -10, `traefik` at -9, which rolls once, `certificates` at -7, `monitoring-extras` at -5,
   then both sites at 1. Each Probe syncs before its site, so a first deploy can page once before its route answers.
6. **Verify**, as the next section says, and with `make remote-test TARGET=plane-prod CONFIRM=plane-prod ONLY="outside psa netpol"`.

## Checking status

```bash
make remote-status TARGET=plane-prod      # every Application, pods not ready, certificates, the release branch. Read-only
kc -n argocd get application rillmark awushi-cloudgarden \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision'
kc -n rillmark get deployment,pods,service,ingressroute,certificate
kc -n rillmark get deployment web -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kc -n rillmark rollout status deployment/web --timeout=5m
kc -n rillmark logs deployment/web --tail=50
```

What production reads, and what it was released from:

```bash
git fetch origin deploy/plane-prod
git show origin/deploy/plane-prod:RELEASE.json
git show origin/deploy/plane-prod:gitops/clusters/plane-prod/platform/rillmark/deployment.yaml | grep 'image:'
```

From outside, and with each app's own check against the VPS, run in that app's checkout:

```bash
curl -sSI https://rillmark.bereket.dev/ && curl -sS https://devops.bereket.dev/healthz
make remote-test TARGET=plane-prod CONFIRM=plane-prod ONLY=outside   # DNS, the redirect and the served certificate of each host
RILLMARK_SITE_URL=https://rillmark.bereket.dev npm run test:e2e        # in rillmark: a headed browser, so it needs a display
node scripts/verify-deployment.mjs https://devops.bereket.dev          # in awushi-cloudgarden: rewrites a few tracked files there
```

Logs are in Grafana, Explore, Loki: `{namespace="rillmark"}` for nginx, and Traefik's access log for every request to a host,
`{namespace="traefik"} | json | RequestHost="rillmark.bereket.dev"`, which names the router and the status.

## Rolling back

Revert the promotion's commit on `main`, through a pull request like any other change, and the release and Argo CD bring the image before
it back, the same way a promotion arrives:

```bash
git log --format='%h %s%n  replaces %(trailers:key=Promote-Replaces,valueonly)' -- gitops/clusters/plane-prod/platform/rillmark
git revert <commit>
```

Images are immutable and pinned by digest, so the image before is exactly what ran before, as long as GHCR still holds it: nothing in
these repositories deletes a version. Promoting the digest from that commit's `Promote-Replaces` line again does the same.
`publish-release.sh` never moves `deploy/plane-prod` backwards, so a rollback is always a new commit on `main`, and never a push to that
branch, which `check-deploy-branch.yml` and `make remote-status` would report.

The static sites hold no data, so the image is all there is to roll back. If a rollout failed, the old pod is probably still serving:
`maxUnavailable: 0` keeps it until the new one is ready.

## Certificates

One per host, in the app's namespace: `rillmark-tls` in `rillmark` and `devops-tls` in `awushi-cloudgarden`. Each has issuer
`letsencrypt-production` and an ECDSA key that changes at each renewal, and cert-manager renews it by itself.

**The first issuance needs DNS first.** The zone's wildcard answers for any name with no record of its own, and points at Vercel. If
cert-manager sees a Certificate before the A record is live, Let's Encrypt fails the order, and the next try is an hour away, doubling up
to 32 hours. So the record goes in before the merge, as [The first deploy](#the-first-deploy) says. The path, all of which must hold:

- The A record answers with the VPS alone: `dig +short rillmark.bereket.dev`.
- The CoreDNS rewrite sends the host to Traefik's Service. cert-manager's self-check goes through it, because its egress refuses the
  node's public address: `kc -n kube-system get configmap coredns-custom -o jsonpath='{.data.rewrites\.override}'`.
- Traefik reads the namespace in its Ingress provider, which serves the solver's temporary Ingress.
- The solver pod can start: the quota has room for it, `kc -n rillmark describe resourcequota budget`.
- Traefik may reach the solver on 8089: the namespace's `acme-http01-solver` policy and Traefik's egress rule to it.
- Port 80 is open on the edge firewall, which Let's Encrypt validates over: `scripts/hosted/edge.sh status`.

To see where it stopped:

```bash
kc -n rillmark get certificate,certificaterequest,order,challenge
kc -n rillmark describe challenge
```

Once the cause is fixed, an order that already failed waits out its backoff. This removes it, and cert-manager tries again at once:

```bash
.tools/bin/kubectl --kubeconfig .local/hosted/plane-prod/kubeconfig --context plane-prod -n rillmark patch certificate rillmark-tls \
  --subresource=status --type=json -p '[{"op":"remove","path":"/status/lastFailureTime"}]'
```

For Awushi Cloudgarden it is `-n awushi-cloudgarden` and `devops-tls`. [scripts/hosted/README.md](../scripts/hosted/README.md), under The
first certificate, says where that comes from: it is read from cert-manager v1.21.3 and has not run on this cluster.

Until the Secret exists, Traefik refuses the host's handshake, so a browser shows a connection error and not a page, and the Probe reads
down. blackbox verifies certificates, so a staging certificate reads as down too.

## Image pulls: Secret ghcr-pull

The packages are private. Each static site's namespace holds Secret `ghcr-pull`, of type `kubernetes.io/dockerconfigjson`, which
ServiceAccount `web` names in `imagePullSecrets`. `scripts/hosted/pull-secrets.sh` makes it from the owner's token file,
`.local/hosted/plane-prod/ghcr-pull-token`, through files and stdin and never an argument, and `make remote-bootstrap` runs it. It is not
in Git, which may hold no Secret, and not in Infisical, because an operator for each site would add a pod and cluster-scoped RBAC to
deliver one token.

That token is a classic token with `read:packages`, so it reads every private package on the account, Wayline's too. To rotate it:

1. Make the new token, and save it at a hidden prompt: `scripts/hosted/owner-inputs.sh ghcr`.
2. `make remote-pull-secrets TARGET=plane-prod CONFIRM=plane-prod`, which writes both sites' Secrets again.
3. `make remote-bundle TARGET=plane-prod`, because the bundle holds the token file.
4. Plane's copy comes from `GHCR_PULL_TOKEN` in Infisical, which the seed never overwrites. Change it there, through
   `make remote-ui TARGET=plane-prod UI=infisical`, and only then revoke the old token, or Plane's next pull fails.

A running pod keeps the image it has. The next pull, on a new pod or after the node frees the image, reads the new Secret.

## Secrets

The static sites have none: they are files, with nothing to sign in to and nothing to keep. Their namespaces hold `ghcr-pull` and the
certificate's Secret, which cert-manager writes, and `scripts/hosted/scrub-values.sh` reads both namespaces, so those values stay out of
published evidence.

## Backups and recovery

**The static sites have nothing to back up.** Each is its image, built from its repository, and what a visitor saves lives in that
browser's local storage. So they are in no nightly backup, no `BACKUP_NAMESPACES` and no restore test, and should not be added: with no
backup to pull, the off-VPS status would stay INCOMPLETE for good, and the restore test would read BLOCKED.

**Recovery.** On the VPS, Argo CD recreates them from `deploy/plane-prod`, and cert-manager issues their certificates again. Off it,
their copies are GitHub, which holds this repository and each app's, and GHCR, which holds the images. A cluster rebuilt from the recovery
bundle and synced from `deploy/plane-prod` brings them back as they were, as long as GHCR still serves those digests and the pull token
works. So for them the line between a local backup and an off-server one does not arise: nothing on the VPS needs a copy, and their
off-server copies are GitHub and GHCR.

## Troubleshooting

### ImagePullBackOff

```bash
kc -n rillmark get pods
kc -n rillmark describe pod -l app.kubernetes.io/component=web | sed -n '/Events:/,$p'
```

The site keeps serving: the old pod stays until the new one is ready. Argo CD shows the Application Progressing, and Degraded once the
Deployment passes its progress deadline, and `KubeDeploymentRolloutStuck` fires after about 15 minutes. By the event's text:

- **`not found` or `manifest unknown`.** GHCR has no such digest under that name: a typo, another app's or component's digest, or one
  from a run that failed before it recorded it. Check it as [Checking a digest](#checking-a-digest) says, then revert, or promote the right one.
- **`401 Unauthorized`, `403 Forbidden` or `denied`.** The pull Secret is missing, or its token was revoked or has expired.
  `kc -n rillmark get secret ghcr-pull` and `kc -n rillmark get serviceaccount web -o jsonpath='{.imagePullSecrets}'`, then
  [rotate it](#image-pulls-secret-ghcr-pull).
- **`no match for platform in manifest`.** That digest is an index with no linux/amd64 image in it. Promote the run's index, which has
  one. A digest of a single arm64 image pulls instead, and then its container fails with `exec format error`.

### 404, 503 or 502 from Traefik, or no handshake

| What you see | What it means | Look at |
|---|---|---|
| The TLS handshake fails with an alert, before any certificate is shown | Traefik holds no certificate for the host, and `sniStrict` refuses it | The Certificate, below. Or Traefik does not read the namespace, so neither the route nor its Secret is loaded: both lists in `values/traefik.yaml` |
| `404 page not found`, Traefik's plain-text body | No route matched. The handshake worked, so the certificate is loaded | `kc -n rillmark get ingressroute rillmark -o yaml`, its `Host` rule, and `kc -n traefik logs deployment/traefik --since=10m` for an error about it |
| An HTML 404 from nginx | The route works, and that file is not in the image. Awushi Cloudgarden answers every missing asset that way on purpose | The app's build |
| `503`, body `no available server` | The route matched, and its Service has no ready pod: an image that does not pull, a failing `/healthz`, or a selector that does not match | `kc -n rillmark get endpointslices -l kubernetes.io/service-name=rillmark`, then the pod. The local cluster's Traefik answered a route with no ready pod this way ([traefik-routes-2.txt](evidence/runs/traefik-routes-2.txt)) |
| `502 Bad Gateway` | A pod is ready, and Traefik could not connect to it. Here that is usually a NetworkPolicy | The next section |

### A NetworkPolicy rejects it

kube-router rejects what a policy denies, so a denial reads as connection refused, at once, as a closed port does, and not as a timeout.
The kubelet's probes come from the node, which no policy covers, so a pod can be Ready and still out of Traefik's reach. Every crossing
needs both halves:

- Traefik to the site: the namespace's `web` policy lets Traefik's pods in on 8080, and `traefik-egress` in
  `network-policies/traefik.yaml` lets them out to that namespace's `app.kubernetes.io/component: web` pods on 8080. The port is the
  container's, because kube-router reads a connection after the Service has been translated.
- Traefik to the solver: `acme-http01-solver` in the namespace, and the matching egress rule, on 8089.
- A pod without `app.kubernetes.io/component: web` matches neither, whatever its other labels.

`make remote-netpol TARGET=plane-prod CONFIRM=plane-prod FROM_NS=traefik` runs the matrix rows that start in Traefik's namespace, Traefik
to each site among them, and `FROM_NS=rillmark` the site's own. A refusal while the node connects to the same port is a policy.

### A merged promotion is not running

- **The release did not run.** `gh run list -R BereketAbera/plane-platform -w ci.yml -b main -L 3`. A red `main` moves nothing, and
  `git show origin/deploy/plane-prod:RELEASE.json` names the commit it last released.
- **Argo CD has not polled yet.** Wait a few minutes, or ask it now:
  `kc -n argocd annotate application rillmark argocd.argoproj.io/refresh=normal --overwrite`.
- **It is rolling out, or stuck.** See [ImagePullBackOff](#imagepullbackoff), and
  `kc -n argocd get application rillmark -o jsonpath='{.status.operationState.message}{"\n"}'`.

A promotion changes no Application file, so the root does not sync for it, and a site whose rollout fails holds nothing else. A change to
an Application file does make the root sync in waves. A site stuck Progressing then holds every later wave, Frameflow's at 2, until it
is fixed or the root's operation is ended: [docs/runbooks/argo-sync-stuck.md](runbooks/argo-sync-stuck.md), End an operation, with this
cluster's `kc` in place of the local one.

## The Vercel deployments stay

Both sites are also still on Vercel, deployed from the owner's machine with the Vercel CLI: <https://rillmark.vercel.app> (project
`rillmark`) and <https://awushi-devops-world.vercel.app> (project `awushi-devops-world`), in scope `bereketaberas-projects`. They stay
until the owner asks for them to go, after the VPS versions are verified. Before that:

- Rillmark's published npm package, 0.2.0, links to rillmark.vercel.app from its homepage field, README and agent skill, so taking that
  deployment down breaks those links unless a redirect takes its place.
- Awushi Cloudgarden keeps saves in each origin's local storage, so progress made on the Vercel origin does not carry over to
  devops.bereket.dev.

## Frameflow

> **To be completed by the change that deploys Frameflow.** This section says only what exists for it now.

What is already in place, shared with the static sites' change:

- Namespace `frameflow`, PSA `restricted`, with a quota of `pods: "0"`, so nothing can start there yet, not even a certificate's solver.
- NetworkPolicy `default-deny` alone, in `network-policies/frameflow.yaml`, and Traefik's egress rules to its web on 3000, to Silo's S3
  port 9000 for the upload route, and to its solver on 8089, which nothing in the namespace admits yet.
- AppProject `frameflow`, its row in `policy/hosted.rego`'s `app_routes`, and the namespace in both of Traefik's provider lists, so its
  deploy rolls nothing in Traefik. The row already holds its two Services to their pods: `frameflow-web` on port 3000 to component `web`
  on 3000 or `http`, and `frameflow-silo` on 9000 to component `s3` on 9000 or `api`. Its Certificate must be the one
  `platform/certificates` would write for its host, and Pod Security is asked about its namespace by `make remote-test`.
- Its DNS record and CoreDNS rewrite. Once that record is applied, `frameflow.bereket.dev` resolves to the VPS: http redirects to https,
  and https fails at the handshake, because it has no certificate yet. It no longer reaches Vercel.

Each part below is to be completed when it deploys, and says what it has to cover:

### Frameflow: components and how they are deployed

> To be completed: web, API, worker, the maintenance CronJobs, Silo and its setup Job, Hatchet and its Postgres, and the operator. Their
> waves, their promotion (`web` and `backend`, one at a time, because both share `promote/frameflow`), and which images are not this
> app's own.

### Frameflow: secrets

> To be completed: Infisical project `frameflow-prod` and its operator `iso-frameflow`, the static secrets and their waves, minting and
> writing the Hatchet client token, and `ghcr-pull` from Infisical.

### Frameflow: backups and restore

> To be completed: the nightly `plane-backup` CronJob in `frameflow` (SQLite, Hatchet's Postgres and the media bucket, sealed by restic
> with `--host frameflow`), the pull off the VPS, and the restore steps, with which copy is local and which is off-server.

### Frameflow: rollback, consoles and troubleshooting

> To be completed: what a rollback leaves in the database, the Hatchet dashboard and Silo console through `make remote-ui`, uploads
> against Traefik's 180-second `readTimeout`, the worker's limits, and failed or cancelled jobs.
