# 0006. Traefik rather than ingress-nginx, and no Gateway API yet

**Status:** Accepted, 2026-11-04. Runtime validation pending where marked.

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
- Every chart route, including `/live`, goes through the `buffering` middleware. The source reading suggests WebSocket hijack passes through it, but that has not been run. [[VERIFY: a WebSocket on /live stays connected through the buffering middleware, with two tabs editing one page]]
- CoreDNS rewrites `plane.dev.localhost` and `plane.prod-sim.localhost` to Traefik's Service, because the Plane API dials its own public host for `copy_object` and OAuth avatars. [[VERIFY: copy_object from the api pod succeeds through the CoreDNS rewrite with a valid signature]]
- **Traefik routes by Host header, and it is shared.** The dev api can reach Traefik, so it can request prod-sim's public hostname. NetworkPolicy cannot see this. It is one concrete way in which namespace separation falls short of independent clusters. See [0010](0010-networkpolicy-under-kindnet.md).
- `*.localhost` resolves to loopback on this Mac without `/etc/hosts`. [[VERIFY: Safari, Chrome and Firefox each resolve *.localhost and keep cookies separate between the two Plane hosts]]
- Pass 2 intends to terminate TLS at Cloudflare and the origin. Nothing for that is configured here.
