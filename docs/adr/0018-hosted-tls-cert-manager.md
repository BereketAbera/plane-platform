# 0018. TLS on hosted production: cert-manager and Let's Encrypt HTTP-01, terminated by Traefik on the node

**Status:** Accepted, 2026-11-07. Supersedes in part [0015](0015-exclusions.md): its exclusion of cert-manager no longer holds for hosted
production. It still holds for the local platform, and 0015's other three exclusions hold for all three environments, as below.

## Context

[0015](0015-exclusions.md) left cert-manager out of Pass 1, because nothing terminated TLS on kind, and expected Pass 2 to terminate TLS at a
Cloudflare edge, which might have kept cert-manager optional. It named the condition that would reverse that: origin certificates managed
in the cluster.

Pass 2 went elsewhere. Hosted production, `plane-prod`, is one K3s v1.36.6+k3s1 node on a Contabo Cloud VPS 12, instance 203733427, at
5.253.234.127 ([node](../evidence/runs/hosted-node-20261106T225936Z.txt), [access and DNS](../evidence/runs/hosted-access-dns-20261106T212722Z.txt)).
The `bereket.dev` zone stays at Vercel. Terraform's [`prod-host`](../../infrastructure/terraform/environments/prod-host/README.md) root holds one
A record for each public name, `wayline`, `grafana` and `infisical`, each pointing straight at the node. No Cloudflare account, zone or proxy
is part of this deployment, so nothing stands between a browser and the node, and the node has to present the certificate itself. The move
to Hetzner and Cloudflare described in [`PASS2_HANDOFF.md`](../../PASS2_HANDOFF.md) and [future Hetzner](../future-hetzner.md) did not happen.

Plane needs HTTPS on a public host. The prod overlay's CORS origins are https only, which is what makes Plane's session and CSRF cookies
Secure, and [`policy/hosted.rego`](../../policy/hosted.rego) refuses an http `WEB_URL` or origin. The zone's CAA records allow Let's Encrypt,
among others ([access and DNS](../evidence/runs/hosted-access-dns-20261106T212722Z.txt)).

## Decision

**cert-manager owns every certificate on hosted production, from Let's Encrypt over HTTP-01, and Traefik on the node terminates TLS.**

- cert-manager v1.21.3, from `quay.io/jetstack/charts`, deployed by Argo CD at wave -8 with each image by digest
  ([Application](../../gitops/clusters/plane-prod/applications/cert-manager.yaml), [values](../../gitops/clusters/plane-prod/values/cert-manager.yaml)).
  Its CRDs are kept if the release goes, and the Application has no finalizer.
- Two ClusterIssuers, `letsencrypt-staging` and `letsencrypt-production`, with an HTTP-01 solver through Traefik's Ingress provider, class
  `traefik`, on entrypoint `web`, behind a ClusterIP Service so no NodePort opens ([issuers](../../gitops/clusters/plane-prod/platform/certificates/clusterissuers.yaml)).
- Three Certificates, each in the namespace of the route that names it: `wayline-tls` in `plane-prod`, `grafana-tls` in `monitoring` and
  `infisical-tls` in `infisical`. ECDSA P-256, a new key at each renewal, and no `renewBefore`, so cert-manager renews at two thirds of the
  lifetime ([certificates](../../gitops/clusters/plane-prod/platform/certificates/)). Each tells Argo CD to ignore its health, so an order
  that fails holds no later wave.
- Traefik 42.3.0 binds hostPorts 80 and 443 on the node, with TLS 1.2 at least and `sniStrict`. Entrypoint `web` redirects to `websecure`,
  with `allowACMEByPass` so the challenge path is not redirected. Traefik has no ACME resolver, and the Plane chart's `createIssuer` and
  `generateCerts` stay off ([values](../../gitops/clusters/plane-prod/values/traefik.yaml)).
- K3s's `coredns-custom` rewrites the three names to Traefik's Service, so cert-manager's self-check, the probes and Plane's calls to its own
  host stay inside the cluster ([`environments/prod`](../../infrastructure/terraform/environments/prod/main.tf)).
- The firewall opens 80 in every stage after `closed`, and `scripts/hosted/bootstrap.sh` opens it before Argo CD starts, because an order
  that meets a closed port 80 waits an hour or more for its next try ([`edge.sh`](../../scripts/hosted/edge.sh)).
- CI holds this: [`policy/hosted.rego`](../../policy/hosted.rego) requires each route's `tls` to name only its own Secret, which leaves no
  room for a resolver, and refuses an Ingress in Git, since cert-manager makes the one a challenge needs.
- Alerts in [`rules-hosted.yaml`](../../gitops/clusters/plane-prod/platform/monitoring-extras/shared/rules-hosted.yaml): `CertificateExpiringSoon`
  under 21 days, `CertificateNotReady` for 30 minutes, `ServedCertificateExpiringSoon` under 14 days on what a probe is served, and
  `CertificateNotWatched` when cert-manager reports nothing for one of the three.

**Dev and prod-sim do not change.** kind still terminates nothing, and its traffic stays plain HTTP on loopback, as 0015 says.

**What stays of 0015, and why.**

| Exclusion | On hosted production | Why it still holds |
|---|---|---|
| Bitnami | Nothing from Bitnami. Hosted Infisical's Postgres and Redis are this repository's own manifests on upstream images by digest ([postgres.yaml](../../gitops/clusters/plane-prod/platform/infisical/postgres.yaml), [redis.yaml](../../gitops/clusters/plane-prod/platform/infisical/redis.yaml)) | 0015's reason, from its research on 2026-11-04: the free images are gone or frozen. CI enforces it here too, because `scripts/ci/validate-manifests.sh` runs `policy/plane.rego`, which refuses any Bitnami reference, on the hosted render, the hosted tree and the hosted charts |
| CloudNativePG | Not used. Plane's Postgres is the chart's single StatefulSet, dumped each night and before each migration, and sealed with restic | Hosted production is one node too, so failover still has nowhere to go, and no recovery target has been stated. 0015's condition, a multi-node cluster and a stated recovery target, is not met |
| Soft Serve | Not used. Hosted Argo CD reads branch `deploy/plane-prod` on GitHub, over SSH with a read-only deploy key, and no Git server runs in the cluster | It is archived upstream, as 0015 says, and hosted production needs no local Git remote: [0011](0011-local-git-daemon-as-argo-source.md)'s git daemon serves kind alone |

## Alternatives considered

| Option | What it would give | Why not here |
|---|---|---|
| A Cloudflare proxy in front, terminating TLS at its edge | Edge certificates, and the node's address hidden | No Cloudflare account or zone is part of this deployment: DNS is at Vercel, and the planned move did not happen. Traefik would also need to trust the proxy's forwarded address, or every client would share one address, and the Grafana and Infisical login limits count per address |
| Traefik's own ACME resolver | One component fewer | A second certificate owner, its store in a pod that has no volume here, and nothing for the cert-manager alerts to read |
| DNS-01 through the Vercel zone | Wildcards, and no need for port 80 | A credential that can write `bereket.dev`'s records would live in the cluster. Today nothing there can change the zone: its credentials stay on the Mac, and reach `prod-host` from the environment. cert-manager would also need a webhook for Vercel, one more component |
| Self-signed certificates, or a private CA | No outside dependency | Every browser would warn, and a stranger's browser would have nothing to trust |

## Consequences

- **Port 80 has to answer for every order and renewal.** A closed firewall makes an order fail, and cert-manager's next try is an hour away,
  doubling each time up to 32 hours, with no retry when the firewall opens. [`scripts/hosted/README.md`](../../scripts/hosted/README.md), section The first
  certificate, says how to try again at once. That reset is read from cert-manager's code and has not run on this cluster.
- **Each name's A record has to exist before Argo CD first sees its Certificate.** The zone's wildcard answers Vercel's address for any name
  without a record of its own, so an order made before the record fails and backs off.
- **Rate limits.** Let's Encrypt's production issuer allows 5 certificates a week for one name, as `wayline-tls.yaml` notes. So
  `wayline-tls` was ordered from staging first, and moved to production in `1c2638a` once staging had issued through the same path.
- **Shorter lifetimes are coming.** Let's Encrypt moves to 64 days in February 2027 and to 45 days in February 2028.
  `CertificateExpiringSoon`'s 21 days must come down before each, as its rule's comment says.
- **Solver pods count against each namespace's quota.** In `infisical` the quota fits one of the server's rollout, the nightly backup and the
  solver at a time ([`capacity.yaml`](../../infrastructure/hosted/plane-prod/capacity.yaml)), so a renewal that meets one of the others
  waits for it.
- **Traefik is one pod on hostPorts**, so each Traefik rollout is a brief outage of all three names.
- **IPv4 only.** There is no AAAA record, so Traefik serves IPv4 alone.
- **TLS is still never exercised on kind or prod-sim.** A certificate problem shows first on hosted production, as 0015 predicted for
  Pass 2.
- **What would reverse this:** a proxy or CDN in front that terminates TLS, or a need for names HTTP-01 cannot cover, such as a wildcard.

## What we found when we ran it

Added 2026-11-07.

- **`wayline-tls` serves.** The hosted smoke's `tls-certificate` step read TLSv1.3, issued by Let's Encrypt, 89 days left, valid for
  `wayline.bereket.dev`, at 06:41Z and 06:45Z, and the second run read PASS on all 21 steps (`smoke-plane-prod-20261107T064131Z.json` and
  `smoke-plane-prod-20261107T064551Z.json`, not published yet).
- **A new Certificate paged before its first issue.** cert-manager reports an expiry of 0 for a Certificate with no certificate yet, so
  `grafana-tls`'s first order read as long expired and `CertificateExpiringSoon` paged at 07:08Z, within a minute of the Certificate being
  created. `ec76d65` leaves a zero expiry to `CertificateNotReady`, with a promtool test, as the rule's comment records. It went out with
  `infisical-tls`, whose first order began before Prometheus had loaded it, so the rule fired once more, at 19:23Z, by Prometheus's own
  record read at 20:30Z. Neither page is in `docs/evidence`.
- **`infisical-tls` serves.** It was ordered once its route was released. The outside run of
  `make remote-test TARGET=plane-prod CONFIRM=plane-prod ONLY="outside secrets routes"` at 19:31Z read a publicly trusted certificate for
  `infisical.bereket.dev` with 89 days left, issued by Let's Encrypt, and at 19:47:29Z the Certificate read Ready from
  `letsencrypt-production` (`test-hosted-20261107T193135Z.txt` and `hosted-routes-20261107T194729Z.txt`, not published yet).
