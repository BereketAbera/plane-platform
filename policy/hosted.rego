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

# Traefik reads routes from plane-prod alone. Anything elsewhere would be a console's route, or inert.
deny contains msg if {
	route_kinds[input.kind]
	object.get(input.metadata, "namespace", "") != plane_namespace
	msg := sprintf("%s: a route may sit only in namespace %s, and the consoles get none: reach them through an SSH tunnel and a port-forward", [identity, plane_namespace])
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
deny contains msg if {
	input.kind == "IngressRoute"
	tls := object.get(input.spec, "tls", {})
	tls != {"secretName": tls_secret}
	msg := sprintf("%s: tls is %v and must name only secretName %s", [identity, tls, tls_secret])
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
	some route in input.spec.routes
	some service in route.services
	not public_backend(service)
	msg := sprintf("%s: route %q reaches %v:%v. Hosted production gives no console a public route, and only Plane's own Services get one", [identity, route.match, service.name, object.get(service, "port", "no port")])
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

# ---- Where this cluster reads from

git_repo := "ssh://git@ssh.github.com:443/BereketAbera/plane-platform.git"

git_revision := "deploy/plane-prod"

# deploy/plane-prod holds only these two trees, so anything else would fail at sync, after the merge.
under_hosted_tree(path) if {
	not contains(path, "..")
	startswith(path, "gitops/clusters/plane-prod/")
}

under_hosted_tree(path) if {
	not contains(path, "..")
	some root in ["gitops/environments/prod", "gitops/environments/prod/"]
	path == root
}

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
	not under_hosted_tree(clean_path(path))
	msg := sprintf("%s: path %q is outside gitops/clusters/plane-prod and gitops/environments/prod, the only trees %s holds", [identity, path, git_revision])
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
