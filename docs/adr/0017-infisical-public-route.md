# 0017. A public route for hosted production's Infisical, for its one admin

**Status:** Accepted, 2026-11-07, by the owner. Built and proved against the pinned Traefik and this Infisical's image in Docker. Deployed to hosted
production with release `f2bff57` at 19:21:48Z, where its tests from outside ran at 19:31Z, not published
([validation.md](../validation.md#hosted-infisicals-public-route)).

## Context

Hosted production's Infisical holds every production secret: Plane's database, broker and object-store credentials, its `SECRET_KEY`, and the
registry token. Until now it had no route. The admin reached it through the SSH tunnel with `make remote-ui TARGET=plane-prod UI=infisical`, and
this repository's rule was that no management UI gets a public route. Grafana became the first exception, behind its own login
([`grafana-route.yaml`](../../gitops/clusters/plane-prod/platform/monitoring-extras/shared/grafana-route.yaml)).

The owner asked for the same for Infisical, with admin access only, knowing what it holds: "we should also have similar setup for infisical just
like grafana and only with admin user access". That is the decision recorded here. This record does not argue it. It says how the route is made as
safe as it can be, and what is left.

What the evidence showed, at v0.167.6, read from its running server and its web client:

- The server registers 3746 API routes in 98 families. Its OpenAPI document leaves out 1186 of them, the sign-in, two-factor, sign-up and SCIM
  among them, so it could not be the list to work from. A throwaway copy logged every route as it registered it.
- Asked with no credential, 143 routes answer before any session is read, or check one only in their handler. Among them are every machine
  identity login, the bootstrap call and the admin sign-up, user sign-up, account recovery, public secret sharing, ACME, EST, SCEP, OCSP, CRLs,
  the SSO and OAuth flows, and callbacks for Slack, Teams, GitHub and AWS. Asked with the admin's own session, 40 refuse it by its kind, because
  they take only a machine's credential.
- The web client names 879 API paths in 81 of those families. It never calls a machine login, the OpenAPI document, SCIM's protocol endpoints,
  or `/api/v3/secrets`.
- This version registers its own rate limiter only for Infisical Cloud, so on this platform nothing limits a sign-in but what sits in front.
- Sign-up is closed in the database, and the bootstrap call closed it. `INVITE_ONLY_SIGNUP` is read by nothing in this version: with it set and
  sign-up opened in the database, a stranger was sent a sign-up code.
- With no SMTP, email two-factor cannot be chosen: the page says Unavailable and the API refuses. Any mail Infisical would send, a code, an unlock
  link or a sign-up code, is written to its log instead.
- Limiting a machine identity's token to the cluster's addresses with its trusted IPs is a paid feature in this version.

## Decision

A route at `https://infisical.bereket.dev`, in four parts that share no path,
[`route.yaml`](../../gitops/clusters/plane-prod/platform/infisical/route.yaml):

1. The sign-in, two-factor and password endpoints, under a limit per client address of a burst of 10 and one more every 6 seconds. That is
   no cap of 10 a minute: Traefik forgets an address after about 7 seconds with no request from it and starts it again with a full burst, so
   a client that waits about 8 seconds between bursts of 10 gets about 70 tries a minute.
2. The session endpoints, select-organization, token refresh, logout and the two-factor checks, under a wider limit of 30 a minute.
3. **An allow list** for the rest of the API: the families the web client calls, and in them a list of refusals for what takes a credential and
   no browser needs. A family a later version adds is refused until someone reads it. Any request carrying a machine's credential is refused too.
4. Pages, which are one `index.html` whatever the path: a clean path only, and a list of refusals for sign-up, account recovery, shared secrets and
   the SSO, LDAP and CLI logins.

An allow list for the API, because the evidence says the web client's surface is a closed set that can be read off its build, and the server's is
larger, partly undocumented, and grows with each release. A list of refusals alone would have to name every one of the 183 routes above and every
one a release adds, and fail open when it missed one. A secret store should fail closed. Pages get a list of refusals, because the page is the same
file for every path and holds no credential: what a refused page would show depends on API calls the route refuses anyway.

Around it:

- **Limits per client, by the connection's address.** `ipStrategy.depth: 0`, and no forwarded header is trusted on these entry points. One
  correct sign-in with an authenticator app makes 2 requests against the first limit and 4 against the second, measured through this route in
  Chrome. The values make the address Infisical records the same one: `TRUSTED_PROXY_CIDRS` is the pods' range, and without it any client could
  name its own with `CF-Connecting-IP`, which was shown through the pinned Traefik.
- **No machine's credential from outside.** Every machine login is refused by path. A machine identity's access token, a service token or an API
  key is refused by its header on every call of the API route, so the bootstrap's 90-day instance admin token, the operator's tokens and any token
  made later work only inside the cluster.
- **Exact words in policy.** [`policy/hosted.rego`](../../policy/hosted.rego) allows these four routes and two limits in their words and no others,
  and keeps Argo CD, Prometheus, Alertmanager and the storage consoles refused. Any container whose image is of repository
  `infisical/infisical`, under any registry, must run the one reference the route was read from, digest and all, until the route has been read
  again for another, and must set the server's four values for the route. The same server published under another repository name meets
  neither rule, and only the list of hosted images, [`policy/hosted-images.txt`](../../policy/hosted-images.txt), makes that change a diff a
  person reads. Policy also holds the four Probes and their blackbox modules, and every NetworkPolicy in namespace infisical, egress-only ones
  too. [`policy/hosted_combined.rego`](../../policy/hosted_combined.rego) wants both limits and every Probe beside any route on the host
  [`target.yaml`](../../infrastructure/hosted/plane-prod/target.yaml) gives Infisical. In each container of the pods the Probes' Service
  selects, it wants the blackbox exporter's own image and entrypoint with one `--config.file`, that file from one ConfigMap mounted whole or by
  items at its directory, no other mount at or under that directory, a subPath one included, and those modules in that file exactly as
  `policy/hosted.rego` writes them. [`policy/hosted_tree.rego`](../../policy/hosted_tree.rego) refuses an object in the hosted tree that states
  no namespace.
- **Proved against the pinned Traefik.** [`tests/routes/infisical-public-route.sh`](../../tests/routes/infisical-public-route.sh) starts the
  Traefik image and flags hosted production pins, in Docker, with `route.yaml`, and asks every anonymous and machine route, and the named ones in
  49 spellings each: trailing and doubled slashes, case, percent-encoding once and twice, encoded slashes and dots, dot segments, semicolons,
  backslashes, NUL and the rest, over HTTP/1.1 and HTTP/2. With an echo server behind it, which sees each request as Traefik forwards it, it
  shows what Traefik lets through, not that nothing refused arrives. Traefik answers most refused spellings itself, and 55 arrive in another
  shape, 52 over HTTP/1.1 and 3 over HTTP/2, the 3 in shapes three of the 52 arrive in: an encoded slash or backslash, a doubly encoded slash
  or dot, an overlong encoded dot, a NUL or a semicolon inside one segment. Those pass on the test's own model of Fastify's router, which does
  not read them as the path refused. Routed by hand, none of the 52 reaches a refused route. That ran on a separate copy of the published
  find-my-way 9.9.0, because the extract of this image holds only its `node_modules/find-my-way/package.json`, which names 9.9.0. With a
  real Infisical of this version behind it, the test shows what Infisical answers, and cannot see what Traefik forwarded, so neither run
  stands in for the other. The verdict that run now uses has not run against the image, only against a
  stand-in that routes with the same model. [`docs/infisical.md`](../infisical.md#the-public-route) says what each run showed. Given a throwaway
  copy nobody has claimed, named by its container and asked at the port it publishes on 127.0.0.1, it also claims that copy and sends the real
  tokens it hands out through the route, so a version whose tokens begin another way fails it. It refuses any other target, and this mode too
  has run only against a stand-in.
- **Only Traefik, and only to the server.** NetworkPolicy lets Traefik reach Infisical's server on 8080, and cert-manager's solver there on 8089
  while a challenge runs, and nothing else in that namespace. Its Postgres and Redis stay denied to it, and the matrix has rows for both. The
  server's pod holds no Kubernetes token.
- **Only admin.** Sign-up is closed in the database. A probe through the route reads the config any sign-in page reads, and
  `InfisicalOpenToClaim` is critical at the first reading that is not claimed and closed. `scripts/hosted/edge.sh open` refuses while Infisical
  reads otherwise, as it already refuses for Plane, and `scripts/hosted/bootstrap.sh` will not let Argo CD deploy the route with 443 open to
  everyone before step 6 has made the admin. The route refuses the bootstrap and sign-up calls, and none of the above leans on that.
- **Two-factor with an authenticator app**, which the owner turns on, with the steps and the way back in
  [`scripts/hosted/README.md`](../../scripts/hosted/README.md#two-factor-for-infisicals-admin).

## Alternatives considered

| Alternative | Why not |
|---|---|
| Keep it behind the tunnel | The owner decided otherwise. The tunnel still works, and is the way in when the route is down or the limit is in the way |
| A list of refusals for the API as well | It fails open on every login or protocol a release adds, and this version alone has 183 routes that take no session of a person's |
| An allow list of every path the client names | 879 paths, most with parameters. A change to one page would break it, and the family list with its refusals is as tight where it matters, at the routes that take no session |
| An allow list of client addresses | The owner's address is not fixed, and that is what the tunnel is for |
| Basic auth or a forward-auth service in front | A second password in the same browser, with no two-factor of its own, and a new service to run and patch. Infisical's own sign-in has two-factor |
| Trusted IPs on each machine identity | A paid feature in this version. The route's refusal of a machine's credential does the same for the public host |
| `INVITE_ONLY_SIGNUP=true` | This version ignores it, as tested. The database decides |

## Consequences

**What is left.** Anyone on the internet can reach the sign-in, the two-factor step, the token refresh and the config a sign-in page reads, and
guess at the password at about 70 tries a minute per address, waiting about 8 seconds between bursts of 10, as many addresses as they have.
Measured against the pinned Traefik v3.7.17 in Docker, Traefik forgets an idle address after about 1 + 60/n seconds, for a limit of n a minute,
and starts it again with a full bucket: 10 tries got 200, a try 5 s later got 429, and a burst 9 s later got 10 more 200s. Infisical asks for no
captcha without `CAPTCHA_SECRET`, which is not set. The password is 48 random hex characters, and two-factor stands behind it, so guessing is not
the threat. These are:

- **A flaw in what stays reachable.** The sign-in, two-factor, session and secret endpoints, and the web client's own code, run for anyone. A bug
  in them is now reachable from the internet, where before it needed the SSH key. Watch Infisical's security releases, and read the route again at
  each upgrade, which policy forces.
- **A stolen session works from anywhere.** A person's session is accepted at every call a browser makes, and the route cannot tell a browser from a
  script that holds one. A phished password and code, or a session lifted from the laptop's browser, now work from anywhere, where before they
  also needed the tunnel.
- **Locks a person with the password can cause.** Wrong codes lock the account, for up to an hour and then until it is unlocked, and need the
  password first. Wrong passwords move no lock, so a stranger can cause none.
- **Relaxed SSRF protection.** `ALLOW_INTERNAL_IP_CONNECTIONS=true` stays, for Kubernetes token review. The server's egress reaches only its
  database, Redis, the API server and kube-dns on 53, so whatever a caller could get it to dial, nothing else answers. A name it looks up does
  leave the node, as a query CoreDNS forwards.
- **Mail in the log.** With no SMTP, any mail Infisical would send is written to its log, and Loki keeps that log for 7 days behind Grafana's public
  login. With an authenticator app no code is mailed. The flows a stranger could start that would mail one, sign-up and account recovery, are
  refused. The unlock link, which carries a token good once, is there as well.
- **What strangers write to the log.** Infisical logs every request's URL with its query string, and the email of each sign-in to an account
  it does not have, which anyone can send to the sign-in, as `scripts/hosted/test-hosted.sh` itself does. Loki keeps those for 7 days too, so
  whoever reads Loki reads them, and a stranger chooses some of that text. Dropping those lines or their query strings in Alloy would end it,
  at the cost of the request log.
- **Traefik holds Infisical's Secrets in memory.** Traefik's token reads Secrets in every namespace, and with namespace infisical among those it
  watches for the route and the solver's Ingress, its providers keep a copy of each Secret there that Helm did not make: `infisical-secrets`,
  which holds the root keys, `infisical-db`, `infisical-redis` and `restic-password`. Code run in Traefik, the pod on the internet, could read
  them through the API anyway. The copy adds a bug that only reads memory. Keeping the route, its limits and its Certificate in a namespace
  that holds only the TLS key would end it, and needs Traefik to allow every route a Service in another namespace. That is the owner's choice.
- **Public secret sharing is off in the server**, by `DISABLE_PUBLIC_SECRET_SHARING`, and the route refuses it too. A super admin can turn it
  back on in the Server Console's environment overrides, which nothing in Git can see.
- **The instance's settings are public.** `/api/v1/admin/config` answers anyone with them, as every sign-in page reads them, so whatever is set
  there later, a sign-in page's text or an allowed domain, is readable on the public host. Its claim probe watches the two fields that matter.

What bounds it: one admin, sign-up closed and watched, two-factor, a limit per address, the route's allow list, no machine's credential from
outside, policy holding the route's words, and the tunnel as the way in when something goes wrong.

**Costs.** The Secret Sharing pages, member invitations, SSO, account recovery by email and the CLI's browser login do not work through the public
route. A machine's token works only inside the cluster, so a script that wants Infisical from outside goes through the tunnel. An Infisical upgrade
waits until someone has read its new routes and web client, run the route test, and changed the version in policy. Once the admin has
two-factor on, no script can replace the 90-day admin token with the password, because the sign-in stops at the code: a person adds the next
one in the UI before it ends, which `make remote-status TARGET=plane-prod` shows, as `scripts/hosted/README.md`, section Locked out of
Infisical, says. Safari keeps no session through
the tunnel once cookies are Secure, so the tunnel is for Chrome or Firefox.
