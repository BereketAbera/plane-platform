# Hosted production, target plane-prod. Run with --namespace hosted, and only on gitops/environments/prod,
# gitops/clusters/plane-prod and the charts its Applications install: a local manifest breaks most of these on purpose.
# The other packages read those files too. These are what only this cluster must hold, because it faces the internet.
package hosted

import data.lib.kube
import rego.v1

public_url := "https://wayline.bereket.dev"

tls_secret := "wayline-tls"

plane_namespace := "plane-prod"

# ---- Images

image_fields := {"image", "baseImage"}

# The laptop's registry cannot be reached from the server, and what it holds has no evidence behind it.
local_registry := `^(localhost|127\.[0-9.]+|\[::1\]|host\.docker\.internal|kind-registry)([:/]|$)`

deny contains msg if {
	walk(input, [path, value])
	image_fields[path[count(path) - 1]]
	is_string(value)
	regex.match(local_registry, value)
	msg := sprintf("%s: image %q is on a local registry, which hosted production cannot reach, at %v", [identity, value, path])
}

# Whatever registry the name above misses: Wayline's images exist for this cluster in one place only.
deny contains msg if {
	walk(input, [path, value])
	image_fields[path[count(path) - 1]]
	is_string(value)
	contains(value, "wayline/")
	not startswith(value, "ghcr.io/bereketabera/wayline/")
	msg := sprintf("%s: image %q must come from ghcr.io/bereketabera/wayline, at %v", [identity, value, path])
}

# ---- What the application is told about itself

# WEB_URL builds every link Plane sends. An http: anywhere in CORS_ALLOWED_ORIGINS, or an empty value, takes Secure off
# the session and CSRF cookies (settings/common.py). MINIO_ENDPOINT_SSL makes presigned URLs https. ENABLE_SIGNUP seeds
# once at first boot, and upstream's default is open.
required_app_vars := {
	"WEB_URL": public_url,
	"CORS_ALLOWED_ORIGINS": public_url,
	"MINIO_ENDPOINT_SSL": "1",
	"ENABLE_SIGNUP": "0",
}

deny contains msg if {
	input.kind == "ConfigMap"
	input.metadata.name == "plane-app-vars"
	some key, want in required_app_vars
	got := object.get(input.data, key, "absent")
	got != want
	msg := sprintf("%s: %s is %q and must be %q, so no http origin and no http WEB_URL", [identity, key, got, want])
}

# A container's env beats the ConfigMap, so the same keys there must not say otherwise.
deny contains msg if {
	kube.is_workload(input)
	some c in kube.containers(input)
	some e in c.env
	want := required_app_vars[e.name]
	got := object.get(e, "value", "a reference")
	got != want
	msg := sprintf("%s: container %q sets %s to %q and it must be %q, so no http origin and no http WEB_URL", [identity, c.name, e.name, got, want])
}

# ---- Routes

route_kinds := {"IngressRoute", "IngressRouteTCP", "IngressRouteUDP"}

# Grafana is one of the two consoles with a public route, and this is all of its route. Whole objects and not a pattern, so another host, path,
# backend or middleware is a change here that a person reads. The first route carries the login's limit, and has the longer rule, which
# is what puts it ahead of the second. The second leaves out /metrics, which Prometheus reads from the pod and the internet has no use for.
grafana_namespace := "monitoring"

grafana_host := "grafana.bereket.dev"

grafana_tls_secret := "grafana-tls"

grafana_login_limit := "grafana-login-limit"

grafana_service := {"name": "kps-grafana", "port": 80}

grafana_routes := {
	{
		"kind": "Rule",
		"match": sprintf("Host(`%s`) && Method(`POST`) && (PathPrefix(`/login`) || PathPrefix(`/api/login`))", [grafana_host]),
		"middlewares": [{"name": grafana_login_limit}],
		"services": [grafana_service],
	},
	{
		"kind": "Rule",
		"match": sprintf("Host(`%s`) && !PathPrefix(`/metrics`)", [grafana_host]),
		"services": [grafana_service],
	},
}

# A person's guesses, measured per client. ipStrategy with no depth is the connection's own address, and Traefik trusts no forwarded
# header on these entry points, so the other criteria would all count something the client chooses.
grafana_login_limit_spec := {"rateLimit": {
	"average": 5,
	"period": "1m",
	"burst": 5,
	"sourceCriterion": {"ipStrategy": {"depth": 0}},
}}

# Infisical is the other, for its one admin's browser, by the owner's choice: docs/adr/0017-infisical-public-route.md. All four of its routes,
# in the words gitops/clusters/plane-prod/platform/infisical/route.yaml gives them, and tests/routes/infisical-public-route.sh proves each of
# those words against the pinned Traefik. The first two carry a limit each, and the other two do not reach their paths, so with either gone
# what it held is refused and not unlimited.
infisical_namespace := "infisical"

infisical_host := "infisical.bereket.dev"

infisical_tls_secret := "infisical-tls"

infisical_guess_limit := "infisical-guess-limit"

infisical_session_limit := "infisical-session-limit"

infisical_service := {"name": "infisical", "port": 8080}

infisical_host_rule := concat("", ["Host(`", infisical_host, "`)"])

# What a guess is made against: a password or a code.
infisical_guess_match := concat("", [
	infisical_host_rule,
	" && Method(`POST`) && (",
	concat(" || ", [
		"Path(`/api/v3/auth/login`)",
		"Path(`/api/v2/auth/mfa/send`)",
		"Path(`/api/v2/auth/mfa/verify`)",
		"Path(`/api/v2/auth/mfa/verify/recovery-code`)",
		"PathRegexp(`^/api/v2/mfa-sessions/[^/]+/verify$`)",
		"Path(`/api/v2/password/user/password-reset`)",
		"Path(`/api/v1/password/password-setup`)",
		"Path(`/api/v1/password/email/password-setup`)",
	]),
	")",
])

# What carries a session, and takes a token this server signed.
infisical_session_match := concat("", [
	infisical_host_rule,
	" && ((Method(`POST`) && (",
	concat(" || ", ["Path(`/api/v3/auth/select-organization`)", "Path(`/api/v1/auth/token`)", "Path(`/api/v1/auth/logout`)"]),
	")) || (Method(`GET`) && (",
	concat(" || ", ["Path(`/api/v2/auth/mfa/check/totp`)", "Path(`/api/v2/auth/mfa/check/webauthn`)"]),
	")))",
])

# The API families the web client calls at v0.167.6, and nothing else under /api. A family a later version adds is refused until it is here.
infisical_api_allowed := `^/api/(status$|v1/auth/([a-z-]+-auth/identities|token-auth/tokens)/|v1/(access-approvals|admin|agent-vault|alerts|announcement|app-connections|approval-policies|audit-log-streams|cert-manager|dashboard|delegated-approvals|dynamic-secrets|email-domains|external-kms|gateway-pools|github-apps|github-org-sync-config|groups|honey-tokens|identities|identity-templates|insights|integration|integration-auth|kmip|kms|ldap|notifications|oauth|organization|organization-admin|organizations|pam|pit|pki|project-folder-grants|project-templates|projects|proxied-services|relays|reminders|secret-approval-requests|secret-syncs|secret-validation-rules|secrets|sso|sub-organizations|user|user-activation|user-engagement|user-project-additional-privilege|webhooks|workflow-integrations)(/|$)|v2/(folders|gateways|identities|identity-project-additional-privilege|mfa-sessions|organizations|pki|relays|secret-approvals|secret-imports|secret-rotations|secret-scanning|secret-versions|service-token|users)(/|$)|v3/(external-migration|gateways)(/|$)|v4/secrets(/|$))`

# Within those families, what takes a credential and no browser needs: machine and agent logins and calls, protocol endpoints, callbacks
# and the SSO logins. tests/routes/infisical-machine-routes.tsv lists every call that takes only a machine's credential.
infisical_api_refused := `(?i)^/api/(v1/(admin/(bootstrap|signup)|agent-vault/(proxy|session)/|announcement/assets/|cert-manager/(acme|crl|ocsp)/|delegated-approvals/callback|github-apps/manifest/callback|honey-tokens/aws/trigger|identities/details|kmip/(server-registration|servers/(connect|login)|spec/)|ldap/login|oauth/(authorize|token|validate)|organization/agent-proxy-ca|pam/accounts/[^/]+/web-access($|/)|pam/sessions/[^/]+/(chunks(/presigned-put)?|credentials|end)($|/)|pki/ca/[^/]+/certificates/[^/]+/der|proxied-services/[^/]+/report-usage|relays/(heartbeat|register)|sso/(github|gitlab|google|oidc/(callback|login)|redirect|saml2|token-exchange)|user/[^/]+/unlock|workflow-integrations/(microsoft-teams/message-endpoint|slack/oauth_redirect))|v2/(gateways/(heartbeat|metrics|pam-session-key)|mfa-sessions/[^/]+/verify|relays/(connect|heartbeat|login))|v3/gateways/(connect|login|token-auth/enroll))`

# A machine's credential on any of those: an identity's access token, whose payload begins {"identityId":, a service token, or an API key.
# A person's session begins {"authMethod":. Any byte outside printable ASCII is refused too, so Infisical's 7 bytes and the 7 characters
# here agree.
infisical_machine_credential := "!HeaderRegexp(`Authorization`, `[^ -~]|^.{7}st\\.|\\.eyJpZGVudGl0eUlkIjo`) && !HeaderRegexp(`X-Api-Key`, `.*`)"

infisical_api_match := concat(" && ", [
	infisical_host_rule,
	concat("", ["PathRegexp(`", infisical_api_allowed, "`)"]),
	concat("", ["!PathRegexp(`", infisical_api_refused, "`)"]),
	"!(Method(`POST`) && PathRegexp(`(?i)^/api/v2/gateways/?$`))",
	"!((Method(`GET`) || Method(`HEAD`)) && PathRegexp(`(?i)^/api/v2/service-token/?$`))",
	infisical_machine_credential,
])

# Pages: a clean path, and none of those for signing up, recovering an account, sharing a secret or a login this platform has no use for.
infisical_page_shape := `^/([A-Za-z0-9._~@:$/-]|%20)*$`

infisical_page_refused := `(?i)^/(api|\.well-known|scep|secret-scanning|signup|admin/signup|requestnewinvite|account-recovery|email-not-verified|login/(ldap|oidc|saml|provider)|cli-redirect|share-secret|shared|secret-request)`

infisical_page_match := concat(" && ", [
	infisical_host_rule,
	concat("", ["PathRegexp(`", infisical_page_shape, "`)"]),
	concat("", ["!PathRegexp(`", infisical_page_refused, "`)"]),
])

infisical_routes := {
	{
		"kind": "Rule",
		"match": infisical_guess_match,
		"middlewares": [{"name": infisical_guess_limit}],
		"services": [infisical_service],
	},
	{
		"kind": "Rule",
		"match": infisical_session_match,
		"middlewares": [{"name": infisical_session_limit}],
		"services": [infisical_service],
	},
	{
		"kind": "Rule",
		"match": infisical_api_match,
		"services": [infisical_service],
	},
	{
		"kind": "Rule",
		"match": infisical_page_match,
		"services": [infisical_service],
	},
}

# Measured, as the route file says: one correct sign-in spends 2 of the first and 4 of the second. Per client, as Grafana's.
infisical_limit_specs := {
	infisical_guess_limit: {"rateLimit": {
		"average": 10,
		"period": "1m",
		"burst": 10,
		"sourceCriterion": {"ipStrategy": {"depth": 0}},
	}},
	infisical_session_limit: {"rateLimit": {
		"average": 30,
		"period": "1m",
		"burst": 30,
		"sourceCriterion": {"ipStrategy": {"depth": 0}},
	}},
}

route_namespaces := {plane_namespace, grafana_namespace, infisical_namespace}

# These read the namespace an object states. Argo CD would put one that states none in its Application's destination, where these would not
# see it, so policy/hosted_tree.rego wants every object in the hosted tree to state its own.
in_grafana_namespace if object.get(input.metadata, "namespace", "") == grafana_namespace

in_infisical_namespace if object.get(input.metadata, "namespace", "") == infisical_namespace

# Plane's route, Grafana's and Infisical's. Anywhere else it could only be another console's.
deny contains msg if {
	route_kinds[input.kind]
	not route_namespaces[object.get(input.metadata, "namespace", "")]
	msg := sprintf("%s: a route may sit only in namespace %s, in %s for Grafana's or in %s for Infisical's, and the other consoles get none: reach them through an SSH tunnel and a port-forward", [identity, plane_namespace, grafana_namespace, infisical_namespace])
}

deny contains msg if {
	input.kind in {"IngressRouteTCP", "IngressRouteUDP"}
	msg := sprintf("%s: %s is not allowed, because a TCP or UDP router comes before the HTTP routes on its entry point", [identity, input.kind])
}

# Port 80 only redirects, and a route with no entry points attaches to all of them.
deny contains msg if {
	input.kind == "IngressRoute"
	entry_points := object.get(input.spec, "entryPoints", [])
	entry_points != ["websecure"]
	msg := sprintf("%s: entryPoints is %v and must be exactly [websecure]", [identity, entry_points])
}

# cert-manager is the only certificate owner, so no certResolver either.
route_tls_secrets := {plane_namespace: tls_secret, grafana_namespace: grafana_tls_secret, infisical_namespace: infisical_tls_secret}

deny contains msg if {
	input.kind == "IngressRoute"
	want := object.get(route_tls_secrets, object.get(input.metadata, "namespace", ""), tls_secret)
	tls := object.get(input.spec, "tls", {})
	tls != {"secretName": want}
	msg := sprintf("%s: tls is %v and must name only secretName %s", [identity, tls, want])
}

# An allow list and not a list of consoles, so a new console needs a change here. The ports matter: Silo's console and
# RabbitMQ's management UI sit behind Services that exist for other reasons.
public_backends := {
	"plane-web": 3000,
	"plane-admin": 3000,
	"plane-space": 3000,
	"plane-live": 3000,
	"plane-api": 8000,
	"plane-minio": 9000,
}

deny contains msg if {
	input.kind == "IngressRoute"
	not in_grafana_namespace
	not in_infisical_namespace
	some route in input.spec.routes
	some service in route.services
	not public_backend(service)
	msg := sprintf("%s: route %q reaches %v:%v. Hosted production gives no console a public route but Grafana's, at %s, and Infisical's, at %s, and only Plane's own Services get one here", [identity, route.match, service.name, object.get(service, "port", "no port"), grafana_host, infisical_host])
}

# In Grafana's namespace a route is one of those two, and nothing else: not Grafana on another host or with /metrics, and not Prometheus
# or Alertmanager, which sit in the same namespace.
deny contains msg if {
	input.kind == "IngressRoute"
	in_grafana_namespace
	some route in input.spec.routes
	not grafana_routes[route]
	msg := sprintf("%s: route %q to %v is not one of Grafana's two. Hosted production gives Grafana only the route policy/hosted.rego writes, at %s", [identity, object.get(route, "match", ""), object.get(route, "services", []), grafana_host])
}

# And both of them: with the first gone, its limit is gone and the second still takes the login.
deny contains msg if {
	input.kind == "IngressRoute"
	in_grafana_namespace
	some wanted in grafana_routes
	not route_present(wanted)
	msg := sprintf("%s: has no route %q, and Grafana's route needs both of its two", [identity, wanted.match])
}

route_present(wanted) if {
	some route in input.spec.routes
	route == wanted
}

# A Middleware can rewrite a path after the rule has read it, so the only one here is the login's limit, as written above.
deny contains msg if {
	input.kind == "Middleware"
	in_grafana_namespace
	input.metadata.name != grafana_login_limit
	msg := sprintf("%s: the only Middleware in namespace %s is %s", [identity, grafana_namespace, grafana_login_limit])
}

deny contains msg if {
	input.kind == "Middleware"
	in_grafana_namespace
	input.metadata.name == grafana_login_limit
	input.spec != grafana_login_limit_spec
	msg := sprintf("%s: must be exactly %v, and any other source criterion counts something the client chooses", [identity, grafana_login_limit_spec])
}

# In Infisical's namespace a route is one of its four, and nothing else: not on another host, not to its Postgres or Redis, not with a
# family more or a refusal less, and not with a limit moved or gone.
deny contains msg if {
	input.kind == "IngressRoute"
	in_infisical_namespace
	some route in input.spec.routes
	not infisical_routes[route]
	msg := sprintf("%s: route %q to %v is not one of Infisical's four. Hosted production gives Infisical only the route policy/hosted.rego writes, at %s", [identity, object.get(route, "match", ""), object.get(route, "services", []), infisical_host])
}

deny contains msg if {
	input.kind == "IngressRoute"
	in_infisical_namespace
	some wanted in infisical_routes
	not route_present(wanted)
	msg := sprintf("%s: has no route %q, and Infisical's route needs all four of its routes", [identity, wanted.match])
}

# The same as Grafana's: a Middleware could rewrite a path after the rule read it, so the only ones here are the two limits, as written.
deny contains msg if {
	input.kind == "Middleware"
	in_infisical_namespace
	not infisical_limit_specs[input.metadata.name]
	msg := sprintf("%s: the only Middlewares in namespace %s are %s and %s", [identity, infisical_namespace, infisical_guess_limit, infisical_session_limit])
}

deny contains msg if {
	input.kind == "Middleware"
	in_infisical_namespace
	want := infisical_limit_specs[input.metadata.name]
	input.spec != want
	msg := sprintf("%s: must be exactly %v, and any other source criterion counts something the client chooses", [identity, want])
}

# The route's lists were read from this version's running server and its web client, and its header refusal from how this version's tokens
# begin, so another version may hold a login, a sign-up or a token they do not name. Moving Infisical on means reading those again, with
# tests/routes/infisical-public-route.sh against the new image, INFISICAL_ROUTE_TEST_DIRECT set to a throwaway copy's 127.0.0.1 port and
# INFISICAL_ROUTE_TEST_THROWAWAY to its container, and then moving this. The whole reference, so another digest under the same tag counts
# too, and any image whose repository is infisical/infisical, however its registry is spelled.
infisical_route_version := "v0.167.6"

infisical_route_image := concat("", ["docker.io/infisical/infisical:", infisical_route_version, "@sha256:ca5cbd14b2f170feaaca3fbe5b001b7594c8b9c0c62a491409910f10b05dbb2c"])

# An image reference's repository: its path with no tag or digest. The registry, which may hold a port of its own, stays in front.
image_repository(image) := concat("/", array.concat(array.slice(parts, 0, count(parts) - 1), [split(parts[count(parts) - 1], ":")[0]])) if {
	parts := split(split(image, "@")[0], "/")
}

infisical_server_image(image) if image_repository(image) == "infisical/infisical"

infisical_server_image(image) if endswith(image_repository(image), "/infisical/infisical")

deny contains msg if {
	kube.is_workload(input)
	some c in kube.containers(input)
	infisical_server_image(c.image)
	c.image != infisical_route_image
	msg := sprintf("%s: container %q runs %s, and Infisical's public route was read from %s, as %s. Read the new version's routes, web client and tokens, run tests/routes/infisical-public-route.sh against it, then change infisical_route_image in policy/hosted.rego", [identity, c.name, c.image, infisical_route_version, infisical_route_image])
}

# What the values tell Infisical's server about its public route, so a revert of any of it fails here: the host its links and CORS name,
# Secure cookies, Traefik's pods as the one proxy whose forwarded address it believes, and no anonymous secret sharing. Read from whatever
# runs its image, because the chart renders no namespace. env wins over the chart's envFrom, so the value here is the one it runs with.
infisical_env_wanted := {
	"SITE_URL": concat("", ["https://", infisical_host]),
	"HTTPS_ENABLED": "true",
	"TRUSTED_PROXY_CIDRS": "10.244.0.0/16",
	"DISABLE_PUBLIC_SECRET_SHARING": "true",
}

# Kubernetes takes the last of two entries with one name.
container_env_value(c, name) := values[count(values) - 1] if {
	values := [object.get(e, "value", "a reference") | some e in object.get(c, "env", []); e.name == name]
	count(values) > 0
} else := "unset"

deny contains msg if {
	kube.is_workload(input)
	some c in kube.containers(input)
	infisical_server_image(c.image)
	some name, want in infisical_env_wanted
	got := container_env_value(c, name)
	got != want
	msg := sprintf("%s: container %q sets %s to %q, and with a public route it must be %q", [identity, c.name, name, got, want])
}

# ---- What watches Infisical's route

# The alerts in monitoring-extras/shared/rules-hosted.yaml read these Probes by their probe label, and what a reading means by its module. So
# each is written out here whole: another module, target or label would leave its alerts reading something else, as a claim probe on a
# module that reads no body leaves all three claim alerts quiet.
infisical_probes := {
	"infisical": {"module": "http_infisical_login", "target": "https://infisical.bereket.dev/login"},
	"infisical-claimed": {"module": "http_infisical_claimed", "target": "https://infisical.bereket.dev/api/v1/admin/config"},
	"infisical-sign-in": {"module": "http_infisical_no_bearer_post", "target": "https://infisical.bereket.dev/api/v1/password/password-setup"},
	"infisical-session": {"module": "http_infisical_no_refresh_cookie", "target": "https://infisical.bereket.dev/api/v1/auth/token"},
}

# The Service each Probe asks. policy/hosted_combined.rego follows it to the file its pods read.
infisical_prober := {"url": "blackbox.monitoring.svc.cluster.local:9115", "path": "/probe"}

infisical_probe_spec(name) := {
	"jobName": "infisical-http",
	"interval": "30s",
	"scrapeTimeout": "10s",
	"module": infisical_probes[name].module,
	"prober": infisical_prober,
	"targets": {"staticConfig": {"static": [infisical_probes[name].target], "labels": {"probe": name}}},
}

deny contains msg if {
	input.kind == "Probe"
	in_infisical_namespace
	not infisical_probes[input.metadata.name]
	msg := sprintf("%s: the only Probes in namespace %s are %v, which its alerts read", [identity, infisical_namespace, object.keys(infisical_probes)])
}

deny contains msg if {
	input.kind == "Probe"
	in_infisical_namespace
	infisical_probes[input.metadata.name]
	input.spec != infisical_probe_spec(input.metadata.name)
	msg := sprintf("%s: must be exactly %v, because Infisical's alerts read this Probe's module, target and label", [identity, infisical_probe_spec(input.metadata.name)])
}

# The same label from anywhere else would be a second series those alerts read.
deny contains msg if {
	input.kind == "Probe"
	not in_infisical_namespace
	label := object.get(input, ["spec", "targets", "staticConfig", "labels", "probe"], "")
	infisical_probes[label]
	msg := sprintf("%s: carries probe label %s, which Infisical's alerts read, and only its Probe in namespace %s may", [identity, label, infisical_namespace])
}

# Each module those Probes use, as blackbox reads it from the ConfigMap kustomize makes of shared/blackbox.yml. Nothing else reads that
# file. The rules below hold that ConfigMap by its name. policy/hosted_combined.rego follows infisical_prober's Service to each container of
# the pods it selects, and holds these modules in the one file that container reads: the one its single --config.file names, by a clean
# absolute path with no $(VAR) for Kubernetes to expand and no empty, "." or ".." segment, from one ConfigMap under any name, mounted whole
# or by items at that file's directory, with no other mount at or under that directory, a subPath one included. No rule reading one object
# at a time can find that.
infisical_blackbox_modules := {
	"http_infisical_login": {"prober": "http", "timeout": "5s", "http": {
		"preferred_ip_protocol": "ip4",
		"fail_if_not_ssl": true,
		"valid_status_codes": [200],
		"fail_if_body_not_matches_regexp": [`<title id="initial-document-title">Infisical</title>`],
	}},
	"http_infisical_claimed": {"prober": "http", "timeout": "5s", "http": {
		"preferred_ip_protocol": "ip4",
		"fail_if_not_ssl": true,
		"valid_status_codes": [200],
		"fail_if_body_json_not_matches_cel": "body.config.initialized == true && body.config.allowSignUp == false",
	}},
	"http_infisical_no_bearer_post": {"prober": "http", "timeout": "5s", "http": {
		"method": "POST",
		"preferred_ip_protocol": "ip4",
		"fail_if_not_ssl": true,
		"valid_status_codes": [401],
		"fail_if_body_not_matches_regexp": [`"message":\s*"Token missing"`],
	}},
	"http_infisical_no_refresh_cookie": {"prober": "http", "timeout": "5s", "http": {
		"method": "POST",
		"preferred_ip_protocol": "ip4",
		"fail_if_not_ssl": true,
		"valid_status_codes": [404],
		"fail_if_body_not_matches_regexp": [`"error":\s*"AuthTokenNotFound"`],
	}},
}

is_blackbox_config if {
	input.kind == "ConfigMap"
	object.get(input.metadata, "namespace", "") == "monitoring"
	startswith(input.metadata.name, "blackbox-config")
}

deny contains msg if {
	is_blackbox_config
	not yaml.is_valid(object.get(input, ["data", "blackbox.yml"], ""))
	msg := sprintf("%s: blackbox.yml is not YAML, so nothing here can say what Infisical's Probes read", [identity])
}

deny contains msg if {
	is_blackbox_config
	modules := object.get(yaml.unmarshal(object.get(input, ["data", "blackbox.yml"], "")), "modules", {})
	some name, want in infisical_blackbox_modules
	object.get(modules, name, "missing") != want
	msg := sprintf("%s: blackbox module %s is %v, and must be exactly %v, because Infisical's alerts read what it reports", [identity, name, object.get(modules, name, "missing"), want])
}

# ---- Who reaches Infisical, and what it reaches

# NetworkPolicy adds up, and in both directions: what may arrive in namespace infisical, and what may leave it, is every policy there taken
# together. So every policy there is written out here, and a policy more, or one of these wider, is a change a person reads first. In:
# Traefik's pods reach the server on 8080 and a solver on 8089, the operator the server, and only the server and the backup Jobs reach
# Postgres, and only the server Redis. Out: every pod reaches kube-dns, the server its database, Redis and the API server, and the backup Jobs
# Postgres. That is all that bounds what the server's relaxed SSRF protection lets a caller of its public route make it dial, as
# values/infisical.yaml says at ALLOW_INTERNAL_IP_CONNECTIONS, so an egress-only policy is as much a way out as one with ingress is a way in.
infisical_server_pods := {"matchLabels": {"app": "infisical-standalone", "component": "infisical"}}

traefik_pods := {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "traefik"}}, "podSelector": {"matchLabels": {"app.kubernetes.io/name": "traefik"}}}

infisical_network_policies := {
	"default-deny": {"podSelector": {}, "policyTypes": ["Ingress", "Egress"]},
	"allow-dns": {
		"podSelector": {},
		"policyTypes": ["Egress"],
		"egress": [{
			"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}}, "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}}}],
			"ports": [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}],
		}],
	},
	"backup": {
		"podSelector": {"matchLabels": {"app.kubernetes.io/component": "backup"}},
		"policyTypes": ["Egress"],
		"egress": [{"to": [{"podSelector": {"matchLabels": {"app.kubernetes.io/name": "infisical-postgres"}}}], "ports": [{"protocol": "TCP", "port": 5432}]}],
	},
	"infisical-server": {
		"podSelector": infisical_server_pods,
		"policyTypes": ["Ingress", "Egress"],
		"ingress": [
			{"from": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "plane-prod"}}, "podSelector": {"matchLabels": {"app.kubernetes.io/name": "secrets-operator"}}}], "ports": [{"protocol": "TCP", "port": 8080}]},
			{"from": [traefik_pods], "ports": [{"protocol": "TCP", "port": 8080}]},
		],
		"egress": [
			{"to": [{"podSelector": {"matchLabels": {"app.kubernetes.io/name": "infisical-postgres"}}}], "ports": [{"protocol": "TCP", "port": 5432}]},
			{"to": [{"podSelector": {"matchLabels": {"app.kubernetes.io/name": "infisical-redis"}}}], "ports": [{"protocol": "TCP", "port": 6379}]},
			{"to": [{"ipBlock": {"cidr": "5.253.234.127/32"}}], "ports": [{"protocol": "TCP", "port": 6443}]},
		],
	},
	"infisical-postgres": {
		"podSelector": {"matchLabels": {"app.kubernetes.io/name": "infisical-postgres"}},
		"policyTypes": ["Ingress"],
		"ingress": [{"from": [{"podSelector": infisical_server_pods}, {"podSelector": {"matchLabels": {"app.kubernetes.io/component": "backup"}}}], "ports": [{"protocol": "TCP", "port": 5432}]}],
	},
	"infisical-redis": {
		"podSelector": {"matchLabels": {"app.kubernetes.io/name": "infisical-redis"}},
		"policyTypes": ["Ingress"],
		"ingress": [{"from": [{"podSelector": infisical_server_pods}], "ports": [{"protocol": "TCP", "port": 6379}]}],
	},
	"acme-http01-solver": {
		"podSelector": {"matchLabels": {"acme.cert-manager.io/http01-solver": "true"}},
		"policyTypes": ["Ingress"],
		"ingress": [{"from": [traefik_pods], "ports": [{"protocol": "TCP", "port": 8089}]}],
	},
}

# This reads the namespace a policy states. One that states none in platform/infisical would land in namespace infisical all the same, so
# policy/hosted_tree.rego refuses it.
is_network_policy_in(namespace) if {
	input.kind == "NetworkPolicy"
	object.get(input.metadata, "namespace", "") == namespace
}

deny contains msg if {
	is_network_policy_in(infisical_namespace)
	not infisical_network_policies[input.metadata.name]
	msg := sprintf("%s: is not one of the NetworkPolicies in namespace %s, which are %v, as policy/hosted.rego writes them. A policy more lets more in or out, with ingress rules or without", [identity, infisical_namespace, object.keys(infisical_network_policies)])
}

deny contains msg if {
	is_network_policy_in(infisical_namespace)
	want := infisical_network_policies[input.metadata.name]
	input.spec != want
	msg := sprintf("%s: spec must be exactly %v, so nothing new reaches the secret store or its database, and they reach nothing new", [identity, want])
}

# Traefik's way into namespace infisical, from its side: the server on 8080 and a solver on 8089, and nothing else there.
traefik_infisical_egress := {
	{"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": infisical_namespace}}, "podSelector": infisical_server_pods}], "ports": [{"protocol": "TCP", "port": 8080}]},
	{"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": infisical_namespace}}, "podSelector": {"matchLabels": {"acme.cert-manager.io/http01-solver": "true"}}}], "ports": [{"protocol": "TCP", "port": 8089}]},
}

# A rule with no destination reaches everything, a namespace selector that does not name one namespace may select infisical, and an address
# block over the pods' range reaches its pods, because kube-router reads a pod's own address.
egress_reaches_infisical(rule) if count(object.get(rule, "to", [])) == 0

egress_reaches_infisical(rule) if {
	some peer in rule.to
	peer.namespaceSelector
	object.get(peer.namespaceSelector, ["matchLabels", "kubernetes.io/metadata.name"], infisical_namespace) == infisical_namespace
}

egress_reaches_infisical(rule) if {
	some peer in rule.to
	net.cidr_intersects(peer.ipBlock.cidr, "10.244.0.0/16")
}

deny contains msg if {
	is_network_policy_in("traefik")
	some rule in object.get(input.spec, "egress", [])
	egress_reaches_infisical(rule)
	not traefik_infisical_egress[rule]
	msg := sprintf("%s: egress rule %v may reach namespace %s, where Traefik reaches only Infisical's server on 8080 and a solver on 8089", [identity, rule, infisical_namespace])
}

public_backend(service) if {
	public_backends[service.name] == service.port
	object.get(service, "kind", "Service") == "Service"
	object.get(service, "namespace", plane_namespace) == plane_namespace
}

# cert-manager makes its own Ingress for a challenge and removes it, so none belongs in Git. Traefik reads the Ingress
# provider for that alone, so any other would be a public route no rule here reads.
deny contains msg if {
	input.kind in {"Ingress", "Gateway", "HTTPRoute", "GRPCRoute", "TLSRoute", "TCPRoute", "UDPRoute"}
	msg := sprintf("%s: no %s in Git. Routes are IngressRoutes, and cert-manager makes the Ingress a challenge needs", [identity, input.kind])
}

# ---- Grafana's login and its token

# Its password is all that keeps a stranger from every dashboard and log, so what guards that login is written out here, and a revert of
# any of it fails CI before it reaches the cluster. Each must be set, because for four of them Grafana 13.3.0's own default is the wrong one:
# basic auth on, failures counted per username and not per address, and the version shown. policy/hosted_combined.rego says the ConfigMap
# and the Role below are there at all.
grafana_name := "kps-grafana"

grafana_ini_wanted := {
	{"section": "auth.basic", "key": "enabled", "value": "false", "why": "basic auth answers on every path, past the login's limit, and writes each failed name to the database"},
	{"section": "security", "key": "disable_username_login_protection", "value": "true", "why": "a count per username lets any stranger keep the one admin locked out"},
	{"section": "security", "key": "disable_ip_address_login_protection", "value": "false", "why": "the count per address is what holds a stranger's guesses"},
	{"section": "security", "key": "disable_brute_force_login_protection", "value": "false", "why": "it switches off both counts"},
	{"section": "auth.anonymous", "key": "enabled", "value": "false", "why": "a stranger would read every dashboard with no login"},
	{"section": "auth.anonymous", "key": "hide_version", "value": "true", "why": "it keeps the version and commit out of /api/health and most of /login"},
	{"section": "auth.proxy", "key": "enabled", "value": "false", "why": "Traefik passes X-WEBAUTH-USER through, so a stranger could send it and be that user"},
}

is_grafana(kind) if {
	input.kind == kind
	input.metadata.name == grafana_name
	object.get(input.metadata, "namespace", "") == grafana_namespace
}

# grafana.ini as Grafana reads it: a [section] line, then key = value lines under it. Every line that sets a key, so a second line for the
# same key is read too.
grafana_ini_lines contains {"section": section, "key": parts[1], "value": parts[2]} if {
	is_grafana("ConfigMap")
	lines := split(object.get(input, ["data", "grafana.ini"], ""), "\n")
	some i, line in lines
	parts := regex.find_all_string_submatch_n(`^\s*([^\s=;#\[]+)\s*=\s*(.*?)\s*$`, line, 1)[0]
	section := grafana_ini_section(lines, i)
}

grafana_ini_section(lines, i) := trim_space(trim(trim_space(lines[max(headers)]), "[]")) if {
	headers := [j | some j, line in lines; j < i; regex.match(`^\s*\[[^\]]*\]\s*$`, line)]
	count(headers) > 0
} else := ""

grafana_ini_sets(wanted) if {
	some line in grafana_ini_lines
	line.section == wanted.section
	line.key == wanted.key
}

deny contains msg if {
	is_grafana("ConfigMap")
	some wanted in grafana_ini_wanted
	not grafana_ini_sets(wanted)
	msg := sprintf("%s: grafana.ini must set [%s] %s = %s, and does not, because %s", [identity, wanted.section, wanted.key, wanted.value, wanted.why])
}

deny contains msg if {
	some line in grafana_ini_lines
	some wanted in grafana_ini_wanted
	line.section == wanted.section
	line.key == wanted.key
	line.value != wanted.value
	msg := sprintf("%s: grafana.ini sets [%s] %s = %s, and it must be %s, because %s", [identity, line.section, line.key, line.value, wanted.value, wanted.why])
}

# Grafana takes GF_<SECTION>_<KEY> from its environment over grafana.ini, so none of those may be set there, whatever the value: one from a
# reference cannot be read here. envFrom could hold any of them unnamed.
grafana_env_name(wanted) := upper(sprintf("GF_%s_%s", [replace(replace(wanted.section, ".", "_"), "-", "_"), wanted.key]))

deny contains msg if {
	is_grafana("Deployment")
	some c in kube.containers(input)
	some e in object.get(c, "env", [])
	some wanted in grafana_ini_wanted
	e.name == grafana_env_name(wanted)
	msg := sprintf("%s: container %q sets %s, which Grafana takes over [%s] %s in grafana.ini. Set it there, where this reads it", [identity, c.name, e.name, wanted.section, wanted.key])
}

deny contains msg if {
	is_grafana("Deployment")
	some c in kube.containers(input)
	count(object.get(c, "envFrom", [])) > 0
	msg := sprintf("%s: container %q takes envFrom, which could set any of Grafana's settings where nothing here reads them. Name each variable in env", [identity, c.name])
}

# A sidecar's reload call needs basic auth, which is off, so a REQ_URL is a reload that fails with 401, or basic auth back on for it.
deny contains msg if {
	is_grafana("Deployment")
	some c in kube.containers(input)
	some e in object.get(c, "env", [])
	e.name == "REQ_URL"
	msg := sprintf("%s: container %q calls %v, and that reload needs basic auth, which grafana.ini keeps off. Set the sidecar's skipReload", [identity, c.name, object.get(e, "value", "a reference")])
}

# Grafana reads datasources only when it starts, or on that reload call. One written while it runs would sit unread until something replaced
# the pod, with Argo CD saying Synced. They are in the chart's datasources value instead, which ConfigMap kps-grafana holds, and its checksum
# rolls the pod.
deny contains msg if {
	is_grafana("Deployment")
	some c in kube.containers(input)
	some e in object.get(c, "env", [])
	e.name == "FOLDER"
	startswith(object.get(e, "value", ""), "/etc/grafana/provisioning/datasources")
	msg := sprintf("%s: container %q writes Grafana's datasources, and Grafana reads them only when it starts, so a change would sit unread. Put them in the chart's datasources value, which rolls the pod", [identity, c.name])
}

deny contains msg if {
	"grafana_datasource" in object.keys(object.get(input, ["metadata", "labels"], {}))
	msg := sprintf("%s: is labelled grafana_datasource, and nothing reads that label. Grafana's datasources are the chart's datasources value, which rolls the pod when one changes", [identity])
}

# Its token is what a bug in the one pod on the internet would hold. The dashboard sidecar reads ConfigMaps, and nothing in that pod needs more.
grafana_role_rules := [{"apiGroups": [""], "resources": ["configmaps"], "verbs": ["get", "list", "watch"]}]

grafana_role_ref := {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": grafana_name}

deny contains msg if {
	is_grafana("Role")
	not grafana_role_reads_configmaps_alone
	msg := sprintf("%s: rules are %v, and must be exactly %v, so Grafana's token reads no Secret", [identity, object.get(input, "rules", []), grafana_role_rules])
}

grafana_role_reads_configmaps_alone if {
	count(input.rules) == 1
	rule := input.rules[0]
	object.keys(rule) == {"apiGroups", "resources", "verbs"}
	{group | some group in rule.apiGroups} == {""}
	{resource | some resource in rule.resources} == {"configmaps"}
	{verb | some verb in rule.verbs} == {"get", "list", "watch"}
}

deny contains msg if {
	is_grafana("RoleBinding")
	input.roleRef != grafana_role_ref
	msg := sprintf("%s: roleRef is %v, and must be %v, the Role these rules read", [identity, input.roleRef, grafana_role_ref])
}

# Any other binding would give that token more than the Role above, from anywhere in the cluster.
deny contains msg if {
	input.kind in {"RoleBinding", "ClusterRoleBinding"}
	some subject in object.get(input, "subjects", [])
	subject.kind == "ServiceAccount"
	subject.name == grafana_name
	object.get(subject, "namespace", grafana_namespace) == grafana_namespace
	not is_grafana("RoleBinding")
	msg := sprintf("%s: binds Grafana's ServiceAccount, whose one binding is RoleBinding %s/%s, to the Role these rules read", [identity, grafana_namespace, grafana_name])
}

deny contains msg if {
	is_grafana("Deployment")
	account := object.get(kube.pod_spec(input), "serviceAccountName", "default")
	account != grafana_name
	msg := sprintf("%s: runs as ServiceAccount %q, and the rules here read what %s may do", [identity, account, grafana_name])
}

# ---- What binds to the node

# The firewall drops these ports today, and it is one layer. Traefik's hostPort is the only way in.
deny contains msg if {
	input.kind == "Service"
	service_type := object.get(input.spec, "type", "ClusterIP")
	service_type in {"NodePort", "LoadBalancer"}
	msg := sprintf("%s: no %s Service. Traefik's hostPort is the only way in", [identity, service_type])
}

deny contains msg if {
	input.kind == "Service"
	count(object.get(input.spec, "externalIPs", [])) > 0
	msg := sprintf("%s: no externalIPs. Traefik's hostPort is the only way in", [identity])
}

# Contract section 2: node-exporter, in this namespace, is the one workload that needs the host's network.
host_network_namespace := "monitoring-agents"

deny contains msg if {
	kube.pod_spec(input).hostNetwork == true
	object.get(input.metadata, "namespace", "") != host_network_namespace
	msg := sprintf("%s: hostNetwork is for node-exporter in %s alone, because a policy cannot hold a pod on the host's network", [identity, host_network_namespace])
}

deny contains msg if {
	kube.is_workload(input)
	some c in kube.containers(input)
	some port in object.get(c, "ports", [])
	port.hostPort
	not host_port_allowed(port.hostPort)
	msg := sprintf("%s: container %q asks for hostPort %v. Traefik holds 80 and 443, and nothing else may bind to the node", [identity, c.name, port.hostPort])
}

host_port_allowed(port) if {
	input.metadata.namespace == "traefik"
	port in {80, 443}
}

host_port_allowed(_) if input.metadata.namespace == host_network_namespace

# A second certificate owner, as above, this one through Traefik's own flags.
deny contains msg if {
	kube.is_workload(input)
	some c in kube.containers(input)
	some arg in object.get(c, "args", [])
	startswith(lower(arg), "--certificatesresolvers")
	msg := sprintf("%s: container %q has %s, and cert-manager is the only certificate owner", [identity, c.name, arg])
}

# cert-manager's own default for a solver is a NodePort Service, made at run time, which no rule above would ever read.
deny contains msg if {
	input.kind in {"ClusterIssuer", "Issuer"}
	some solver in object.get(input, ["spec", "acme", "solvers"], [])
	http01 := solver.http01
	service_type := object.get(http01, ["ingress", "serviceType"], "NodePort")
	service_type != "ClusterIP"
	msg := sprintf("%s: an HTTP-01 solver's serviceType is %v, and it must be ClusterIP, or each challenge opens a NodePort", [identity, service_type])
}

# ---- Where this cluster reads from

git_repo := "ssh://git@ssh.github.com:443/BereketAbera/plane-platform.git"

git_revision := "deploy/plane-prod"

# Root reads applications/, a child one directory of platform/, and plane-prod the render. Everything that checks this tree reads those
# and nothing else (collect_hosted in scripts/ci/lib-manifests.sh), so an Application on any other path, values/ or a new folder, would
# deploy what no rule here has read. And deploy/plane-prod holds only the two trees, so a path out of them would fail at sync.
readable_path("gitops/environments/prod")

readable_path(path) if {
	not contains(path, "..")
	regex.match(`^gitops/clusters/plane-prod/platform/[A-Za-z0-9._-]+$`, path)
}

readable_path("gitops/clusters/plane-prod/applications") if input.metadata.name == "root"

clean_path(path) := trim_suffix(trim_prefix(path, "./"), "/")

git_source(source) if not source.chart

deny contains msg if {
	input.kind == "Application"
	some source in kube.app_sources(input)
	git_source(source)
	object.get(source, "repoURL", "") != git_repo
	msg := sprintf("%s: Git source %v is not the one this cluster reads, %s", [identity, object.get(source, "repoURL", ""), git_repo])
}

deny contains msg if {
	input.kind == "Application"
	some source in kube.app_sources(input)
	git_source(source)
	object.get(source, "targetRevision", "") != git_revision
	msg := sprintf("%s: Git source is at %v, and this cluster reads only %s, so nothing but that branch deploys", [identity, object.get(source, "targetRevision", ""), git_revision])
}

deny contains msg if {
	input.kind == "Application"
	some source in kube.app_sources(input)
	git_source(source)
	path := source.path
	not readable_path(clean_path(path))
	msg := sprintf("%s: path %q is not one this cluster reads: a directory of gitops/clusters/plane-prod/platform, or gitops/environments/prod. Nothing checks what any other path holds", [identity, path])
}

# With neither field it would read the root of the branch.
deny contains msg if {
	input.kind == "Application"
	some source in kube.app_sources(input)
	git_source(source)
	not source.path
	not source.ref
	msg := sprintf("%s: a Git source needs a path, or a ref for Helm values", [identity])
}

deny contains msg if {
	input.kind == "Application"
	some source in kube.app_sources(input)
	source.chart
	some value_file in object.get(source, ["helm", "valueFiles"], [])
	not hosted_value_file(value_file)
	msg := sprintf("%s: chart %s reads values from %q, and they must come from $values/gitops/clusters/plane-prod", [identity, source.chart, value_file])
}

hosted_value_file(value_file) if {
	not contains(value_file, "..")
	startswith(value_file, "$values/gitops/clusters/plane-prod/")
}

# Charts here render from helm.valueFiles and directories from their files, and that is all these checks read. Any other field of a
# source changes what runs with no file to read: helm.parameters, helm.valuesObject, a kustomize image, a directory filter, a plugin.
# An allow list, so a field Argo CD adds later needs a change here. scripts/ci/check-prod-evidence.sh and collect_hosted refuse
# .argocd-source files, which reach the same fields from a directory.
source_fields := {"repoURL", "targetRevision", "path", "chart", "ref", "helm"}

deny contains msg if {
	input.kind == "Application"
	some source in kube.app_sources(input)
	some field, _ in source
	not source_fields[field]
	msg := sprintf("%s: a source sets %s, which changes what runs and which nothing here reads. Put it in a file this tree holds", [identity, field])
}

deny contains msg if {
	input.kind == "Application"
	some source in kube.app_sources(input)
	some field, _ in object.get(source, "helm", {})
	field != "valueFiles"
	msg := sprintf("%s: a source sets helm.%s, which changes what runs and which nothing here reads. Put it in a values file", [identity, field])
}

# Every rule above reads a source, so an Application with none would pass them all, and a hydrator reads another branch.
deny contains msg if {
	input.kind == "Application"
	not kube.app_sources(input)
	msg := sprintf("%s: an Application here names spec.source or spec.sources, and this one neither", [identity])
}

deny contains msg if {
	input.kind == "Application"
	input.spec.sourceHydrator
	msg := sprintf("%s: no sourceHydrator. This cluster reads one branch, as it stands", [identity])
}

# A range would let a chart move with no change in Git.
deny contains msg if {
	input.kind == "Application"
	some source in kube.app_sources(input)
	source.chart
	not regex.match(`^v?[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]*)?$`, object.get(source, "targetRevision", ""))
	msg := sprintf("%s: chart %s is at %q, and a chart must be pinned to one version", [identity, source.chart, object.get(source, "targetRevision", "")])
}

# Only these exist on this cluster, and Terraform holds both.
deny contains msg if {
	input.kind == "Application"
	project := object.get(input, ["spec", "project"], "")
	not project in {"platform", plane_namespace}
	msg := sprintf("%s: project %q does not exist on this cluster, so use platform or %s", [identity, project, plane_namespace])
}

deny contains msg if {
	input.kind == "Application"
	server := object.get(input, ["spec", "destination", "server"], "")
	server != "https://kubernetes.default.svc"
	msg := sprintf("%s: destination server %q is not this cluster", [identity, server])
}

# The root reads applications/ alone, so an object that makes Applications would reach past that one list.
deny contains msg if {
	input.kind == "ApplicationSet"
	msg := sprintf("%s: no ApplicationSet. The root reads one directory of plain Applications", [identity])
}

# Git cannot widen these once Terraform has applied them, and this says so before it does.
deny contains msg if {
	input.kind == "AppProject"
	some repo in input.spec.sourceRepos
	not allowed_source_repo(repo)
	msg := sprintf("%s: sourceRepos has %q. This cluster's one Git source is %s, and anything else there must name a chart repository", [identity, repo, git_repo])
}

allowed_source_repo(repo) if repo == git_repo

allowed_source_repo(repo) if {
	not contains(repo, "*")
	not regex.match(`^(ssh://|git://|git@)|\.git$`, repo)
}

deny contains msg if {
	input.kind == "AppProject"
	input.metadata.name == plane_namespace
	some destination in input.spec.destinations
	destination.namespace != plane_namespace
	msg := sprintf("%s: this project deploys only to namespace %s, not %v", [identity, plane_namespace, destination.namespace])
}

deny contains msg if {
	input.kind == "AppProject"
	input.metadata.name == plane_namespace
	input.spec.clusterResourceWhitelist
	msg := sprintf("%s: this project must hold no clusterResourceWhitelist, because cluster scope is what it may never touch", [identity])
}

identity := kube.label(input) if input.metadata.name

else := "document"
