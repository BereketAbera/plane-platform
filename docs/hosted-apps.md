# Hosted apps: Rillmark, Awushi Cloudgarden and Frameflow

Three apps run on hosted production beside Wayline, on the same K3s node and the same platform services, each in a namespace,
AppProject and Argo CD Application of its own. This is how each is deployed, promoted, rolled back, checked and fixed.

**Status.** Live on hosted production since 2026-11-08. #4 (what Terraform and the bootstrap read), #5 (release A) and #6 (release B)
merged that night, after the DNS and cluster applies and the bootstrap, and #7 added Frameflow to the off-VPS pull. The same night's checks
all passed:
- every host over trusted HTTPS, with its routes, Pod Security and the 350-row NetworkPolicy matrix;
- Frameflow end to end: upload, Hatchet, FFmpeg, HLS at 360p and 720p, and playback;
- a failed job, a mid-encode cancel and a queued second video;
- Wayline's latency during the encodes, with no K3s restart;
- each app's backup, its restore test, and the off-VPS pull and verify.

Silo's setup Job needed 512Mi (#6). The parts below that say they ran only in Docker on this machine were later run on the VPS as well.

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
| Code and CI | [BereketAbera/rillmark](https://github.com/BereketAbera/rillmark): `ci.yml` checks, `images.yml` builds the image | [BereketAbera/awushi-cloudgarden](https://github.com/BereketAbera/awushi-cloudgarden): the same two workflows | [BereketAbera/frameflow](https://github.com/BereketAbera/frameflow): `ci.yml` runs its tests with FFmpeg, `images.yml` builds and checks both images |
| Images | `ghcr.io/bereketabera/rillmark/web` | `ghcr.io/bereketabera/awushi-cloudgarden/web` | `ghcr.io/bereketabera/frameflow/web` and `/backend` |
| Host | <https://rillmark.bereket.dev> | <https://devops.bereket.dev> | <https://frameflow.bereket.dev> |
| Namespace, AppProject, Application | `rillmark`, all three. Wave 1, with a finalizer | `awushi-cloudgarden`, all three. Wave 1, with a finalizer | `frameflow`, all three. Wave 2, no finalizer, `PruneLast=true`. Its Infisical operator is Application `infisical-operator-frameflow`, wave 1, under `platform` |
| Certificate and its Secret | `rillmark-tls` | `devops-tls` | `frameflow-tls` |
| Runs | One nginx-unprivileged pod, `web`, on 8080, behind Service `rillmark` on 80 | The same, behind Service `awushi-cloudgarden` | Web, API, worker and two CronJobs from its two images, beside its own Hatchet, Hatchet's Postgres and its own Silo: [Frameflow](#frameflow) |

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

Frameflow's are in [Frameflow: where its pieces live](#frameflow-where-its-pieces-live).

Each AppProject deploys to its own namespace only, may create nothing cluster-scoped, and may not create a NetworkPolicy, ResourceQuota,
LimitRange or any of cert-manager's kinds, so an app cannot widen what contains it or ask for another host's certificate. Its certificate
comes from the `certificates` Application instead. `policy/hosted.rego`'s `app_routes` table binds each host to its namespace and its
certificate, both ways, and its route to its own Services, each of which must select the pods of one component and send to their port.

## What they share with Wayline, and what they do not

They share the platform services and nothing of Wayline's data plane: no database, credentials, Silo or Infisical project crosses between
any two apps.

| Service | What an app gets from it | What has to be in place |
|---|---|---|
| Traefik | One IngressRoute per host, on `websecure` only. TLS 1.2 and up, with `sniStrict`, so a host with no certificate is refused at the handshake. `readTimeout: 900s` covers a request's body | The namespace in both of Traefik's provider lists, `gitops/clusters/plane-prod/values/traefik.yaml`. Changing those rolls Traefik once, a brief outage of every host |
| cert-manager | Its certificate from `letsencrypt-production`, by HTTP-01 through Traefik, renewed by itself | DNS first, the CoreDNS rewrite, the solver's policies and quota room: see [Certificates](#certificates) |
| Argo CD | One Application, reading `platform/<app>/` from `deploy/plane-prod`, under the app's own AppProject | The namespace and the AppProject, from Terraform, before the Application exists |
| Infisical | Nothing, for the static sites, which have no secrets. Frameflow gets project `frameflow-prod`, read by an operator of its own, `iso-frameflow`, in its namespace alone: [Frameflow: secrets](#frameflow-secrets) | The project, its identity and its values, from `make remote-bootstrap`, before Frameflow's Application exists |
| Monitoring | Logs, pod metrics and the generic alerts with nothing added, and a Probe with `RillmarkDown` or `CloudgardenDown` (critical, 2m) and a `...NotWatched` rule. `CertificateNotWatched` names both certificates, and Frameflow's. Frameflow adds `FrameflowDown`, `FrameflowApiUnavailable`, `FrameflowWorkerUnavailable`, `HatchetUnavailable`, `FrameflowBucketNearQuota` and `FrameflowBucketFull`, two `...NotWatched` rules, and Silo's metrics. Its backup is in `BackupTooOld`, `BackupNeverSucceeded` and `PlaneBackupFailed`. [monitoring-new-app.md](monitoring-new-app.md) | The host's CoreDNS rewrite, because blackbox reaches only Traefik's Service |
| Backups | Nothing, for the static sites: see [Backups and recovery](#backups-and-recovery). Frameflow's SQLite file, Hatchet's database and its bucket, nightly, sealed on the node by restic, and pulled off it by hand: [Frameflow: backups and restore](#frameflow-backups-and-restore) | Folder `/srv/wayline/backups/frameflow` and Secret `restic-password` in `frameflow`, from `make remote-bootstrap` |
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

Frameflow's first deploy takes the same two merges, with more in each, and then a third, after a token is minted by hand:
[Frameflow: the first deploy](#frameflow-the-first-deploy).

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

## Backing out the first deploy

The first deploy comes out newest first: Frameflow's release B, then the second merge, then the first. Only the second is a revert on
`main`, through a pull request, and it takes steps by hand before it. Not tried: this is read from the manifests and from how Argo CD
behaves, as [Argo CD](argocd.md) records it.

1. **Release B.** In place, and not by a revert, which would prune Frameflow's database volume:
   [Frameflow: rolling back](#frameflow-rolling-back) says how.
2. **The second merge.** Its revert takes the apps' namespaces out of Traefik's provider lists, so Traefik rolls once, a brief outage of
   every host, Wayline's among them, as at the merge. Each child the merge changed puts its part back by itself at its next sync: Traefik's
   values, the NetworkPolicies, the Certificates, the Probes and rules, the backup and the token reviewer's subject. Root prunes the four
   Applications the merge added. `rillmark` and `awushi-cloudgarden` carry the resources finalizer, so their pods, Services and routes go
   with them. `frameflow` and `infisical-operator-frameflow` carry none, so everything they deployed would stay and run with nothing
   managing it: behind the default deny that `network-policies/frameflow.yaml` holds on `main` before the merge, which lets no pod reach
   DNS, Hatchet's Postgres or Infisical, and with Frameflow's rules gone, so nothing would page. So take Frameflow out by hand first, while
   its policies stand, and only then merge the revert:
   ```bash
   # Root first, or its self-heal makes both Applications again from the files still in Git.
   kc -n argocd patch application root --type merge -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}'
   for a in frameflow infisical-operator-frameflow; do
     kc -n argocd patch application "$a" --type merge -p '{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io"]}}'
   done
   kc -n argocd delete application frameflow --timeout=15m     # returns once Argo CD has deleted what it deployed
   kc -n frameflow get deployments,statefulsets,cronjobs,infisicalstaticsecrets,pvc
   kc -n argocd delete application infisical-operator-frameflow --timeout=10m
   ```
   The operator goes last, after the Infisical CRs it served. Its chart installs no CRDs, so deleting it reaches nothing of `iso-prod`'s.
   What stays: the claims of Hatchet's Postgres and Silo, which come from `volumeClaimTemplates` and which Argo CD does not track, and the
   volume of every claim deleted, `frameflow-data` among them, `Released` on `local-path-retain` with its folder. Then merge the revert,
   wait for its release, and put root's auto-sync back:
   `kc -n argocd patch application root --type json -p '[{"op":"remove","path":"/spec/syncPolicy/automated/enabled"}]'`. Root then prunes
   the sites' Applications. If its operation does not end, because a child it waits on never finishes, end it as
   [End an operation](runbooks/argo-sync-stuck.md#end-an-operation) says, and ask for a hard refresh.
3. **The first merge.** Its namespaces, quotas, LimitRanges, AppProjects, CoreDNS rewrites, DNS records and Infisical project can stay:
   Argo CD reads none of them, and they cost nothing with nothing in them. Keep them at least until the four Applications are gone,
   because an Application whose project does not exist holds root with no retry. Taking them out is a Terraform change of its own, planned
   and read like any other, and prod-host's records each carry `prevent_destroy`, which that change takes off first. Do not revert the
   merge on `main` ahead of that change. Terraform's state exists once, and from a tree without the merge, as `main` would then be,
   `make remote-bootstrap` applies the prod root with no plan to read, which destroys the apps' objects, and
   `scripts/infisical-bootstrap.sh` destroys project `frameflow-prod`, whose slug then stays reserved for 14 days
   ([terraform.md](terraform.md)).

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
ServiceAccount `web` names in `imagePullSecrets`. Frameflow's `ghcr-pull` comes from Infisical instead, because it has an operator anyway:
[Frameflow: secrets](#frameflow-secrets). `scripts/hosted/pull-secrets.sh` makes it from the owner's token file,
`.local/hosted/plane-prod/ghcr-pull-token`, through files and stdin and never an argument, and `make remote-bootstrap` runs it. It is not
in Git, which may hold no Secret, and not in Infisical, because an operator for each site would add a pod and cluster-scoped RBAC to
deliver one token.

That token is a classic token with `read:packages`, so it reads every private package on the account, Wayline's too. To rotate it:

1. Make the new token, and save it at a hidden prompt: `scripts/hosted/owner-inputs.sh ghcr`.
2. `make remote-pull-secrets TARGET=plane-prod CONFIRM=plane-prod`, which writes both sites' Secrets again.
3. `make remote-bundle TARGET=plane-prod`, because the bundle holds the token file.
4. Plane's copy comes from `GHCR_PULL_TOKEN` in Infisical, and Frameflow's from the same key in project `frameflow-prod`, and the seed
   overwrites neither. Change both there, through `make remote-ui TARGET=plane-prod UI=infisical`, and only then revoke the old token, or
   the next pull of either fails.

A running pod keeps the image it has. The next pull, on a new pod or after the node frees the image, reads the new Secret.

## Secrets

The static sites have none: they are files, with nothing to sign in to and nothing to keep. Their namespaces hold `ghcr-pull` and the
certificate's Secret, which cert-manager writes, and `scripts/hosted/scrub-values.sh` reads both namespaces, so those values stay out of
published evidence. Frameflow's are in [Frameflow: secrets](#frameflow-secrets).

## Backups and recovery

Frameflow's are in [Frameflow: backups and restore](#frameflow-backups-and-restore).

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
until the owner chooses to take them down, after the VPS versions are verified. Before that:

- Rillmark's published npm package, 0.2.0, links to rillmark.vercel.app from its homepage field, README and agent skill, so taking that
  deployment down breaks those links unless a redirect takes its place.
- Awushi Cloudgarden keeps saves in each origin's local storage, so progress made on the Vercel origin does not carry over to
  devops.bereket.dev.

## Frameflow

Frameflow takes an uploaded MP4, makes 360p and 720p HLS renditions of it with FFmpeg, and plays them back. It is a Next.js web server, an
API and a Hatchet worker, from two images of its own, beside its own Hatchet, Hatchet's own Postgres and its own Silo, all in namespace
`frameflow`. Unlike the static sites it holds data, its secrets come from Infisical, and its first deploy reaches the cluster in two
releases, with a token minted by hand between them.

### Frameflow: what runs, and why

| Component, and its `app.kubernetes.io/component` | What it is | Ports | Storage |
|---|---|---|---|
| `frameflow-web`, `web` | Deployment, 1 replica, rolling with surge 1. Next.js's server: the pages, and a proxy of the API's public routes | 3000 | emptyDirs at `/tmp` and `/app/.next/cache` |
| `frameflow-api`, `api` | Deployment, 1 replica, `Recreate`. The `backend` image's default command, Fastify: it signs uploads, queues each video with Hatchet, takes the worker's reports and serves playback | 4000 | PVC `frameflow-data`, 1Gi, holding the SQLite file `/data/app.db` |
| `frameflow-worker`, `worker` | Deployment, 1 replica, `Recreate`. The `backend` image as a Hatchet worker, running FFmpeg | 8001, its health, for the kubelet alone | emptyDir `/scratch`, 8Gi |
| `frameflow-cleanup` and `frameflow-reconcile`, `maintenance` | CronJobs, hourly and every 10 minutes, from the `backend` image | none | `frameflow-data` |
| `frameflow-silo`, `s3` | StatefulSet, 1. The Silo image and digest Plane's render runs | 9000 S3, 9090 console | PVC 25Gi, for bucket `frameflow-media`, held to 18GiB |
| `frameflow-silo-setup`, `s3-setup` | Job, an Argo CD Sync hook, so it runs again at every sync of `frameflow`, with `pgsty/mc` | none | none |
| `hatchet`, `hatchet` | Deployment, 1 replica, `Recreate`. hatchet-lite v0.114.2: the engine, its REST API and its dashboard in one process | 7070 gRPC, 8080 REST, 8888 dashboard with the REST API under `/api`, 8733 health for the kubelet | `/config`, in memory, 16Mi |
| `hatchet-postgres`, `postgres` | StatefulSet, 1. Postgres 16.15: Hatchet's database, and its queue | 5432 | PVC 5Gi |
| `plane-backup`, `backup` | CronJob, nightly at 02:47 UTC, in Application `backup`: [backups](#frameflow-backups-and-restore) | none | PVC `backups`, 24Gi, and an emptyDir of 22Gi |
| `iso-frameflow` | Infisical's operator, for this namespace alone, as plane-prod has `iso-prod`: Application `infisical-operator-frameflow` | none | none |

Every pod runs as a user that is not root, with no capability, as the namespace's Pod Security level, `restricted`, requires, and on a
read-only root filesystem. The images of Hatchet, Silo, `mc` and Postgres set no such user, so the manifests name one: 65532 for Hatchet,
1000 for Silo and `mc`, as Frameflow's own images do, and 70, the alpine image's postgres, for Postgres.

Why it is built this way:

- **Its own Silo, not Wayline's.** Wayline's Silo is part of Plane's render, moves with Plane's promotion, and Plane's pods hold its root
  keys, so a bucket of Frameflow's there would be open to anything that broke into Plane, and one backup would hold two apps. Frameflow's
  runs the same image with root keys of its own, which only Silo and the setup Job read. The app holds an app user's keys, for its one
  bucket, and the backup a read-only user's. The setup Job makes the bucket, its quota, both users and their policies at every sync,
  because Silo's users are in no backup. In Docker, with these images, running it four times over changed nothing that was already
  right, and the app user could do nothing outside its bucket.
- **hatchet-lite, with Postgres as its queue.** The engine, the REST API and the dashboard in one pod, and no RabbitMQ: what Hatchet
  supports for low volume, and the least to run on one node. Every start runs Hatchet's migrations and its seed, so it rolls out by
  `Recreate` and two never run together. Its Postgres is its own, on the 16.15 image Infisical's runs, so no database or credential is
  shared with Wayline or Infisical. Its keysets come from Infisical, and hatchet-lite writes `/config` again from them at every start, so
  nothing there needs keeping. In Docker it ran that way, as 65532 with no capability, and wrote nothing but `/config`.
- **SQLite on a volume, with one API.** Frameflow keeps its catalogue of videos, comments and profiles in one SQLite file, and one process
  writes it, so the API runs once and rolls out by `Recreate`. The CronJobs open the same file, on the same ReadWriteOnce volume, on the
  one node. The worker never opens it: it reports each step to the API over HTTP.

The images that are not Frameflow's own, hatchet-lite, Silo, `mc` and Postgres, and the backup's Python, rclone and restic, are pinned by
digest in the manifests and in `policy/hosted-images.txt`, and move only by an ordinary pull request that changes both. `promote-app.yml`
moves `web` and `backend` alone, which nothing outside `platform/frameflow/` names: the backup reads SQLite with the platform's Python.

### Frameflow: what the internet reaches

| A request to frameflow.bereket.dev | Reaches | Who can |
|---|---|---|
| Any, but the upload below | `frameflow-web:3000`, which proxies `/api/auth`, `/api/videos`, `/api/health`, `/api/social` and `/streams` to the API, `frameflow-api:4000`, and nothing else of it | Anyone. A `POST` to `/api/auth/session`, where the owner signs in, passes Middleware `frameflow-login-limit` first: 10 a minute from one client address, with a burst of 10, and Traefik's 429 past those |
| A `PUT` under `/frameflow-media/videos/`, from release B | `frameflow-silo:9000`, for one presigned upload | Whoever holds a URL the API signed, for 15 minutes |

- **Writes are the owner's alone.** With `AUTH_MODE=owner`, a visitor reads the feed, watch pages, profiles and the streams of public and
  unlisted videos, and adds to nothing but a video's view count. Uploading, editing, deleting, commenting, liking, saving and every private
  video need the owner, who signs in at `/studio` with the access key. The API answers with a signed session cookie, `HttpOnly`, `Secure`
  and `SameSite=Lax`, for 12 hours: [the owner access key](#frameflow-the-owner-access-key). A new upload is private until the owner
  changes that in the studio.
- **The upload route is one method under one prefix.** `policy/hosted.rego` holds a route to Silo to exactly
  ``Host(`frameflow.bereket.dev`) && Method(`PUT`) && PathPrefix(`/frameflow-media/videos/`)``, with no Middleware, and holds each Service
  a route names to its own pods and port, so the rest of Silo's API, its listings and its admin calls get no route. The URL is signed for
  that host, its object key, `Content-Type: video/mp4` and its expiry, and Traefik passes the Host header on as it came: in Docker, such a
  URL answered 403 `SignatureDoesNotMatch` to any other Host, and to any other content type. The signature is in the query string, which
  `values/traefik.yaml` keeps out of Traefik's access log.
- **No buffering on it.** A buffering Middleware would hold whole videos in Traefik, whose memory limit is 256Mi. The size limit is the
  API's: it checks the size an upload declares before it signs, and the size Silo then holds before it queues the video.
- **Playback goes through the API**, at `/streams/<video>/...`, which serves a completed video's master playlist, its two rendition
  playlists and their segments to whoever may see that video. The bucket itself is private, with no anonymous access.
- **Nothing else answers.** Not the API's own port, nor its `/internal/*`, where the worker reports, which the web server does not proxy
  and `WORKER_CALLBACK_SECRET` guards. Not Silo's console, Hatchet's gRPC, REST API or dashboard, nor either database. People reach the
  two consoles by port-forward: [consoles](#frameflow-consoles).

### Frameflow: where its pieces live

| Piece | Where | Owner |
|---|---|---|
| Workloads, Services, routes, the Infisical CRs | `gitops/clusters/plane-prod/platform/frameflow/`, which its `kustomization.yaml` builds: Argo CD applies what that lists, and nothing else there | Argo CD, Application `frameflow` |
| The Applications | `.../applications/frameflow.yaml`, and `.../applications/infisical-operator-frameflow.yaml` with `.../values/infisical-operator-frameflow.yaml` | Argo CD's root |
| NetworkPolicies | `.../platform/network-policies/frameflow.yaml`, one policy per component, and the other halves in `traefik.yaml`, `monitoring.yaml` and `infisical.yaml` beside it | Argo CD, `network-policies` |
| Certificate | `.../platform/certificates/frameflow-tls.yaml` | Argo CD, `certificates` |
| Probe, rules, Silo's ServiceMonitor | `.../platform/monitoring-extras/frameflow/` | Argo CD, `monitoring-extras` |
| Backup: PV `backups-frameflow`, PVC `frameflow/backups`, CronJob `frameflow/plane-backup` | `.../platform/backup/storage.yaml` and `frameflow.yaml` | Argo CD, `backup` |
| The operator's right to review its own login | `plane-infisical-auth` in `frameflow`, a subject in `.../platform/infisical/token-reviewer.yaml` | Argo CD, `infisical` |
| Namespace, quota `budget`, LimitRange `defaults`, AppProject, DNS record, CoreDNS rewrite | As the static sites' | Terraform, through `make remote-bootstrap` and `host-terraform.sh` |
| Infisical project `frameflow-prod`, its identity and its values | `scripts/hosted/target.sh` names it, `infisical/terraform` makes it, `scripts/infisical-seed.sh` fills it | `make remote-bootstrap` |
| The owner access key, its sha256 and Hatchet's three keysets | `.local/hosted/plane-prod/frameflow/`, made once by `make remote-frameflow-inputs` | This machine, and the recovery bundle |
| Image pins | The manifests, and the same lines in `policy/hosted-images.txt` | `promote-app.yml` for `web` and `backend`, a pull request for the rest |

### Frameflow: the first deploy

It keeps the order of [The first deploy](#the-first-deploy): what Terraform and the bootstrap read merges first and is applied from this
machine, and only then the manifests Argo CD acts on. Those then reach the cluster in two releases, because Hatchet must run before its
client token can exist, and the token's InfisicalStaticSecret reads Degraded until it does. Argo CD's root holds every later change to an
Application while a child has an operation open (`values/argocd.yaml`), so one release with everything would stop Frameflow's first sync
at that CR, retrying it, and hold root with it. Release A brings up Hatchet, its Postgres, Silo and the web server. Release B adds the
token's CR, then the API, the worker and the CronJobs, and the upload route.

1. **The images.** The pins name the two digests Frameflow's `images.yml` recorded for its commit `83f693d81006`, in run 42383037982, which
   pushed, pulled back, checked and scanned them. Check them before the merge as
   [Frameflow: deploying a new version](#frameflow-deploying-a-new-version) says.
2. **The owner's inputs, on this machine.** The owner access key and its sha256, and Hatchet's three keysets, which hatchet-admin v0.114.2
   makes in Docker with no network, into 0600 files under `.local/hosted/plane-prod/frameflow/`. A file that exists is never made again:
   the keysets must outlive every database Hatchet writes with them. Docker needs to be running. The image is public, so where Docker's
   credential helper hangs, run this with `DOCKER_CONFIG` naming a folder whose `config.json` is `{"auths":{}}`.
   ```bash
   make remote-frameflow-inputs TARGET=plane-prod
   ```
   Put the access key in your password manager, as it says.
3. **The first merge: what Terraform and the bootstrap read.** Beside the static sites' part of it: Frameflow's quota and LimitRange in
   `infrastructure/hosted/plane-prod/capacity.yaml`, its Infisical environment in `scripts/hosted/target.sh` and the scripts that make and
   fill it, its backup folder and restic Secret in `scripts/hosted/bootstrap.sh`, its files in `bundle.sh`'s list, and the two Frameflow
   scripts and their make targets. `platform/frameflow/` comes with the next merge, so the Infisical bootstrap warns that nothing here says
   yet what its `InfisicalAuth` references, and binds the names that folder uses: Secret `plane-infisical-identity` and ServiceAccount
   `plane-infisical-auth`, in `frameflow`. Then pull `main` into this checkout.
4. **DNS, the cluster and Infisical.** DNS as for the sites: the same apply adds Frameflow's record, so wait for
   `dig +short frameflow.bereket.dev` too. Read a plan of the prod root first, as for the sites: Frameflow's quota and LimitRange change,
   and nothing is destroyed. Infisical's Terraform can be read the same way, with Infisical forwarded, as
   `make remote-ui TARGET=plane-prod UI=infisical` does, in another terminal. It should add Frameflow's five resources and change nothing of
   `prod`'s:
   ```bash
   WAYLINE_TARGET=plane-prod CONFIRM=plane-prod PLAN_ONLY=yes INFISICAL_URL=http://127.0.0.1:<port> scripts/infisical-bootstrap.sh
   ```
   Then apply, bundle what changed, and back Infisical up at once:
   ```bash
   make remote-bootstrap TARGET=plane-prod CONFIRM=plane-prod
   make remote-bundle TARGET=plane-prod
   make remote-backup TARGET=plane-prod CONFIRM=plane-prod ONLY=infisical     # so a dump holds frameflow-prod
   ```
   Bootstrap gives Frameflow its quota, makes `/srv/wayline/backups/frameflow` and Secret `restic-password` in the namespace, and runs
   Infisical's bootstrap. That adds project `frameflow-prod`, its read-only identity and its Kubernetes Auth, bound to namespace
   `frameflow` alone, and the seed writes each Frameflow value that is missing, generated or from the owner's files. The identity's id
   goes into Secret `plane-infisical-identity` in the namespace, where `InfisicalAuth` reads it. Until a dump of Infisical holds
   `frameflow-prod`, restoring Infisical brings back a database older than it, and restored mode then stops before prod's CA and identity,
   so the backup comes straight after: [after a lost VPS](#frameflow-backups-and-restore) says what to do if one is restored anyway.
   Before the next merge:
   ```bash
   kc -n frameflow get resourcequota budget -o jsonpath='{.spec.hard.pods}{"\n"}'       # 16, where it was 0
   kc -n frameflow get secret plane-infisical-identity restic-password
   ```
5. **The second merge: release A**, with the static sites' manifests. For Frameflow: `platform/frameflow/` and the lines of
   `policy/hosted-images.txt` it names, the two Applications, its NetworkPolicies, its Certificate, its Probe and rules, its backup, and the
   token reviewer's new subject. Root syncs `network-policies` and `backup` at wave -10, `certificates` at -7, `monitoring-extras` at -5,
   `infisical` at -4, `infisical-operator-frameflow` at 1 and `frameflow` at 2. Inside `frameflow`, in waves: the ServiceAccounts and
   `InfisicalConnection` (-3), `InfisicalAuth` (-2), the InfisicalStaticSecrets but the token's (-1), the ConfigMap and the Services (0),
   Hatchet's Postgres and Silo (1), Hatchet and Silo's setup Job (2), the web server (3), and its route (4). The Probe syncs before the
   route, so `FrameflowDown` can page once before the site answers, as the sites' Probes can. The API's and the worker's rules stay quiet
   until their Deployments exist. Watch it:
   ```bash
   kc -n argocd get application infisical-operator-frameflow frameflow \
     -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,MESSAGE:.status.operationState.message'
   kc -n frameflow get infisicalstaticsecrets,pods,pvc
   kc -n frameflow rollout status deployment/hatchet --timeout=10m
   kc -n frameflow logs job/frameflow-silo-setup
   ```
   If that Job fails, [Silo's setup Job fails](#silos-setup-job-fails) says where to look, and root waits until it passes.
   The site then shows its pages, and every call they make to the API fails, until release B. So does the nightly backup, whose pod
   mounts the API's volume: take release B the same day, or `PlaneBackupFailed` says so the next morning. `make remote-test` can run now
   too, and its matrix rows that dial `frameflow-api` read INCONCLUSIVE until release B.
6. **The token.** With `hatchet` Ready, from this machine:
   ```bash
   make remote-frameflow-token TARGET=plane-prod CONFIRM=plane-prod
   make remote-backup TARGET=plane-prod CONFIRM=plane-prod ONLY=infisical     # so a dump holds it
   ```
   It runs `/hatchet-admin token create` in Hatchet's pod, for the default tenant and for 87600 hours, takes off the newline Hatchet ends it
   with, and writes it to Infisical as `HATCHET_CLIENT_TOKEN`, through stdin and the port-forward, never printing it. It prints the
   token's name, `frameflow-<time>`, which is how the dashboard lists it.
7. **The third merge: release B.** In `platform/frameflow/kustomization.yaml`, move the five files its release B comment lists into its
   `resources`, and add the backend image's line to `policy/hosted-images.txt`, the pin those files name: the list holds only what Argo
   CD is given, and release A runs no backend. Only `frameflow` syncs, because no Application file changes: the token's
   InfisicalStaticSecret at wave 3, then the API with its volume, the worker, the CronJobs and the upload route at 4.
8. **Verify.** Hatchet's dashboard lists `frameflow-worker` under Workers ([consoles](#frameflow-consoles)). Sign in at
   <https://frameflow.bereket.dev/studio>, upload an MP4 of at least 1280x720, and watch it play. Make one, if FFmpeg is here, with
   `ffmpeg -f lavfi -i testsrc2=size=1280x720:rate=30 -t 10 -c:v libx264 -pix_fmt yuv420p test.mp4`, and one at `640x360` to see
   `SOURCE_TOO_SMALL`. Then:
   ```bash
   curl -sS https://frameflow.bereket.dev/api/health/ready      # the API's own check of SQLite and Silo, through the web server
   make remote-test TARGET=plane-prod CONFIRM=plane-prod ONLY="outside psa netpol"
   make remote-netpol TARGET=plane-prod CONFIRM=plane-prod FROM_NS=frameflow
   make remote-backup TARGET=plane-prod CONFIRM=plane-prod ONLY=frameflow
   make remote-restore-test TARGET=plane-prod CONFIRM=plane-prod ONLY=frameflow
   ```
   `frameflow` joined `BACKUP_NAMESPACES` in `scripts/hosted/lib-restic.sh` once that first backup had sealed (2026-11-08), so
   `make remote-pull-backups` takes an off-server copy of it too: [backups and restore](#frameflow-backups-and-restore).

### Frameflow: the owner access key

It is the one credential that writes to Frameflow. `make remote-frameflow-inputs` made it from 32 random bytes, in base64 with no newline,
into `.local/hosted/plane-prod/frameflow/owner-access-key`, and wrote its sha256 beside it, in `OWNER_TOKEN_SHA256`. Infisical holds only
that sha256, under the same name, and so does the API. The key belongs in your password manager, and the recovery bundle holds the file
while it is here. Once the key is in the password manager the file may go: nothing reads it again.

To sign in, open <https://frameflow.bereket.dev/studio> and paste the key, which this copies without printing it:

```bash
pbcopy < .local/hosted/plane-prod/frameflow/owner-access-key
```

The browser keeps the session cookie and never the key. A script sends the key as a bearer token instead, from the file and never in an
argument:

```bash
printf 'Authorization: Bearer %s\n' "$(cat .local/hosted/plane-prod/frameflow/owner-access-key)" |
  curl -sS -H @- https://frameflow.bereket.dev/api/auth/me
```

To replace it, as after a leak:

1. Make a new key and its sha256. The keysets beside them stay as they are:
   ```bash
   rm -f .local/hosted/plane-prod/frameflow/owner-access-key .local/hosted/plane-prod/frameflow/OWNER_TOKEN_SHA256
   make remote-frameflow-inputs TARGET=plane-prod
   pbcopy < .local/hosted/plane-prod/frameflow/OWNER_TOKEN_SHA256
   ```
2. Paste it as the new value of `OWNER_TOKEN_SHA256` in Infisical, project `frameflow-prod`, environment `prod`, through
   `make remote-ui TARGET=plane-prod UI=infisical`. The seed writes only what is missing, so this is how a value changes.
3. Within a minute the operator writes Secret `frameflow-app` again, and auto-reload restarts the API, which reads it when it starts and
   is the one pod that holds the owner's keys. The API is down for those seconds, because it rolls out by `Recreate`, and a video in
   processing goes on, because the worker reads neither key. From then on the old key signs in no more.
4. `make remote-bundle TARGET=plane-prod`, and put the new key in your password manager.

A session signed in before stays valid until it ends, up to 12 hours, because the session is signed with `OWNER_SESSION_SECRET` and not the
key. To end them all now, replace that the same way, with at least 32 characters: `openssl rand -hex 32 | tr -d '\n' | pbcopy`.

### Frameflow: secrets

All of them are in Infisical project `frameflow-prod`, environment `prod`, at `/`, which only Frameflow's identity reads, and only its
operator, `iso-frameflow`, logs in as it, from its own namespace. Each Kubernetes Secret below is written by an InfisicalStaticSecret of
the same name, from a template whose `secretFrom` lines say which Infisical key each of its keys comes from, and the operator reads them
again every 60 seconds. None is in Git, and `scripts/hosted/scrub-values.sh` reads the namespace, so their values stay out of published
evidence. Two Secrets there come from this machine instead: `plane-infisical-identity`, the identity's id, from the Infisical bootstrap,
and `restic-password`, from `make remote-bootstrap`. cert-manager writes `frameflow-tls`.

| Secret | Holds | Read by | Made by |
|---|---|---|---|
| `frameflow-app` | `WORKER_CALLBACK_SECRET`, `OWNER_TOKEN_SHA256`, `OWNER_SESSION_SECRET`, and the app user's `S3_ACCESS_KEY_ID` and `S3_SECRET_ACCESS_KEY`, under the same names in Infisical | The API alone, which alone sets `AUTH_MODE=owner`: whoever holds the owner's keys can sign in as the owner. The web server reads no Secret | The seed, in hex, but `OWNER_TOKEN_SHA256`, from the owner's file |
| `frameflow-worker` | `WORKER_CALLBACK_SECRET`, and the app user's `S3_ACCESS_KEY_ID` and `S3_SECRET_ACCESS_KEY` | The worker, which runs FFmpeg on every upload and is given no key to sign in with. Frameflow refuses the owner's keys in a role without `AUTH_MODE=owner`, so a worker given them would not start | The seed, from the same keys as `frameflow-app` |
| `frameflow-maintenance` | The app user's `S3_ACCESS_KEY_ID` and `S3_SECRET_ACCESS_KEY` | The two CronJobs, and a restore's `objects` step | The seed, from the same keys |
| `frameflow-silo-root` | `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD`, from `SILO_ROOT_USER` and `SILO_ROOT_PASSWORD` | Silo alone | The seed |
| `frameflow-silo-setup` | Root's two, and `APP_ACCESS_KEY`, `APP_SECRET_KEY`, `BACKUP_ACCESS_KEY` and `BACKUP_SECRET_KEY`, from the app user's and the backup user's keys | The setup Job alone | The seed |
| `frameflow-silo-backup` | The read-only backup user's `S3_BACKUP_ACCESS_KEY_ID` and `S3_BACKUP_SECRET_ACCESS_KEY` | The backup | The seed |
| `hatchet-db` | `POSTGRES_USER`, `POSTGRES_PASSWORD` and `POSTGRES_DB`, from `HATCHET_PG_USER`, `HATCHET_PG_PASSWORD` and `HATCHET_PG_DB` | Hatchet's Postgres, the init container in Hatchet's pod that waits for it, and the backup | The seed: user and database `hatchet`, the password in hex |
| `hatchet-server` | `DATABASE_URL`, built from the three `HATCHET_PG_*` keys, which is why the password is hex: nothing URL-encodes it. `SERVER_AUTH_COOKIE_SECRETS`, `SERVER_ENCRYPTION_MASTER_KEYSET`, `SERVER_ENCRYPTION_JWT_PRIVATE_KEYSET`, `SERVER_ENCRYPTION_JWT_PUBLIC_KEYSET` and `ADMIN_PASSWORD`, from `HATCHET_COOKIE_SECRETS`, `HATCHET_MASTER_KEYSET`, `HATCHET_JWT_PRIVATE_KEYSET`, `HATCHET_JWT_PUBLIC_KEYSET` and `HATCHET_ADMIN_PASSWORD` | Hatchet, and the backup, for a truncated hash of the master keyset | The keysets from the owner's files, the rest by the seed |
| `hatchet-client-token` | `HATCHET_CLIENT_TOKEN`, in its own CR at wave 3, which release B adds | The API, the worker and the reconcile CronJob | `make remote-frameflow-token`, once Hatchet runs |
| `ghcr-pull` | The pull Secret, from `GHCR_PULL_TOKEN` | The accounts of the pods that run Frameflow's own images, `web`, `api`, `worker` and `maintenance`. Every other image here is public | The seed, from `.local/hosted/plane-prod/ghcr-pull-token`, as for Plane |

A change in Infisical reaches its Secret within a minute. Auto-reload then restarts the Deployments that read it, a Job or CronJob reads
it at its next run, and Postgres and Silo, which carry no auto-reload, read theirs only as below. What changing each takes:

- **The app user's and the backup user's keys.** Silo names a user by its access key, so change only the secret key: a new access key
  would make a second user at the next sync and leave the first one able to sign in. Then sync `frameflow` in Argo CD's UI
  (`make remote-ui TARGET=plane-prod UI=argocd`), so the setup Job gives the user its new secret: `mc admin user add` on a user that exists
  keeps its policy and replaces its secret, and the old one is refused from then on. The API and the worker restart with the new key by
  themselves, and Silo refuses them until the Job has run.
- **Silo's root keys.** Silo reads them when it starts, so a change takes `kc -n frameflow delete pod frameflow-silo-0`, and then a sync for
  the Job. Not tried.
- **Hatchet's Postgres password.** `POSTGRES_PASSWORD` acts only on an empty data directory, so a new value in Infisical alone locks Hatchet
  out of the database it has. Change it in Postgres first, at psql's hidden prompt, then the same in Infisical, which restarts Hatchet with
  the new `DATABASE_URL`. Hex, as the seed makes it: `openssl rand -hex 24 | tr -d '\n' | pbcopy`. Not tried.
  ```bash
  kc -n frameflow exec -it hatchet-postgres-0 -- psql -U hatchet -d hatchet -c '\password hatchet'
  ```
- **Hatchet's three keysets: never.** The JWT keysets are encrypted under the master keyset, every token Hatchet has minted is signed with
  them, and what Hatchet encrypts in its database is under the master keyset. They change only with the database: a restore puts back a
  dump written under the same three, which are in Infisical, in this machine's files and in the bundle. If all three are lost, Hatchet
  needs a new, empty database, a new set and a new token. Its runs and their history go with it, and Frameflow's videos do not: they are in
  SQLite and Silo.
- **Hatchet's cookie secrets**, `HATCHET_COOKIE_SECRETS`, sign the dashboard's sessions, so a new value only signs everyone out of it. It is
  two keys with one space between, each of 32 hex characters, which
  `printf '%s %s' "$(openssl rand -hex 16)" "$(openssl rand -hex 16)" | pbcopy` copies. A key of 64 characters stops Hatchet at start, with
  `secrets must be 16/24/32 bytes`, as Docker showed.
- **Hatchet's admin password.** Hatchet's seed makes the admin only when there is none, so a new value changes nothing for the admin who
  exists. Change the password in the dashboard, which lets a user change their own, and then the same in `HATCHET_ADMIN_PASSWORD`, so the
  two agree.
- **The Hatchet client token** lasts ten years. It names `SERVER_URL`, and Hatchet checks every token against it, its keysets and its own
  database, which is why `SERVER_URL` never changes. To replace it, as after a leak, run `make remote-frameflow-token` again, which writes
  the new one over it in Infisical. Once the API and the worker have restarted with it, revoke the old one in the dashboard, under Settings,
  API Tokens. A database restored from before a token was minted has no row for it, and Hatchet refuses it: mint another the same way.
- **`GHCR_PULL_TOKEN`** changes with the static sites' and Plane's: [Image pulls](#image-pulls-secret-ghcr-pull).
- **`WORKER_CALLBACK_SECRET`** is read by the API and the worker alike, from `frameflow-app` and `frameflow-worker`, and auto-reload
  restarts both. Change it while no video is processing: a report the worker sends while the two disagree is refused, and fails its task.

### Frameflow: deploying a new version

Its two images come from one run of Frameflow's `images.yml`, on its `main`. It builds `web` and `backend` for linux/amd64 alone, pushes
them tagged with the commit's first 12 characters, pulls each back by digest, runs its FFmpeg check and its smoke test on exactly those
digests, scans them with trivy, and only then records them, in the job summary and in `digests.txt` in the run's `image-digests`
artifact. Each is a plain image manifest and not an index, so the digest it records is the one to promote. Check it before the merge, with
your own logins, as [Checking a digest](#checking-a-digest) does for the sites:

```bash
gh run list -R BereketAbera/frameflow -w images.yml -b main -L 5
dir="$(mktemp -d)" && gh run download <run id> -R BereketAbera/frameflow -n image-digests -D "$dir" && cat "$dir/digests.txt"
gh run view <run id> -R BereketAbera/frameflow --json headSha -q '.headSha[0:12]'          # the tag
docker buildx imagetools inspect ghcr.io/bereketabera/frameflow/backend@sha256:<its digest>  # one linux/amd64 manifest, no list
```

Then promote each, one at a time, because both share branch `promote/frameflow`, and a second dispatch replaces the first one's change:

```bash
gh workflow run promote-app.yml -R BereketAbera/plane-platform -f app=frameflow -f component=backend \
  -f digest=sha256:<backend's digest> -f tag=<the commit's first 12 characters>
```

Merge it, and then the same with `-f component=web`. The backend goes first, because the pages call the API, and newer pages may call what
an older API does not have. `make promote-app APP=frameflow COMPONENT=backend DIGEST=... TAG=...` does the same here. Before release B
the list holds no `backend` line, so a promotion of it is refused until release B adds one.

What each does once Argo CD has synced it:

- **`backend`.** The API stops and then starts, by `Recreate`, so for some seconds whatever the site asks it fails, and it applies any new
  migration of its SQLite file as it starts. The worker gets SIGTERM, takes no new task, and finishes the one it runs, for up to 600
  seconds, and only then does the new one start. Videos wait in Hatchet's queue meanwhile. The CronJobs run the new image from their
  next run.
- **`web`.** It rolls with surge 1, so the old pod serves until the new one is ready.

Hatchet, Silo, `mc` and Postgres move by an ordinary pull request that changes the manifest and the line in `policy/hosted-images.txt`
together. Back up before a new Hatchet, because it migrates its database when it starts, and going back takes the dump from before:
`make remote-backup TARGET=plane-prod CONFIRM=plane-prod ONLY=frameflow`.

### Frameflow: rolling back

Revert the promotion's commit, as [Rolling back](#rolling-back) says for the sites. What that leaves:

- **The SQLite schema.** The API applies its migrations when it starts and has none that undo one. If the older image runs on the newer
  file, stop there. If it does not, restore from the nightly before the promotion, as
  [Frameflow: backups and restore](#frameflow-backups-and-restore) says. What was uploaded since is then still in Silo, and in no record.
- **Hatchet's schema**, after a new Hatchet: an older hatchet-lite on a newer database is not supported. Restore Hatchet's database from
  the dump before the upgrade, with the same keysets.
- **Videos.** Those the newer worker processed stay as they are: their renditions in Silo, their records in SQLite.

**Taking release B back out.** Do it in place: revert the promotion that brought the trouble, as above. To stop it altogether, set
`replicas: 0` on `frameflow-api` and `frameflow-worker` and `suspend: true` on both CronJobs, through a pull request: videos then wait in
Hatchet's queue, the pages load and their calls fail, as before release B, and `FrameflowApiUnavailable` and
`FrameflowWorkerUnavailable` fire until it comes back. Never take its five files out of `kustomization.yaml`'s list: `frameflow` would
prune them, and claim `frameflow-data` with them. Its volume, on `local-path-retain`, would go to `Released` with `app.db` still in its
folder, and nothing binds a released volume again. The nightly mounts that claim too, so its next run would wait in `Pending` until its
deadline, and `PlaneBackupFailed` fires. Listed again, the claim gets a new, empty volume, and the API starts on an empty catalogue: the
sources and renditions stay in Silo and the runs in Hatchet, and no record names them. If the files were taken out anyway, then before
they are listed again, keep the old volume for the claim of that name, so that the claim the listing makes binds to it and not to a new
one. Not tried:

```bash
kc get pv -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,CLAIM:.spec.claimRef.name,MADE:.metadata.creationTimestamp' \
  | grep -E '^NAME|frameflow-data'
# Available again, and kept for frameflow/frameflow-data alone:
kc patch pv <the Released one> --type merge -p '{"spec":{"claimRef":{"uid":null,"resourceVersion":null}}}'
kc -n frameflow get pvc frameflow-data -o jsonpath='{.spec.volumeName}{"\n"}'   # after the release: that volume
```

Or restore the database from the nightly, with only `unseal` and `sqlite`: [Restoring](#frameflow-backups-and-restore).

### Frameflow: consoles

Neither has a public route. Each is a port-forward through the tunnel, from this machine, and runs until Ctrl-C:

```bash
make remote-ui TARGET=plane-prod UI=hatchet          # Hatchet's dashboard, at http://localhost:18888 and no other port
make remote-ui TARGET=plane-prod UI=frameflow-silo   # Silo's console, at http://localhost:18110 or the next port free
```

**Hatchet's dashboard.** Sign in as `admin@frameflow.local`, with the password this copies without printing it:

```bash
kc -n frameflow get secret hatchet-server -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d | pbcopy
```

Open it as `http://localhost:18888`, not 127.0.0.1: its session cookie is for `localhost` alone, and in Docker a sign-in at 127.0.0.1 did
not hold. The port is the one `SERVER_URL` names, so `ui.sh` takes no other, and says so when something else holds it. Sign-up is off, and
so is making another tenant. It shows each run of the last 7 days with its tasks, attempts and errors, and the workers that are
registered, and it can cancel a run.

**Silo's console.** Its root user and password are in Secret `frameflow-silo-root`, keys `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD`, read
the same way. Root can change anything. Whatever the setup Job sets, it sets again at the next sync: the bucket, its anonymous access of
none, its quota, the two users and their policies. Whatever else is changed there stays. To only look, sign in with the backup user's keys
from `frameflow-silo-backup` instead: that user can list and read the bucket and nothing more.

### Frameflow: processing limits and retention

| Limit | Value | Why |
|---|---|---|
| Videos at once | 1, `FRAMEFLOW_MAX_CONCURRENT_VIDEOS=1`. The rest wait in Hatchet's queue, for up to 12 hours, `FRAMEFLOW_SCHEDULE_TIMEOUT` | The node is Wayline's too |
| Renditions at once | 1, `FRAMEFLOW_WORKER_SLOTS=1` and `MAX_CONCURRENT_ENCODES=1`: 360p and 720p one after the other, the second waiting in Hatchet's queue and not inside its own timeout | |
| The worker's CPU and memory | Requests 500m and 2Gi, limits 3 CPU and 6Gi, and FFmpeg's `FFMPEG_THREADS=3` | The limit caps an encode, and Wayline's larger requests keep its share when the CPU is contended |
| Scratch | emptyDir `/scratch` of 8Gi, in an ephemeral-storage limit of 10Gi. Past either, the kubelet evicts the pod, and the Deployment starts another with an empty scratch | One disk holds everything on the node |
| Upload size | 500 MiB, `MAX_UPLOAD_BYTES=524288000` | One PUT must finish within Traefik's `readTimeout` of 900s, which every host shares, so a whole 500 MiB takes about 4.7 Mbit/s of upload |
| Upload URL | 16 minutes, `S3_PRESIGNED_UPLOAD_TTL_SECONDS=960` | A minute longer than the `readTimeout`, because the API takes no completion after it |
| Source | MP4, at least 1280x720 | The probe fails a smaller one, with `SOURCE_TOO_SMALL` |
| Task timeouts | validate 2m, probe 15m, each encode 30m, publish 15m, complete 2m. The probe, the encodes and publish retry twice | At the measured 2.06x, 30 minutes fits about 60 minutes of 720p at 30 fps. A longer source passes every size check and fails after three tries, up to 90 minutes holding the only worker |
| Stopping | `terminationGracePeriodSeconds: 600` | A stopping worker finishes its task first. Ten minutes covers an encode of about 20 minutes of 720p, at the 2.06x measured on 3 threads, and one cut off is retried |

The studio's page says up to 500 MB and checks that much in the browser, and the API holds the same limit. Past it, the API answers
`The declared upload exceeds the configured size limit.` The page's number is built into the web image, so a higher limit needs a new
web image as well as `MAX_UPLOAD_BYTES`. A file within the limit can still be cut off at 900s on a link under about 4.7 Mbit/s. That `readTimeout` is every host's, so raising it
again rolls Traefik, and it lets a slow client hold a connection for that long. `MAX_UPLOAD_BYTES` reaches the API only when it restarts, so a change to it goes
with a new `frameflow.bereket.dev/config-revision` on the pod template in `api.yaml`.

To raise the worker's memory, apply `capacity.yaml` with Terraform first, because past the LimitRange's `max` a new pod is refused and the
worker is on Recreate. To lower it, merge first, wait until the worker runs at the lower size, and apply `capacity.yaml` last: a quota below
what is running refuses every new pod, Silo's setup hook among them, and Frameflow's sync cannot finish. Lowering the bucket's quota below
what it holds refuses every write until videos are deleted.

What removes what:

- `frameflow-cleanup`, at 23 past each hour, expires each upload that was never completed, its object too, and deletes what is left in
  staging of each video that has finished or failed.
- Each task deletes its own scratch when it ends, on success or failure, and the worker clears what a killed one left when it starts.
- Hatchet drops runs after 7 days, `SERVER_LIMITS_DEFAULT_TENANT_RETENTION_PERIOD=168h`. Frameflow's own record of each video stays.
- Silo drops an incomplete multipart upload after 24 hours, at a sweep every 6, as this release does by default and as Docker showed.
- The bucket's quota is 18GiB, and past it Silo refuses every write, the worker's renditions among them. Silo enforces it from a count that
  lags the writes by minutes, so a bucket can pass it by what is written meanwhile. `FrameflowBucketNearQuota` warns at 80% and
  `FrameflowBucketFull` pages at 95%.
- Nothing deletes the owner's videos: sources, renditions and failed videos stay until deleted in the studio. When the bucket fills,
  delete some there. The quota is in the setup Job, the two rules and their test, and 18GiB is about as far as it goes as sized: it has to
  stay within Silo's 25Gi volume and the backup's 22Gi of scratch, which holds the whole bucket each night with the dumps beside it. At a full
  bucket the backup's 24Gi volume leaves about 6GiB for videos deleted in the last three months. Past that the repository outgrows what
  `capacity.yaml` counts, with no error and no alert short of the node's disk. Growing the bucket further grows all three, which counts about
  three times against the disk in `capacity.yaml`.

### Frameflow: backups and restore

Two copies, which survive different things:

| | The local copy, on the VPS | The off-server copy, on this machine |
|---|---|---|
| Where | restic repository `/srv/wayline/backups/frameflow/restic`, on the node's one disk | `.local/hosted/plane-prod/offsite-restic/frameflow` |
| Made by | CronJob `frameflow/plane-backup`, nightly at 02:47 UTC, or `make remote-backup` now | `make remote-pull-backups TARGET=plane-prod`, by hand: nothing schedules it, so nothing leaves the VPS while this machine is off |
| Kept | 7 daily, 4 weekly and 3 monthly snapshots | 90 days, by time |
| Survives | a bad deploy, a deleted video, a broken database | losing the VPS, or its disk |
| Does not survive | losing the node: it is on the disk it backs up | losing this machine with the VPS, unless the bundle and the copy are somewhere else too |

Each snapshot holds the SQLite file, copied with `VACUUM INTO` and checked with `integrity_check`, with its row counts; Hatchet's database,
from `pg_dump -Fc`, restored into a scratch database to count each table; every object in `frameflow-media` but the staging of videos in
flight, read as the backup user from one listing taken first, so what the worker publishes or the browser uploads while it copies waits for
the next night; a manifest, with the first 16 hex characters of the master keyset's sha256, so a restore can tell the dump's keysets from
others; and `SHA256SUMS`. restic seals it as `--host frameflow --tag wayline`. Until the API has made its database there is nothing to keep,
and the night says so and succeeds. What is not in it, and where it comes from instead:

- Silo's users and policies, which the setup Job makes again at every sync.
- Every secret, Hatchet's keysets among them, which are in Infisical, and Infisical's own nightly backup holds project `frameflow-prod`.
  The keysets and the owner access key are also in this machine's files and the recovery bundle.
- Hatchet's `/config`, which it writes at every start, and the worker's scratch, which no one needs.

```bash
make remote-backup TARGET=plane-prod CONFIRM=plane-prod ONLY=frameflow        # one now, from the CronJob, with its logs kept as evidence
make remote-restore-test TARGET=plane-prod CONFIRM=plane-prod ONLY=frameflow  # restore the newest into an isolated namespace and prove it
make remote-pull-backups TARGET=plane-prod                                     # the off-server copy, over the read-only SFTP user
make remote-backup-dest TARGET=plane-prod VERB=verify                          # restore the newest copy here, and check every hash
```

The restore test proves the files against their hashes, restores Hatchet's dump into an empty Postgres, reads the SQLite copy's recorded
check, finds every object its rows name, and compares the keyset's fingerprint with the live one. Frameflow is in the pull's list,
`BACKUP_NAMESPACES` in `scripts/hosted/lib-restic.sh`, since its first backup sealed (2026-11-08), so the pull and `VERB=verify` copy and
check it beside Plane's and Infisical's. A rebuilt VPS whose Frameflow has not sealed a backup yet has no repository there to pull.

**Restoring.** This puts Hatchet's database, Frameflow's database and the bucket back to one snapshot, so a video and its run agree.
Everything written since that snapshot is lost, so a person decides to do it. Objects uploaded since stay in the bucket, where nothing
names them and they do no harm. Hatchet's keysets stay as they are: the dump was written under them. It has not run on any cluster: the
Job below ran in Docker on this machine, with stand-ins for the pinned images, so read each step before running it.

1. If the cluster still runs, keep what is there now: `make remote-backup TARGET=plane-prod CONFIRM=plane-prod ONLY=frameflow`. If the
   live database is the problem, this fails at `integrity_check`. Go on regardless.
2. Pause auto-sync, root first or it puts the others back, then `frameflow` and `backup`, and wait until none has a sync running. A
   failing one never ends by itself: [End an operation](runbooks/argo-sync-stuck.md#end-an-operation) says how.
   ```bash
   for a in root frameflow backup; do kc -n argocd patch application "$a" --type merge -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}'; done
   ```
3. Stop what writes, and the nightly with it:
   ```bash
   kc -n frameflow scale deployment/frameflow-worker deployment/frameflow-api deployment/hatchet --replicas=0
   for c in frameflow-cleanup frameflow-reconcile plane-backup; do kc -n frameflow patch cronjob "$c" --type merge -p '{"spec":{"suspend":true}}'; done
   kc -n frameflow get pods
   ```
   Wait until no `api`, `worker`, `hatchet`, `maintenance` or `backup` pod runs. The worker may take up to its 600 seconds' grace to
   finish an encode. The web pods can stay: their calls to the API fail until step 6.
4. Restore, through Job `restore-frameflow` in `frameflow`. It carries `app.kubernetes.io/component: backup`, which lets it reach Hatchet's
   Postgres and Silo and nothing else, and it runs the images the nightly pins. Its steps, in order:
   - `unseal` restores the snapshot and checks every file against `SHA256SUMS`.
   - `keyset` stops unless the backup's fingerprint matches the master keyset Hatchet runs with.
   - `hatchet-db` drops and makes again Hatchet's database, with `dropdb` and not `pg_restore --clean`, so no table newer than the dump
     survives. It restores without `--single-transaction`, because Hatchet's partitions need more locks than one transaction holds, and
     checks each table's count against the backup's.
   - `sqlite` moves the live `app.db` aside with its `-wal` and `-shm`, so a stale write-ahead log can never meet the restored file, checks
     the copy, and puts it in place as the app's user, 1000.
   - `objects` copies the bucket back as the app user, which may write objects in its bucket and make no bucket, so rclone does not try.
     It deletes nothing.

   `SNAPSHOT` is `latest`, or a short ID: every seal prints its snapshot, in `kc -n frameflow logs job/<job> -c seal`, or in
   `.local/evidence-raw/backup-plane-prod-<stamp>.txt` for a run of `make remote-backup`. For this machine's copy, `restic -r
   .local/hosted/plane-prod/offsite-restic/frameflow --password-file .local/hosted/plane-prod/restic-password snapshots --host frameflow
   --tag wayline` lists them. To restore only part, leave out the other containers, but keep `unseal`, and keep `keyset` with `hatchet-db`.
   ```bash
   SNAPSHOT=latest
   STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
   BACKUP=gitops/clusters/plane-prod/platform/backup/frameflow.yaml
   image() { NAME="$1" .tools/bin/yq -r '.spec.jobTemplate.spec.template.spec | (.initContainers[], .containers[]) | select(.name == strenv(NAME)) | .image' "$BACKUP"; }
   RESTIC_IMAGE="$(image seal)" POSTGRES_IMAGE="$(image hatchet-postgres)" PYTHON_IMAGE="$(image sqlite)" RCLONE_IMAGE="$(image objects)"
   kc apply -f - <<YAML
   apiVersion: batch/v1
   kind: Job
   metadata: {name: restore-frameflow, namespace: frameflow}
   spec:
     backoffLimit: 0
     activeDeadlineSeconds: 14400
     template:
       metadata:
         labels: {app.kubernetes.io/name: restore-frameflow, app.kubernetes.io/component: backup}
       spec:
         restartPolicy: Never
         automountServiceAccountToken: false
         securityContext: {runAsNonRoot: true, runAsUser: 70, runAsGroup: 70, fsGroup: 70, seccompProfile: {type: RuntimeDefault}}
         volumes:
           - {name: backups, persistentVolumeClaim: {claimName: backups, readOnly: true}}
           - {name: restic-password, secret: {secretName: restic-password, defaultMode: 0440}}
           - {name: data, persistentVolumeClaim: {claimName: frameflow-data}}
           - {name: work, emptyDir: {sizeLimit: 22Gi}}
           - {name: tmp, emptyDir: {sizeLimit: 64Mi}}
         initContainers:
           - name: unseal
             image: $RESTIC_IMAGE
             securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
             resources: {requests: {cpu: 50m, memory: 128Mi}, limits: {cpu: "1", memory: 1Gi}}
             env:
               - {name: RESTIC_REPOSITORY, value: /backups/restic}
               - {name: RESTIC_PASSWORD_FILE, value: /run/restic/password}
               - {name: RESTIC_CACHE_DIR, value: /work/cache}
               - {name: TMPDIR, value: /work}
               - {name: HOME, value: /work}
             volumeMounts:
               - {name: backups, mountPath: /backups, readOnly: true}
               - {name: restic-password, mountPath: /run/restic, readOnly: true}
               - {name: work, mountPath: /work}
             command: [/bin/sh, -c]
             args:
               - |
                 set -eu
                 restic --no-lock restore $SNAPSHOT --host frameflow --tag wayline --target /work/restored --verify
                 cd /work/restored/work/backup
                 sha256sum -c SHA256SUMS > /dev/null
                 echo "unseal: every file matches its hash, in backup \$(grep '"id"' manifest.json)"
           - name: keyset
             image: $POSTGRES_IMAGE
             securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
             resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {cpu: 100m, memory: 64Mi}}
             env:
               - {name: KEYSET, valueFrom: {secretKeyRef: {name: hatchet-server, key: SERVER_ENCRYPTION_MASTER_KEYSET}}}
             volumeMounts:
               - {name: work, mountPath: /work}
             command: [/bin/sh, -c]
             args:
               - |
                 set -eu
                 live="\$(printf %s "\$KEYSET" | sha256sum | cut -c1-16)"
                 unset KEYSET
                 if ! grep -q "\"hatchet_master_keyset_fp\": \"\$live\"" /work/restored/work/backup/manifest.json; then
                   echo "keyset: this backup was not taken under the master keyset Hatchet runs with, so Hatchet could not read its database" >&2
                   exit 1
                 fi
                 echo "keyset: the backup and the running keyset are a pair"
           - name: hatchet-db
             image: $POSTGRES_IMAGE
             securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
             resources: {requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: "1", memory: 512Mi}}
             env:
               - {name: PGHOST, value: hatchet-postgres}
               - {name: PGUSER, valueFrom: {secretKeyRef: {name: hatchet-db, key: POSTGRES_USER}}}
               - {name: PGPASSWORD, valueFrom: {secretKeyRef: {name: hatchet-db, key: POSTGRES_PASSWORD}}}
               - {name: POSTGRES_DB, valueFrom: {secretKeyRef: {name: hatchet-db, key: POSTGRES_DB}}}
             volumeMounts:
               - {name: work, mountPath: /work}
               - {name: tmp, mountPath: /tmp}
             command: [/bin/sh, -c]
             args:
               - |
                 set -eu
                 B=/work/restored/work/backup/postgres
                 TRIES=0
                 until pg_isready -q -t 10 || [ "\$TRIES" -ge 30 ]; do TRIES=\$((TRIES + 1)); sleep 2; done
                 dropdb --maintenance-db=postgres --force --if-exists "\$POSTGRES_DB"
                 createdb --maintenance-db=postgres "\$POSTGRES_DB"
                 pg_restore --no-owner --no-privileges --exit-on-error -d "\$POSTGRES_DB" "\$B/hatchet.dump"
                 vacuumdb --analyze-only "\$POSTGRES_DB"
                 psql -XAt -F "\$(printf '\t')" -v ON_ERROR_STOP=1 -d "\$POSTGRES_DB" -f "\$B/rowcounts.sql" > /tmp/rowcounts.tsv
                 cmp -s /tmp/rowcounts.tsv "\$B/rowcounts.tsv" || { echo "hatchet-db: the restored row counts differ from the backup's" >&2; exit 1; }
                 echo "hatchet-db: restored, and its \$(wc -l < /tmp/rowcounts.tsv) tables count as the backup recorded"
           - name: sqlite
             image: $PYTHON_IMAGE
             securityContext: {runAsUser: 1000, runAsGroup: 1000, allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
             resources: {requests: {cpu: 25m, memory: 32Mi}, limits: {cpu: 500m, memory: 256Mi}}
             env:
               - {name: HOME, value: /tmp}
             volumeMounts:
               - {name: data, mountPath: /data}
               - {name: work, mountPath: /work}
               - {name: tmp, mountPath: /tmp}
             command: [/bin/sh, -c]
             args:
               - |
                 set -eu
                 old=/data/app.db.before-restore-$STAMP
                 for suffix in "" -wal -shm; do
                   if [ -e "/data/app.db\$suffix" ]; then mv "/data/app.db\$suffix" "\$old\$suffix"; fi
                 done
                 cp /work/restored/work/backup/sqlite/app.db /data/app.db.restoring
                 python3 -I -c 'import sqlite3, sys; r = sqlite3.connect(sys.argv[1]).execute("PRAGMA integrity_check").fetchall(); sys.exit(None if r == [("ok",)] else f"sqlite: {r[:5]}")' /data/app.db.restoring
                 mv /data/app.db.restoring /data/app.db
                 echo "sqlite: restored. The file it replaced, if any, is \$old"
         containers:
           - name: objects
             image: $RCLONE_IMAGE
             securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
             resources: {requests: {cpu: 25m, memory: 32Mi}, limits: {cpu: 500m, memory: 512Mi}}
             env:
               - {name: HOME, value: /tmp}
               - {name: RCLONE_CONFIG, value: /tmp/rclone.conf}
               - {name: RCLONE_CONFIG_DST_TYPE, value: s3}
               - {name: RCLONE_CONFIG_DST_PROVIDER, value: Minio}
               - {name: RCLONE_CONFIG_DST_ENDPOINT, value: "http://frameflow-silo:9000"}
               - {name: RCLONE_CONFIG_DST_NO_CHECK_BUCKET, value: "true"}
               - {name: RCLONE_CONFIG_DST_ACCESS_KEY_ID, valueFrom: {secretKeyRef: {name: frameflow-maintenance, key: S3_ACCESS_KEY_ID}}}
               - {name: RCLONE_CONFIG_DST_SECRET_ACCESS_KEY, valueFrom: {secretKeyRef: {name: frameflow-maintenance, key: S3_SECRET_ACCESS_KEY}}}
             volumeMounts:
               - {name: work, mountPath: /work}
               - {name: tmp, mountPath: /tmp}
             command: [/bin/sh, -c]
             args:
               - |
                 set -eu
                 rclone copy /work/restored/work/backup/objects dst:frameflow-media --checksum --transfers 4 --stats 0
                 rclone check /work/restored/work/backup/objects dst:frameflow-media --one-way --download
                 echo "objects: every object in the backup is in frameflow-media"
   YAML
   kc -n frameflow wait --for=condition=Complete job/restore-frameflow --timeout=4h
   kc -n frameflow logs job/restore-frameflow --all-containers --prefix
   ```
5. Delete the Job, and resume the CronJobs. Argo CD does not put `suspend` back, because the manifests never set it:
   ```bash
   kc -n frameflow delete job restore-frameflow
   for c in frameflow-cleanup frameflow-reconcile plane-backup; do kc -n frameflow patch cronjob "$c" --type merge -p '{"spec":{"suspend":false}}'; done
   ```
6. Put auto-sync back, `frameflow` and `backup` first and root last:
   `kc -n argocd patch application <name> --type json -p '[{"op":"remove","path":"/spec/syncPolicy/automated/enabled"}]'`. Argo CD puts
   the replicas back in its waves: Hatchet first, whose start runs any newer migrations, then the API and the worker. Then run
   `make remote-test TARGET=plane-prod CONFIRM=plane-prod ONLY=argo`, check that a video plays and that
   `curl -sS https://frameflow.bereket.dev/api/health/ready` answers, and look at the runs in `make remote-ui TARGET=plane-prod UI=hatchet`.
7. **The Hatchet token.** If the API or the worker now fails to authenticate to Hatchet, the token was minted after this snapshot, and the
   restored database does not know it: `make remote-frameflow-token TARGET=plane-prod CONFIRM=plane-prod`, and the operator restarts both.
8. **Runs in flight** when the snapshot was taken come back as running. Hatchet's timeouts fail them, and reconcile settles their videos
   within about 30 minutes. Upload again any that matter.
9. **A fresh baseline:** `make remote-backup TARGET=plane-prod CONFIRM=plane-prod ONLY=frameflow`. Once the restore is proved good, the
   files `/data/app.db.before-restore-<stamp>*` on the API's volume can go.

**After a lost VPS.** Rebuilding the node and the platform is the recovery bundle's part. The bootstrap makes
`/srv/wayline/backups/frameflow` and Secret `restic-password` from the bundle's password, and Infisical's restore brings back project
`frameflow-prod` with Hatchet's keysets in it, or the seed writes them again from `.local/hosted/plane-prod/frameflow/` or the bundle. Merge
or sync both releases and mint the token, as in the first deploy. Then, before the first night runs, put this machine's copy back as the
node's repository, moving aside any that a night has made there already, and restore in place from step 2. Not scripted, and not tried:

```bash
TARGET=plane-prod bash -c 'HOSTED_NO_CLUSTER=yes; source scripts/hosted/lib.sh
  COPYFILE_DISABLE=1 tar -C "$LOCAL_DIR/offsite-restic/frameflow" -cf - . |
    node_ssh "sudo -n install -d -m 750 -o 70 -g 70 $HOSTED_BACKUP_ROOT/frameflow/restic && sudo -n tar -xf - -C $HOSTED_BACKUP_ROOT/frameflow/restic && sudo -n chown -R 70:70 $HOSTED_BACKUP_ROOT/frameflow/restic && sudo -n chmod -R g+rX $HOSTED_BACKUP_ROOT/frameflow/restic"'
```

The copy is a full restic repository, under the same password and with the same snapshots, `--host frameflow --tag wayline`, because the
pull made it with `--copy-chunker-params`.

**If Infisical's dump is older than project `frameflow-prod`,** as one from before the first deploy's bootstrap is, its restored mode stops
before it refreshes anything of prod's: Terraform wants to make Frameflow's five resources, and restored mode makes nothing. Bring prod back
alone, then make Frameflow's again as a first bootstrap does, with Infisical forwarded as `make remote-ui TARGET=plane-prod UI=infisical`
does. Not tried:

```bash
WAYLINE_TARGET=plane-prod CONFIRM=plane-prod INFISICAL_RESTORED=yes HOSTED_RESTORE_WITHOUT_APPS=yes INFISICAL_URL=http://127.0.0.1:<port> scripts/infisical-bootstrap.sh
WAYLINE_TARGET=plane-prod CONFIRM=plane-prod INFISICAL_URL=http://127.0.0.1:<port> scripts/infisical-bootstrap.sh
```

`HOSTED_RESTORE_WITHOUT_APPS=yes` is refused without `INFISICAL_RESTORED=yes`, because anywhere else Terraform would destroy the project
it leaves out, and the first command refuses too if the dump holds `frameflow-prod` after all. The second makes the project, its reader and
its Kubernetes Auth, and seeds it: the keysets and the owner's sha256 from this machine's files, and a new value for everything else. So
mint the token again, and a Hatchet Postgres or a Silo that kept its volume needs the change [secrets](#frameflow-secrets) describes for its
password, or for its root keys.

**If the keysets are lost too,** Hatchet's dump cannot be used, and the `keyset` step stops. Remove the old keyset files, make new ones
with `make remote-frameflow-inputs TARGET=plane-prod`, and replace their values in Infisical by hand, because the seed never overwrites
one. Let Hatchet start on an empty database, restore only with `unseal`, `sqlite` and `objects`, and mint a new token. Every run's history
is gone. Videos keep their records and objects, and reconcile settles those that were processing.

### Frameflow: checking status

```bash
make remote-status TARGET=plane-prod      # the Applications, pods not ready, and the last nightly of each backup, Frameflow's too
kc -n argocd get application infisical-operator-frameflow frameflow \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision'
kc -n frameflow get deployment,statefulset,cronjob,pods,pvc
kc -n frameflow get infisicalstaticsecrets,ingressroute,certificate
curl -sS https://frameflow.bereket.dev/api/health/ready
```

Logs are in Grafana, Explore, Loki: `{namespace="frameflow"}`, and one component's with `{namespace="frameflow", pod=~"frameflow-worker-.*"}`.
Traefik's access log has each request to the host, the uploads among them:
`{namespace="traefik"} | json | RequestHost="frameflow.bereket.dev" | RequestMethod="PUT"`.

### Frameflow: troubleshooting

#### The worker does not register

Videos stay queued, the pod is not Ready, and `FrameflowWorkerUnavailable` fires after 15 minutes. Its health server starts only after it
has registered its workflows with Hatchet, so both its probes are refused until then.

```bash
kc -n frameflow get pods -l app.kubernetes.io/component=worker
kc -n frameflow logs deployment/frameflow-worker --tail=100
```

- **Hatchet is not Ready**: the next section.
- **`CreateContainerConfigError`**: a Secret it reads does not exist. Usually `hatchet-client-token`, because the token was never written:
  [below](#the-tokens-infisicalstaticsecret-is-degraded).
- **`UNAUTHENTICATED`, or a 401 or 403**: the token was revoked, or its row is not in Hatchet's database, after a restore from before it was
  minted. Mint another. A token minted under another `SERVER_URL` or another set of keysets fails the same way.
- **`connection refused` to `hatchet:7070` or `hatchet:8888`**, with Hatchet Ready: a NetworkPolicy, `worker`'s egress or `hatchet`'s
  ingress in `network-policies/frameflow.yaml`. `make remote-netpol TARGET=plane-prod CONFIRM=plane-prod FROM_NS=frameflow` runs the
  namespace's rows.
- **It exits with status 1 and restarts**: its link to Hatchet's dispatcher gave up reconnecting, and it exits so the kubelet starts it
  again. Look at Hatchet first.

#### Hatchet is not ready

`HatchetUnavailable` fires after 5 minutes, and new uploads fail to queue, with `The video could not be queued for processing.` Its
readiness is the engine's own, on 8733 `/ready`, which also fails when its database or its queue does. It is HTTP, because its gRPC port
has no health service to ask.

```bash
kc -n frameflow get pods -l app.kubernetes.io/component=hatchet
kc -n frameflow logs deployment/hatchet --all-containers --tail=100
kc -n frameflow describe pod -l app.kubernetes.io/component=hatchet | sed -n '/Events:/,$p'
```

By the log:

- **`wait-for-postgres: hatchet-postgres:5432 did not answer in 3 minutes`**: `hatchet-postgres-0` is not Ready, or a policy between them
  refuses.
- **`failed to validate SERVER_AUTH_COOKIE_SECRETS, secrets must be 16/24/32 bytes`**: `HATCHET_COOKIE_SECRETS` is not two keys of 32 hex
  characters with one space between: [secrets](#frameflow-secrets).
- **A time zone error**: Hatchet refuses a database whose time zone is not UTC, and its Postgres runs with `-c timezone=UTC`, so that
  argument is gone.
- **A migration fails**: the database must be Hatchet's own, and was empty when it first started. Nothing else may make its objects,
  extension `btree_gist` among them.
- **A keyset error**: the three keysets in Infisical are not a set, or one is damaged. Put back the ones in this machine's files, through
  the Infisical UI, and never make new ones for a database that exists.
- **OOMKilled**: its limit is 1536Mi, and Go keeps its heap to 90% of it. It used about 40Mi idle in Docker.

Every start runs the migrations and the seed, which do nothing on a database Hatchet made. On an empty one, the first start was ready in
3 seconds in Docker.

#### Silo's setup Job fails

`frameflow-silo-setup` is a Sync hook at wave 2, so a run that fails fails `frameflow`'s sync, and nothing in the later waves is applied
until one passes: on a first deploy, the web server and its route are not there yet. One run is up to four pods (`backoffLimit: 3`) within
900 seconds. The sync then retries without limit, 30 seconds and then up to 5 minutes apart, and each retry makes the Job again:
`BeforeHookCreation` deletes the one before, with its pods, so `kc -n frameflow logs job/frameflow-silo-setup` shows the current run's or
nothing. Loki keeps the earlier ones, `{namespace="frameflow", pod=~"frameflow-silo-setup-.*"}`, and each pod's last state says how it
ended:

```bash
kc -n frameflow get pods -l app.kubernetes.io/name=frameflow-silo-setup \
  -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,ENDED:.status.containerStatuses[0].state.terminated.reason'
kc -n frameflow get events --sort-by=.lastTimestamp | grep silo-setup
kc -n argocd get application frameflow -o jsonpath='{.status.operationState.message}{"\n"}'
```

- **`OOMKilled`**: `mc admin user add` encrypts its request with a key it derives by argon2id, 64 MiB at a time. At a 128Mi limit, two of
  the first three runs on the live Silo died there (2026-11-08). Raise `limits.memory` in `silo-setup.yaml`, within the namespace's
  LimitRange and quota.
- **`frameflow-silo:9000 did not answer ready in 2 minutes`**: Silo is not Ready, or restarted under the Job
  (`kc -n frameflow get pods -l app.kubernetes.io/component=s3`), or a policy refuses `s3-setup` its connection to Silo, in
  `network-policies/frameflow.yaml`: `make remote-netpol TARGET=plane-prod CONFIRM=plane-prod FROM_NS=frameflow`.
- **`mc` refuses root's keys**: those in `frameflow-silo-setup` are not the ones Silo started with, as after a change in Infisical before
  Silo restarted: [secrets](#frameflow-secrets).

A fix under `platform/frameflow/` lands at the next retry, up to 5 minutes later, with no step by hand, because a sync that fails reads the
newest commit each time it tries again. Root waits meanwhile: [Root waits on frameflow](#root-waits-on-frameflow).

#### The pages load, and nothing in them does

The API is down, and `FrameflowApiUnavailable` fires after 5 minutes. Its readiness, `/health/ready`, fails while SQLite or Silo does:

```bash
kc -n frameflow get pods -l app.kubernetes.io/component=api
kc -n frameflow logs deployment/frameflow-api --tail=50
```

- **`CreateContainerConfigError`**: `frameflow-app` or `hatchet-client-token` does not exist: `kc -n frameflow get infisicalstaticsecrets`.
- **It exits at start with what a setting lacks**, such as `OWNER_SESSION_SECRET with at least 32 characters`, or `OWNER_TOKEN_SHA256` not
  being 64 hex characters: the value in Infisical.
- **Not Ready, with `Readiness probe failed` and a 503 in its events**: SQLite or Silo fails it. Silo is down, or refuses the app user's
  keys, as after a change before the setup Job ran: [secrets](#frameflow-secrets).

#### ImagePullBackOff in frameflow

As for the sites, [ImagePullBackOff](#imagepullbackoff), with these differences:

- Frameflow's `ghcr-pull` comes from Infisical: `kc -n frameflow get secret ghcr-pull` must exist, and a new token goes into
  `GHCR_PULL_TOKEN` in project `frameflow-prod` too.
- Its own images are plain linux/amd64 manifests, so a `no match for platform` means a digest from somewhere else.
- hatchet-lite is public on GHCR. Silo, `mc` and Postgres come from Docker Hub, through `mirror.gcr.io` first, as
  `infrastructure/hosted/plane-prod/registries.yaml` sets, so a `429` or `toomanyrequests` is Docker Hub's limit for anonymous pulls, and it
  clears by itself.

#### Uploads fail

The studio shows what went wrong in its notice. Traefik's access log has the PUT and its status, and the browser's developer tools have
Silo's answer, which names its error in XML.

| The studio says | Why | What to do |
|---|---|---|
| `The declared upload exceeds the configured size limit.` (413, from the API) | The file is over 500 MiB | A smaller file. [Processing limits](#frameflow-processing-limits-and-retention) says what raising it takes |
| `Only MP4 uploads are supported.` (415) | Another container or extension | An MP4 |
| `Object storage rejected the upload.`, with Silo's 403 `SignatureDoesNotMatch` | The request's Host or Content-Type is not what the URL was signed for, or the app user's secret key in `frameflow-app` is not the one Silo holds | Traefik passes the Host on by default, so look for a change to the upload route. For the keys, sync `frameflow`, which runs the setup Job: [secrets](#frameflow-secrets) |
| The same, with 403 `AccessDenied` and an expired request | More than 16 minutes since the URL was made | Upload again |
| The same, with 403 `InvalidAccessKeyId` | Silo has no user by the app's access key, as after a new one in Infisical before the setup Job ran | Sync `frameflow` |
| The same, with a quota error | The bucket is full | [Retention](#frameflow-processing-limits-and-retention) |
| `Could not reach object storage.` | The connection broke: often Traefik's 900s `readTimeout`, which a whole 500 MiB PUT needs about 4.7 Mbit/s of upload to beat | A faster link or a smaller file. Traefik's log shows the PUT's `Duration` near 900s. If Traefik answers before it closes the connection, the page can say `Object storage rejected the upload.` instead, with no error from Silo. The video stays `uploading` until the hourly cleanup expires it |
| `The upload authorization expired.` (410) | The upload finished more than 16 minutes after its URL was made, and the API no longer takes it | Upload again |
| `The uploaded object size does not match the declared size.` (400) | The PUT stopped short, or the object Silo holds is not the size declared | Upload again |
| `Upload storage is unavailable.` (503) | The API could not sign the URL. Signing calls nothing, so this is the API's S3 settings, not Silo | `kc -n frameflow logs deployment/frameflow-api --tail=50` |
| `The video could not be queued for processing.` (503) | Hatchet refused the run | [Hatchet is not ready](#hatchet-is-not-ready), and the API's log for the token |

#### The token's InfisicalStaticSecret is Degraded

Before the token is written, `hatchet-client-token` finds no `HATCHET_CLIENT_TOKEN`, and reads Degraded. `frameflow`'s sync then fails at
that wave and retries, and the API, the worker and the CronJobs wait behind it. That is why the CR comes in release B, after the token.
`frameflow` reads Degraded meanwhile, and it is root's last wave, so root's operation does not finish either: its sync fails there and
tries again, up to 5 minutes apart, and `ArgoAppDegraded` pages. Each of root's tries reads the newest commit, so changes to Application
files still land. What holds root with no retry is in the next section, [Root waits on frameflow](#root-waits-on-frameflow).

```bash
kc -n frameflow get infisicalstaticsecret hatchet-client-token -o jsonpath='{.status.conditions}{"\n"}'
make remote-frameflow-token TARGET=plane-prod CONFIRM=plane-prod
```

The CR reads Healthy at the operator's next read, within 60 seconds, and the sync goes on at its next retry, up to 5 minutes later.

#### Root waits on frameflow

`frameflow` is root's last wave, and root's operation waits on it while it reads Progressing or Missing, with no retry and no timeout.
Root's check of it, in `values/argocd.yaml`, also reads a Healthy `frameflow` as Progressing while its own sync is still open, or while it
is not Synced. Until `frameflow` finishes or root's operation is ended, root applies no later change to an Application file, the
platform's charts and Wayline's own Application among them. What each child reads from its own path still syncs. A child that reads
Degraded fails root's sync instead, and each retry of root's reads the newest commit, so changes to Application files still land.

```bash
kc -n argocd get application root -o jsonpath='{.status.operationState.phase} {.status.operationState.message}{"\n"}'
kc -n argocd get application frameflow \
  -o jsonpath='{.status.health.status} {.status.sync.status} {.status.operationState.phase} {.status.operationState.message}{"\n"}'
```

What holds `frameflow` short of Degraded is one of two things:

- **A sync that fails and tries again** while what it made reads Healthy, as on a Sync hook that keeps failing,
  [above](#silos-setup-job-fails), or an object the apply refuses, past the quota for one, which stays Missing. Each try reads the newest
  commit, so a fix under `platform/frameflow/` lands by itself.
- **A sync that waits** on something that never turns Ready: a StatefulSet's pod, since a StatefulSet has no progress deadline, such as
  Silo's or Hatchet's Postgres's on a failed pull or a crash loop, or an Infisical CR that is never read. That sync never fails, so it never
  tries again. Publish the fix, then end `frameflow`'s operation, and its next automated sync takes the fix.

`ArgoSyncFailed` (15m) and `ArgoAppStuckProgressing` (30m) name `frameflow`, and `ArgoRootSyncStuck` names root at 60m. To land a change
to an Application file meanwhile, a revert among them, end root's operation too. Both as
[End an operation](runbooks/argo-sync-stuck.md#end-an-operation) says, which has not been tried on hosted production.

#### A video fails, or stays queued

- **Its state** is in the studio, with the reason when it failed, and in Hatchet's dashboard, under Runs: workflow `frameflow-phase-3`, with
  each task's attempts and errors.
- **`SOURCE_TOO_SMALL`**: the source is under 1280x720.
- **A task that times out** is cancelled: FFmpeg gets SIGTERM, then SIGKILL 5 seconds later, the task's scratch is deleted, and Hatchet
  retries it, twice for the probe, the encodes and publish. Cancelling a run in the dashboard takes the same path, and the video ends
  failed.
- **Queued for long**: one video is processed at a time, so it may be waiting its turn, for up to 12 hours. Otherwise the worker is not
  registered, above.
- **Stuck in queued or processing**, while Hatchet says the run ended: `frameflow-reconcile`, every 10 minutes, asks Hatchet about each
  video stuck for over 30 minutes and sets its state to match.
- **The worker was evicted**, for its scratch: `kc -n frameflow get events --field-selector reason=Evicted`. The task in it fails and is
  retried on the new pod.

A failed video's source stays in the bucket until it is deleted in the studio. To process it again, upload it again.

The two CronJobs try each run three times, and keep a Job that still failed, two hours for cleanup's and one for reconcile's, for its logs
and for `KubeJobFailed`: `kc -n frameflow get jobs`, then `kc -n frameflow logs job/<name>`. Each is safe to run again, and the next run
does what the failed one did not.
