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
