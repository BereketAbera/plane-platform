# 0017. A public route for hosted production's Infisical, for its one admin

**Status:** Accepted, 2026-11-07, by the owner. Built and proved against the pinned Traefik and this Infisical's image in Docker. Not yet deployed
to hosted production.

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

1. The sign-in, two-factor and password endpoints, under a limit of 10 a minute per client address.
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
  keeps Argo CD, Prometheus, Alertmanager and the storage consoles refused, and refuses an Infisical image of another version until the route has
  been read again for it.
- **Proved against the pinned Traefik.** [`tests/routes/infisical-public-route.sh`](../../tests/routes/infisical-public-route.sh) starts the
  Traefik image and flags hosted production pins, in Docker, with `route.yaml`, and asks every anonymous and machine route, and the named ones in
  49 spellings each: trailing and doubled slashes, case, percent-encoding once and twice, encoded slashes and dots, dot segments, semicolons,
  backslashes, NUL and the rest, over HTTP/1.1 and HTTP/2. Once with an echo server behind it, which shows what arrives, and once with a real
  Infisical of this version, which shows what its router does with it. Nothing refused reached a handler of its own.
- **Only Traefik, and only to the server.** NetworkPolicy lets Traefik reach Infisical's port 8080 and nothing else in that namespace. Its
  Postgres and Redis stay denied to it, and the matrix has rows for both. The server's pod holds no Kubernetes token.
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
guess at the password at 10 tries a minute per address, as many addresses as they have. The password is 48 random hex characters, so guessing is
not the threat. These are:

- **A flaw in what stays reachable.** The sign-in, two-factor, session and secret endpoints, and the web client's own code, run for anyone. A bug
  in them is now reachable from the internet, where before it needed the SSH key. Watch Infisical's security releases, and read the route again at
  each upgrade, which policy forces.
- **A stolen session works from anywhere.** A person's session is accepted at every call a browser makes, and the route cannot tell a browser from a
  script that holds one. A phished password and code, or a session lifted from the laptop's browser, now work from anywhere, where before they
  also needed the tunnel.
- **Locks a person with the password can cause.** Wrong codes lock the account, for up to an hour and then until it is unlocked, and need the
  password first. Wrong passwords move no lock, so a stranger can cause none.
- **Relaxed SSRF protection.** `ALLOW_INTERNAL_IP_CONNECTIONS=true` stays, for Kubernetes token review. The server's egress reaches only its
  database, Redis and the API server, so whatever a caller could get it to dial, nothing else answers.
- **Mail in the log.** With no SMTP, any mail Infisical would send is written to its log, and Loki keeps that log for 7 days behind Grafana's public
  login. With an authenticator app no code is mailed. The flows a stranger could start that would mail one, sign-up and account recovery, are
  refused.

What bounds it: one admin, sign-up closed and watched, two-factor, a limit per address, the route's allow list, no machine's credential from
outside, policy holding the route's words, and the tunnel as the way in when something goes wrong.

**Costs.** The Secret Sharing pages, member invitations, SSO, account recovery by email and the CLI's browser login do not work through the public
route. A machine's token works only inside the cluster, so a script that wants Infisical from outside goes through the tunnel. An Infisical upgrade
waits until someone has read its new routes and web client, run the route test, and changed the version in policy. Safari keeps no session through
the tunnel once cookies are Secure, so the tunnel is for Chrome or Firefox.
