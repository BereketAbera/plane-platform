# 0006. Traefik rather than ingress-nginx, and no Gateway API yet

**Status:** Accepted, 2026-11-04.

## Context

Plane needs host and path routing, with a body limit above `FILE_SIZE_LIMIT`, and a WebSocket path for `/live`.

`kubernetes/ingress-nginx` is archived (`archived=true`, last push 2026-03-23, research, 2026-11-04). Kubernetes announced its [retirement](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/). So it gets no further patches.

The `plane-ce` chart has first-class Traefik support. With `ingress.ingressClass: traefik` it renders an `IngressRoute` and a body-limit `Middleware`. It has no `HTTPRoute` templates.

## Decision

Traefik v3.7.17, chart 42.3.0, deployed by Argo CD at wave -9, using the chart's `IngressRoute` objects.

- The `kubernetesCRD` provider is on and `kubernetesIngress` is off. Every route on this platform is an `IngressRoute`.
- NodePorts 30080 and 30443, which kind maps to loopback only. No `hostPort`, so PSA `baseline` is satisfied.
- `externalTrafficPolicy: Local`, so kube-proxy does not rewrite the client source. On this host the source is still Docker's, not the browser's.
- No TLS locally. The Plane overlay names `entryPoints: [web]` explicitly, because the chart's derived default flips to `websecure` as soon as TLS values appear.
- No Gateway API in Pass 1.

## Alternatives considered

| Option | Plane chart fit | Why not |
|---|---|---|
| ingress-nginx | Rendered through plain `Ingress` | Archived, no patches |
| Traefik with plain `Ingress` | Rendered only if the class name does not start with `traefik` | Needs a contrived class name, and drops the body limit |
| Gateway API (Traefik, Envoy Gateway or others) | No `HTTPRoute` in the chart | Would mean hand-maintaining all 8 routes and drifting from upstream. Envoy Gateway also adds a controller and a proxy. CRDs must be installed separately |

Gateway API is a reasonable later move, not a rejected one. Traefik v3.7.17 implements Standard channel v1.6.3 (research, 2026-11-04). It becomes worthwhile when the chart ships `HTTPRoute`, or when this platform is willing to own those routes.

## Consequences

- `IngressRoute` and `Middleware` are Traefik-specific. Moving to another controller means rewriting routes. Staying on the chart's templates keeps upstream's route changes visible at each upgrade.
- Traefik's CRDs arrive with its own Application, so nothing rendered earlier can use them. That is why the Argo CD route is synced from `gitops/bootstrap/argocd-route` by the root Application rather than shipped in Argo CD's values, and why Traefik's metrics use a plain Service rather than the chart's `serviceMonitor`.
- The overlay patches the body limit, because Helm renders `2.097152e+07` and the CRD field is an integer. It sets `maxRequestBodyBytes: 20971520`.
- The overlay adds a trailing-slash redirect, with `test` operations that make a reordered chart fail the render.
- Every chart route, including `/live`, goes through the `buffering` middleware, and WebSocket hijack passes through it. On 2026-11-05, on the branded images, text typed in one real browser tab showed in a second within 2 seconds ([live-dev](../evidence/branding/live-dev/README.md)). On 2026-11-04 the smoke's own client held two connections idle for 330s, with pings answered and an update getting through after ([plane-dev-smoke-soak-1.txt](../evidence/runs/plane-dev-smoke-soak-1.txt)). On 2026-11-05 two real Chromium tabs of one session still carried edits within 2 seconds, 5m54s after the page opened, with k6 running on dev, and text typed during a restart of the live pod reached the other tab after reconnect and survived a reload ([RT-2b-RT-3-20261105T073208Z.txt](../evidence/runs/RT-2b-RT-3-20261105T073208Z.txt)). That is two tabs in dev, one restart and one browser engine.
- CoreDNS rewrites `plane.dev.localhost` and `plane.prod-sim.localhost` to Traefik's Service, because the Plane API dials its own public host for `copy_object` and OAuth avatars. `copy_object` works through it with a valid signature, in step `asset-duplicate` in both environments. Traefik's PUT counter moved with each run, and a worker, with no policy route, times out ([plane-dev-copy-object-path-1.txt](../evidence/runs/plane-dev-copy-object-path-1.txt)).
- **Traefik routes by Host header, and it is shared.** The dev api can reach Traefik, so it can request prod-sim's public hostname. NetworkPolicy cannot see this. It is one concrete way in which namespace separation falls short of independent clusters. See [0010](0010-networkpolicy-under-kindnet.md).
- `*.localhost` resolves to loopback on this Mac without `/etc/hosts`. Chromium uses it, and cookies carry no `Domain` ([live-dev](../evidence/branding/live-dev/README.md), [plane-dev-cookies-1.txt](../evidence/runs/plane-dev-cookies-1.txt)). One Chromium profile with a tab on each host held a dev session, and the prod-sim host answered it with 401 ([AUTH-4-20261105T062750Z.txt](../evidence/runs/AUTH-4-20261105T062750Z.txt)). A session on each host at once, Safari and Firefox: Not tested in Pass 1.
- Pass 2 intends to terminate TLS at Cloudflare and the origin. Nothing for that is configured here.

## What we found when we ran it

Added 2026-11-05.

- **The source Traefik sees.** `172.24.0.1`, the kind gateway, for every browser on the host ([traefik-nodeport-source-1.txt](../evidence/runs/traefik-nodeport-source-1.txt)). `externalTrafficPolicy: Local` does not change that here, because Docker's own publishing sits in front of it.
- **Sharing one Traefik reached further than this record said.** Besides the other Plane host, an api pod could read Prometheus and Alertmanager, which have no login ([routes-before-1.txt](../evidence/runs/routes-before-1.txt)). So all five internal UIs now carry Middleware `node-network-only`, an allow list on the socket address, and a pod gets 403 ([routes-after-3.txt](../evidence/runs/routes-after-3.txt)). Reaching the other Plane host stays possible, as this record says.
- **A rollout dropped requests behind Traefik.** It could still send a request to a pod that had got SIGTERM, so `2aefba1` added a 5s `preStop` sleep: 10 failed of 2,757 samples before, and 0 of 5,902 after ([before](../evidence/runs/plane-dev-rollout-availability-1.txt), [after](../evidence/runs/plane-dev-rollout-availability-2.txt)). How long Traefik takes to react was not measured.
