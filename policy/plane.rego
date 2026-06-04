# Plane-specific traps found by reading upstream. Run with --namespace plane.
package plane

import data.lib.kube
import rego.v1

banned_registry := "artifacts.plane.so"

required_bucket := "uploads"

# It fronts Docker Hub and shares its rate limit, and every digest is available from docker.io.
deny contains msg if {
	walk(input, [path, value])
	is_string(value)
	contains(value, banned_registry)
	msg := sprintf("%s: %s is banned, found at %v", [identity, banned_registry, path])
}

# export_task.py hardcodes '/uploads', so any other bucket produces broken export links.
deny contains msg if {
	walk(input, [path, value])
	path[count(path) - 1] == "AWS_S3_BUCKET_NAME"
	value != required_bucket
	msg := sprintf("%s: AWS_S3_BUCKET_NAME is %v, must be %q", [identity, value, required_bucket])
}

deny contains msg if {
	kube.is_workload(input)
	some c in kube.containers(input)
	some e in c.env
	e.name == "AWS_S3_BUCKET_NAME"
	e.value != required_bucket
	msg := sprintf("%s: container %q sets AWS_S3_BUCKET_NAME=%v, must be %q", [identity, c.name, e.value, required_bucket])
}

# Presigned URLs are path-style on the public host, so the Silo route must carry the bucket path.
deny contains msg if {
	input.kind == "IngressRoute"
	some route in input.spec.routes
	some svc in route.services
	endswith(svc.name, "-minio")
	not regex.match("`/uploads[/`]", route.match)
	msg := sprintf("%s: route to %s must match /uploads, got %s", [identity, svc.name, route.match])
}

# ADR 0015: nothing from Bitnami, image or chart. Reading every string catches an image, a chart
# repository and a Helm value alike. scripts/ci/lint.sh covers what never renders into a manifest.
bitnami_reference := `(?i)(^|[^a-z0-9])bitnami(legacy|charts|secure)?(/|$)|charts\.bitnami\.com`

deny contains msg if {
	walk(input, [path, value])
	is_string(value)
	regex.match(bitnami_reference, value)
	msg := sprintf("%s: nothing from Bitnami may be used (ADR 0015), found at %v", [identity, path])
}

# Contract section 3: the host each Plane namespace serves.
environment_hosts := {
	"plane-dev": "plane.dev.localhost",
	"plane-prod-sim": "plane.prod-sim.localhost",
}

# Traefik reads IngressRoutes from every namespace, and plane-dev may create them, so a dev route
# could capture plane.prod-sim.localhost. A rule stays on its host only when that Host is ANDed at
# the top: with no Host, or with an OR beside it, the rule also matches other hosts.
deny contains msg if {
	input.kind == "IngressRoute"
	host := environment_hosts[input.metadata.namespace]
	some route in input.spec.routes
	not stays_on_host(route.match, host)
	msg := sprintf("%s: route %q must be limited to %s, with any other condition ANDed to it", [identity, route.match, host_matcher(host)])
}

# The other direction: only that environment's namespace may name its host.
deny contains msg if {
	input.kind == "IngressRoute"
	some namespace, host in environment_hosts
	object.get(input.metadata, "namespace", "") != namespace
	some route in input.spec.routes
	contains(route.match, host)
	msg := sprintf("%s: route %q names %s, which only namespace %s may serve", [identity, route.match, host, namespace])
}

# Traefik applies TCP routers before HTTP routers on an entry point, so HostSNI(`*`) would take all
# of its traffic. No Plane environment needs one.
deny contains msg if {
	input.kind in {"IngressRouteTCP", "IngressRouteUDP"}
	environment_hosts[object.get(input.metadata, "namespace", "")]
	msg := sprintf("%s: %s is not allowed in a Plane namespace, because it could take traffic from every host", [identity, input.kind])
}

# Contract section 3: the internal UIs. Each Plane api must reach Traefik for the CoreDNS self-dial, and Traefik
# routes by Host header, so a route to one of these with no allow list lets that pod read every metric and silence
# alerts. monitoring/manifests/shared/ingress-routes.yaml has the reasoning, and tests/routes/internal-routes.sh
# proves it at runtime. A missing Middleware fails closed, with a 404, so naming it is the part to check.
#
# A route reaches a UI through its backend, and the host is only how it is spelled: the same Service under another
# host, under no host, or under a HostRegexp serves the same UI. So the namespace and the Service each decide, and the
# host is kept for a route that names one of these hosts with a backend of its own.
internal_namespaces := {"argocd", "monitoring", "infisical"}

internal_services := {"argocd-server", "kps-grafana", "kps-prometheus", "kps-alertmanager", "infisical"}

internal_hosts := {
	"argocd.localhost",
	"grafana.localhost",
	"prometheus.localhost",
	"alertmanager.localhost",
	"infisical.localhost",
}

allow_list := "node-network-only"

deny contains msg if {
	input.kind == "IngressRoute"
	some route in input.spec.routes
	needs_allow_list(route)
	not names_allow_list(route)
	msg := sprintf("%s: route %q is in a namespace that holds an internal UI, or names one by Service or host, so it must name the %s middleware", [identity, route.match, allow_list])
}

needs_allow_list(_) if internal_namespaces[object.get(input.metadata, "namespace", "")]

needs_allow_list(route) if names_internal_service(route)

# Traefik matches hosts in any case, and a HostRegexp would escape the dots.
needs_allow_list(route) if {
	some host in internal_hosts
	contains(replace(lower(route.match), `\`, ""), host)
}

names_internal_service(route) if {
	some service in route.services
	internal_services[service.name]
}

# A TCP router comes before every HTTP router on its entry point, as above, and this Middleware is an HTTP one, so
# nothing could hold the allow list on it.
deny contains msg if {
	input.kind in {"IngressRouteTCP", "IngressRouteUDP"}
	internal_namespaces[object.get(input.metadata, "namespace", "")]
	msg := sprintf("%s: %s is not allowed beside an internal UI, because it would have no %s middleware", [identity, input.kind, allow_list])
}

deny contains msg if {
	input.kind in {"IngressRouteTCP", "IngressRouteUDP"}
	not internal_namespaces[object.get(input.metadata, "namespace", "")]
	some route in input.spec.routes
	names_internal_service(route)
	msg := sprintf("%s: %s must not reach an internal UI, because it would have no %s middleware", [identity, input.kind, allow_list])
}

names_allow_list(route) if {
	some middleware in route.middlewares
	middleware.name == allow_list
}

# Naming it proves little if it admits everyone. Docker's default pool, contract section 3, and no ipStrategy,
# because with one Traefik would read X-Forwarded-For, which any client can set.
deny contains msg if {
	input.kind == "Middleware"
	input.metadata.name == allow_list
	input.spec != {"ipAllowList": {"sourceRange": ["172.16.0.0/12"]}}
	msg := sprintf("%s: must be an ipAllowList of exactly 172.16.0.0/12 with no ipStrategy", [identity])
}

host_matcher(host) := sprintf("Host(`%s`)", [host])

stays_on_host(match, host) if match == host_matcher(host)

stays_on_host(match, host) if {
	prefix := sprintf("%s && ", [host_matcher(host)])
	startswith(match, prefix)
	# What is left outside balanced parentheses, to three levels. Anything deeper leaves a parenthesis
	# behind and is refused, which errs on the safe side.
	outside := regex.replace(trim_prefix(match, prefix), `\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)`, "")
	not contains(outside, "||")
	not contains(outside, "(")
	not contains(outside, ")")
}

identity := kube.label(input) if input.metadata.name

else := "document"
