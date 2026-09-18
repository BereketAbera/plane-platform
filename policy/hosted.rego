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

# Grafana is the one console with a public route, and this is all of that route. Whole objects and not a pattern, so another host, path,
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

route_namespaces := {plane_namespace, grafana_namespace}

in_grafana_namespace if object.get(input.metadata, "namespace", "") == grafana_namespace

# Plane's route and Grafana's. Anywhere else it could only be another console's.
deny contains msg if {
	route_kinds[input.kind]
	not route_namespaces[object.get(input.metadata, "namespace", "")]
	msg := sprintf("%s: a route may sit only in namespace %s, or in %s for Grafana's, and the other consoles get none: reach them through an SSH tunnel and a port-forward", [identity, plane_namespace, grafana_namespace])
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
route_tls_secrets := {plane_namespace: tls_secret, grafana_namespace: grafana_tls_secret}

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
	some route in input.spec.routes
	some service in route.services
	not public_backend(service)
	msg := sprintf("%s: route %q reaches %v:%v. Hosted production gives no console a public route but Grafana's, at %s, and only Plane's own Services get one here", [identity, route.match, service.name, object.get(service, "port", "no port"), grafana_host])
}

# In Grafana's namespace a route is one of those two, and nothing else: not Grafana on another host or with /metrics, and not Prometheus
# or Alertmanager, which sit in the same namespace.
deny contains msg if {
	input.kind == "IngressRoute"
	in_grafana_namespace
	some route in input.spec.routes
	not grafana_routes[route]
	msg := sprintf("%s: route %q to %v is not one of Grafana's two. Hosted production gives no console a public route but Grafana's, at %s, as policy/hosted.rego writes it", [identity, object.get(route, "match", ""), object.get(route, "services", []), grafana_host])
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
