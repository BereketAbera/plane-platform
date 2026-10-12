package hosted_test

import data.hosted
import rego.v1

good_app_vars := {
	"kind": "ConfigMap",
	"metadata": {"name": "plane-app-vars", "namespace": "plane-prod"},
	"data": {
		"WEB_URL": "https://wayline.bereket.dev",
		"CORS_ALLOWED_ORIGINS": "https://wayline.bereket.dev",
		"MINIO_ENDPOINT_SSL": "1",
		"ENABLE_SIGNUP": "0",
		"DEBUG": "0",
	},
}

with_var(key, value) := object.union(good_app_vars, {"data": {key: value}})

without_var(key) := json.remove(good_app_vars, [sprintf("data/%s", [key])])

test_good_app_vars_accepted if {
	count(hosted.deny) == 0 with input as good_app_vars
}

test_http_web_url_rejected if {
	count(hosted.deny) == 1 with input as with_var("WEB_URL", "http://wayline.bereket.dev")
}

test_another_host_in_web_url_rejected if {
	count(hosted.deny) == 1 with input as with_var("WEB_URL", "https://plane.dev.localhost")
}

test_http_origin_rejected if {
	count(hosted.deny) == 1 with input as with_var("CORS_ALLOWED_ORIGINS", "http://wayline.bereket.dev,https://wayline.bereket.dev")
}

# Empty also takes Secure off the cookies, and a star lets any site in.
test_empty_or_open_origins_rejected if {
	count(hosted.deny) == 1 with input as with_var("CORS_ALLOWED_ORIGINS", "")
	count(hosted.deny) == 1 with input as with_var("CORS_ALLOWED_ORIGINS", "*")
}

test_open_sign_up_rejected if {
	count(hosted.deny) == 1 with input as with_var("ENABLE_SIGNUP", "1")
}

test_http_presigned_urls_rejected if {
	count(hosted.deny) == 1 with input as with_var("MINIO_ENDPOINT_SSL", "0")
}

test_a_missing_value_rejected if {
	count(hosted.deny) == 1 with input as without_var("WEB_URL")
	count(hosted.deny) == 1 with input as without_var("CORS_ALLOWED_ORIGINS")
	count(hosted.deny) == 1 with input as without_var("ENABLE_SIGNUP")
}

test_other_config_maps_ignored if {
	count(hosted.deny) == 0 with input as {"kind": "ConfigMap", "metadata": {"name": "other"}, "data": {"note": "http://x"}}
}

deployment(namespace, name, image, extra) := {
	"kind": "Deployment",
	"metadata": {"name": name, "namespace": namespace},
	"spec": {"template": {"spec": {"containers": [object.union({"name": "c", "image": image}, extra)]}}},
}

ghcr_web := "ghcr.io/bereketabera/wayline/web@sha256:0000000000000000000000000000000000000000000000000000000000000000"

test_ghcr_image_accepted if {
	count(hosted.deny) == 0 with input as deployment("plane-prod", "plane-web-wl", ghcr_web, {})
}

test_upstream_image_accepted if {
	count(hosted.deny) == 0 with input as deployment("plane-prod", "plane-pgdb-wl", "docker.io/library/postgres:15.19-alpine@sha256:abc", {})
}

test_localhost_image_rejected if {
	denied := hosted.deny with input as deployment("plane-prod", "plane-web-wl", "localhost:5001/wayline/web@sha256:abc", {})
	count(denied) == 2 # a local registry, and Wayline's image anywhere but GHCR
}

test_loopback_and_kind_registries_rejected if {
	count(hosted.deny) == 2 with input as deployment("plane-prod", "plane-web-wl", "127.0.0.1:5001/wayline/web@sha256:abc", {})
	count(hosted.deny) == 2 with input as deployment("plane-prod", "plane-web-wl", "kind-registry:5000/wayline/web@sha256:abc", {})
	count(hosted.deny) == 1 with input as deployment("monitoring", "x", "localhost:5001/other@sha256:abc", {})
}

test_a_local_image_in_an_init_container_rejected if {
	doc := {
		"kind": "Job",
		"metadata": {"name": "plane-api-migrate-1", "namespace": "plane-prod"},
		"spec": {"template": {"spec": {
			"containers": [{"name": "c", "image": ghcr_web}],
			"initContainers": [{"name": "i", "image": "localhost:5001/x@sha256:abc"}],
		}}},
	}
	count(hosted.deny) == 1 with input as doc
}

test_a_local_image_on_an_operator_resource_rejected if {
	doc := {"kind": "Prometheus", "metadata": {"name": "x", "namespace": "monitoring"}, "spec": {"image": "localhost:5001/prometheus@sha256:abc"}}
	count(hosted.deny) == 1 with input as doc
}

test_wayline_image_from_another_registry_rejected if {
	count(hosted.deny) == 1 with input as deployment("plane-prod", "plane-web-wl", "docker.io/someone/wayline/web@sha256:abc", {})
}

test_container_env_cannot_undo_the_config_map if {
	count(hosted.deny) == 1 with input as deployment("plane-prod", "plane-api-wl", ghcr_web, {"env": [{"name": "WEB_URL", "value": "http://wayline.bereket.dev"}]})
	count(hosted.deny) == 1 with input as deployment("plane-prod", "plane-api-wl", ghcr_web, {"env": [{"name": "CORS_ALLOWED_ORIGINS", "valueFrom": {"secretKeyRef": {"name": "x", "key": "y"}}}]})
	count(hosted.deny) == 0 with input as deployment("plane-prod", "plane-api-wl", ghcr_web, {"env": [{"name": "WEB_URL", "value": "https://wayline.bereket.dev"}]})
}

route_spec := {
	"entryPoints": ["websecure"],
	"routes": [{"match": "Host(`wayline.bereket.dev`) && PathPrefix(`/`)", "kind": "Rule", "services": [{"name": "plane-web", "port": 3000}]}],
	"tls": {"secretName": "wayline-tls"},
}

route_doc(namespace, spec) := {"kind": "IngressRoute", "metadata": {"name": "plane-ingress", "namespace": namespace}, "spec": spec}

good_route := route_doc("plane-prod", route_spec)

route_to(name, port) := route_doc("plane-prod", object.union(route_spec, {"routes": [{"match": "Host(`wayline.bereket.dev`)", "kind": "Rule", "services": [{"name": name, "port": port}]}]}))

test_good_route_accepted if {
	count(hosted.deny) == 0 with input as good_route
}

test_web_entry_point_rejected if {
	count(hosted.deny) == 1 with input as route_doc("plane-prod", object.union(route_spec, {"entryPoints": ["web"]}))
	count(hosted.deny) == 1 with input as route_doc("plane-prod", object.union(route_spec, {"entryPoints": ["web", "websecure"]}))
}

# With no entry points Traefik attaches a route to all of them.
test_no_entry_points_rejected if {
	count(hosted.deny) == 1 with input as route_doc("plane-prod", json.remove(route_spec, ["entryPoints"]))
}

test_no_tls_rejected if {
	count(hosted.deny) == 1 with input as route_doc("plane-prod", json.remove(route_spec, ["tls"]))
}

test_another_certificate_or_a_resolver_rejected if {
	count(hosted.deny) == 1 with input as route_doc("plane-prod", object.union(route_spec, {"tls": {"secretName": "other"}}))
	count(hosted.deny) == 1 with input as route_doc("plane-prod", object.union(route_spec, {"tls": {"certResolver": "letsencrypt"}}))
}

test_a_route_to_any_console_rejected if {
	every console in [
		["argocd-server", 80],
		["kps-grafana", 80],
		["kps-prometheus", 9090],
		["kps-alertmanager", 9093],
		["infisical", 8080],
		["plane-rabbitmq", 15672],
		["traefik", 8080],
	] {
		count(hosted.deny) == 1 with input as route_to(console[0], console[1])
	}
}

test_every_public_backend_accepted if {
	count(hosted.deny) == 0 with input as route_to("plane-web", 3000)
	count(hosted.deny) == 0 with input as route_to("plane-admin", 3000)
	count(hosted.deny) == 0 with input as route_to("plane-space", 3000)
	count(hosted.deny) == 0 with input as route_to("plane-live", 3000)
	count(hosted.deny) == 0 with input as route_to("plane-api", 8000)
	count(hosted.deny) == 0 with input as route_to("plane-minio", 9000)
}

# The same Service, and the other port is the console.
test_silo_console_port_rejected if {
	count(hosted.deny) == 1 with input as route_to("plane-minio", 9090)
}

test_a_route_reaching_out_of_its_namespace_rejected if {
	doc := route_doc("plane-prod", object.union(route_spec, {"routes": [{"match": "Host(`wayline.bereket.dev`)", "services": [{"name": "plane-web", "port": 3000, "namespace": "monitoring"}]}]}))
	count(hosted.deny) == 1 with input as doc
}

test_traefik_internal_service_rejected if {
	doc := route_doc("plane-prod", object.union(route_spec, {"routes": [{"match": "Host(`wayline.bereket.dev`)", "services": [{"name": "api@internal", "kind": "TraefikService"}]}]}))
	count(hosted.deny) == 1 with input as doc
}

test_a_route_in_another_namespace_rejected if {
	count(hosted.deny) == 1 with input as route_doc("argocd", route_spec)
	count(hosted.deny) == 1 with input as route_doc("cert-manager", route_spec)
	count(hosted.deny) == 1 with input as {"kind": "IngressRoute", "metadata": {"name": "x"}, "spec": route_spec}
}

test_tcp_and_udp_routes_rejected if {
	count(hosted.deny) == 1 with input as {"kind": "IngressRouteTCP", "metadata": {"name": "x", "namespace": "plane-prod"}, "spec": {}}
	count(hosted.deny) == 1 with input as {"kind": "IngressRouteUDP", "metadata": {"name": "x", "namespace": "monitoring"}, "spec": {}}
	count(hosted.deny) == 2 with input as {"kind": "IngressRouteUDP", "metadata": {"name": "x", "namespace": "argocd"}, "spec": {}}
	count(hosted.deny) == 1 with input as {"kind": "IngressRouteTCP", "metadata": {"name": "x", "namespace": "infisical"}, "spec": {}}
}

# Written out here and not read from the policy, so a change there has to be made twice.
grafana_login_route := {
	"kind": "Rule",
	"match": "Host(`grafana.bereket.dev`) && Method(`POST`) && (PathPrefix(`/login`) || PathPrefix(`/api/login`))",
	"middlewares": [{"name": "grafana-login-limit"}],
	"services": [{"name": "kps-grafana", "port": 80}],
}

grafana_page_route := {
	"kind": "Rule",
	"match": "Host(`grafana.bereket.dev`) && !PathPrefix(`/metrics`)",
	"services": [{"name": "kps-grafana", "port": 80}],
}

grafana_spec := {
	"entryPoints": ["websecure"],
	"routes": [grafana_login_route, grafana_page_route],
	"tls": {"secretName": "grafana-tls"},
}

grafana_route := route_doc("monitoring", grafana_spec)

# The page route swapped for this one, and the rule that names each swap.
grafana_with(route) := route_doc("monitoring", object.union(grafana_spec, {"routes": [grafana_login_route, route]}))

page_rule(match, service) := {"kind": "Rule", "match": match, "services": [service]}

says(doc, text) if {
	denied := hosted.deny with input as doc
	some msg in denied
	contains(msg, text)
}

not_grafanas := "is not one of Grafana's two"

test_grafana_route_accepted if {
	count(hosted.deny) == 0 with input as grafana_route
}

test_grafana_routes_in_either_order_accepted if {
	count(hosted.deny) == 0 with input as route_doc("monitoring", object.union(grafana_spec, {"routes": [grafana_page_route, grafana_login_route]}))
}

test_grafana_on_any_other_host_rejected if {
	every match in [
		"Host(`metrics.bereket.dev`) && !PathPrefix(`/metrics`)",
		"Host(`grafana.wayline.bereket.dev`) && !PathPrefix(`/metrics`)",
		"Host(`grafana.bereket.dev`) || Host(`other.bereket.dev`)",
		"HostRegexp(`^grafana[.]bereket[.]dev$`) && !PathPrefix(`/metrics`)",
		"PathPrefix(`/`) && !PathPrefix(`/metrics`)",
	] {
		says(grafana_with(page_rule(match, {"name": "kps-grafana", "port": 80})), not_grafanas)
	}
}

test_grafana_with_its_metrics_public_rejected if {
	says(grafana_with(page_rule("Host(`grafana.bereket.dev`)", {"name": "kps-grafana", "port": 80})), not_grafanas)
	says(grafana_with(page_rule("Host(`grafana.bereket.dev`) && !Path(`/other`)", {"name": "kps-grafana", "port": 80})), not_grafanas)
}

test_grafana_on_the_web_entry_point_rejected if {
	count(hosted.deny) == 1 with input as route_doc("monitoring", object.union(grafana_spec, {"entryPoints": ["web"]}))
	count(hosted.deny) == 1 with input as route_doc("monitoring", object.union(grafana_spec, {"entryPoints": ["web", "websecure"]}))
	count(hosted.deny) == 1 with input as route_doc("monitoring", json.remove(grafana_spec, ["entryPoints"]))
}

test_grafana_without_its_own_certificate_rejected if {
	says(route_doc("monitoring", json.remove(grafana_spec, ["tls"])), "tls is {} and must name only secretName grafana-tls")
	says(route_doc("monitoring", object.union(grafana_spec, {"tls": {"secretName": "wayline-tls"}})), "must name only secretName grafana-tls")
	says(route_doc("monitoring", object.union(grafana_spec, {"tls": {"certResolver": "letsencrypt"}})), "must name only secretName grafana-tls")
}

test_another_console_under_the_grafana_host_rejected if {
	every service in [
		{"name": "kps-prometheus", "port": 9090},
		{"name": "kps-alertmanager", "port": 9093},
		{"name": "loki", "port": 3100},
		{"name": "kps-grafana", "port": 3000},
		{"name": "api@internal", "kind": "TraefikService"},
		{"name": "argocd-server", "namespace": "argocd", "port": 80},
		{"name": "kps-grafana", "namespace": "other", "port": 80},
	] {
		says(grafana_with(page_rule("Host(`grafana.bereket.dev`) && !PathPrefix(`/metrics`)", service)), not_grafanas)
	}
}

test_prometheus_on_a_path_of_the_grafana_host_rejected if {
	extra := page_rule("Host(`grafana.bereket.dev`) && PathPrefix(`/prometheus`)", {"name": "kps-prometheus", "port": 9090})
	says(route_doc("monitoring", object.union(grafana_spec, {"routes": [grafana_login_route, grafana_page_route, extra]})), not_grafanas)
}

test_grafana_login_without_its_limit_rejected if {
	says(route_doc("monitoring", object.union(grafana_spec, {"routes": [grafana_page_route]})), "has no route")
	unlimited := json.remove(grafana_login_route, ["middlewares"])
	says(route_doc("monitoring", object.union(grafana_spec, {"routes": [unlimited, grafana_page_route]})), not_grafanas)
}

test_grafana_page_route_missing_rejected if {
	says(route_doc("monitoring", object.union(grafana_spec, {"routes": [grafana_login_route]})), "has no route")
}

test_a_middleware_on_the_grafana_page_route_rejected if {
	says(grafana_with(object.union(grafana_page_route, {"middlewares": [{"name": "rewrite"}]})), not_grafanas)
}

test_grafana_route_in_another_namespace_rejected if {
	says(route_doc("plane-prod", grafana_spec), "gives no console a public route but Grafana's")
	says(route_doc("traefik", grafana_spec), "a route may sit only in namespace")
	says(route_doc("argocd", grafana_spec), "a route may sit only in namespace")
}

test_plane_route_in_the_grafana_namespace_rejected if {
	says(route_doc("monitoring", route_spec), not_grafanas)
	says(route_doc("monitoring", route_spec), "must name only secretName grafana-tls")
}

middleware(namespace, name, spec) := {"kind": "Middleware", "metadata": {"name": name, "namespace": namespace}, "spec": spec}

limit_with(criterion) := middleware("monitoring", "grafana-login-limit", {"rateLimit": {"average": 5, "period": "1m", "burst": 5, "sourceCriterion": criterion}})

test_grafana_login_limit_accepted if {
	count(hosted.deny) == 0 with input as limit_with({"ipStrategy": {"depth": 0}})
}

# Any of these counts what a client sends, so a client that changes it is never limited.
test_a_limit_on_anything_but_the_connection_rejected if {
	count(hosted.deny) == 1 with input as limit_with({"ipStrategy": {"depth": 1}})
	count(hosted.deny) == 1 with input as limit_with({"ipStrategy": {"excludedIPs": ["0.0.0.0/0"]}})
	count(hosted.deny) == 1 with input as limit_with({"requestHeaderName": "X-Forwarded-For"})
	count(hosted.deny) == 1 with input as limit_with({"requestHost": true})
}

test_a_looser_limit_rejected if {
	count(hosted.deny) == 1 with input as middleware("monitoring", "grafana-login-limit", {"rateLimit": {"average": 5000, "period": "1m", "burst": 5, "sourceCriterion": {"ipStrategy": {"depth": 0}}}})
	count(hosted.deny) == 1 with input as middleware("monitoring", "grafana-login-limit", {"stripPrefix": {"prefixes": ["/x"]}})
}

test_another_middleware_beside_grafana_rejected if {
	count(hosted.deny) == 1 with input as middleware("monitoring", "rewrite", {"replacePath": {"path": "/metrics"}})
}

test_middlewares_elsewhere_ignored if {
	count(hosted.deny) == 0 with input as middleware("plane-prod", "plane-body-limit", {"buffering": {"maxRequestBodyBytes": 5242880}})
}

test_ingress_and_gateway_api_in_git_rejected if {
	count(hosted.deny) == 1 with input as {"kind": "Ingress", "metadata": {"name": "x", "namespace": "plane-prod"}}
	count(hosted.deny) == 1 with input as {"kind": "HTTPRoute", "metadata": {"name": "x", "namespace": "plane-prod"}}
	count(hosted.deny) == 1 with input as {"kind": "Gateway", "metadata": {"name": "x", "namespace": "traefik"}}
}

# Traefik's chart needs this one, and it routes nothing by itself.
test_ingress_class_accepted if {
	count(hosted.deny) == 0 with input as {"kind": "IngressClass", "metadata": {"name": "traefik"}}
}

service(spec) := {"kind": "Service", "metadata": {"name": "x", "namespace": "plane-prod"}, "spec": spec}

test_cluster_ip_services_accepted if {
	count(hosted.deny) == 0 with input as service({"ports": [{"port": 80}]})
	count(hosted.deny) == 0 with input as service({"type": "ClusterIP", "ports": [{"port": 80}]})
}

test_node_port_and_load_balancer_rejected if {
	count(hosted.deny) == 1 with input as service({"type": "NodePort"})
	count(hosted.deny) == 1 with input as service({"type": "LoadBalancer"})
}

test_external_ips_rejected if {
	count(hosted.deny) == 1 with input as service({"externalIPs": ["5.253.234.127"]})
}

daemon(namespace, spec) := {
	"kind": "DaemonSet",
	"metadata": {"name": "x", "namespace": namespace},
	"spec": {"template": {"spec": object.union({"containers": [{"name": "c", "image": "i"}]}, spec)}},
}

test_host_network_only_for_node_exporter if {
	count(hosted.deny) == 0 with input as daemon("monitoring-agents", {"hostNetwork": true})
	count(hosted.deny) == 1 with input as daemon("plane-prod", {"hostNetwork": true})
	count(hosted.deny) == 1 with input as json.remove(daemon("x", {"hostNetwork": true}), ["metadata/namespace"])
	count(hosted.deny) == 0 with input as daemon("plane-prod", {"hostNetwork": false})
}

with_port(namespace, port) := deployment(namespace, "x", "i", {"ports": [port]})

test_host_ports_only_for_traefik if {
	count(hosted.deny) == 0 with input as with_port("traefik", {"containerPort": 8000, "hostPort": 80})
	count(hosted.deny) == 0 with input as with_port("traefik", {"containerPort": 8443, "hostPort": 443})
	count(hosted.deny) == 0 with input as with_port("monitoring-agents", {"containerPort": 9100, "hostPort": 9100})
	count(hosted.deny) == 1 with input as with_port("traefik", {"containerPort": 8080, "hostPort": 8080})
	count(hosted.deny) == 1 with input as with_port("plane-prod", {"containerPort": 3000, "hostPort": 443})
	count(hosted.deny) == 0 with input as with_port("plane-prod", {"containerPort": 3000})
}

test_a_traefik_acme_resolver_rejected if {
	count(hosted.deny) == 1 with input as deployment("traefik", "traefik", "i", {"args": ["--certificatesresolvers.le.acme.email=x"]})
	count(hosted.deny) == 0 with input as deployment("traefik", "traefik", "i", {"args": ["--entryPoints.web.address=:8000"]})
}

issuer(ingress) := {
	"kind": "ClusterIssuer",
	"metadata": {"name": "letsencrypt-staging"},
	"spec": {"acme": {"solvers": [{"http01": {"ingress": ingress}}]}},
}

test_solver_on_a_cluster_ip_accepted if {
	count(hosted.deny) == 0 with input as issuer({"ingressClassName": "traefik", "serviceType": "ClusterIP"})
}

# cert-manager's default when the field is left out.
test_solver_on_a_node_port_rejected if {
	count(hosted.deny) == 1 with input as issuer({"ingressClassName": "traefik"})
	count(hosted.deny) == 1 with input as issuer({"ingressClassName": "traefik", "serviceType": "NodePort"})
}

git_url := "ssh://git@ssh.github.com:443/BereketAbera/plane-platform.git"

application(source) := {
	"kind": "Application",
	"metadata": {"name": "x", "namespace": "argocd"},
	"spec": {"project": "platform", "destination": {"server": "https://kubernetes.default.svc", "namespace": "monitoring"}, "source": source},
}

plain_source(path) := {"repoURL": git_url, "targetRevision": "deploy/plane-prod", "path": path}

root_application := json.patch(application(plain_source("gitops/clusters/plane-prod/applications")), [{"op": "replace", "path": "/metadata/name", "value": "root"}])

test_git_sources_in_the_two_trees_accepted if {
	count(hosted.deny) == 0 with input as root_application
	count(hosted.deny) == 0 with input as application(plain_source("gitops/clusters/plane-prod/platform/backup"))
	count(hosted.deny) == 0 with input as application(plain_source("./gitops/clusters/plane-prod/platform/backup/"))
	count(hosted.deny) == 0 with input as application(plain_source("gitops/environments/prod"))
	count(hosted.deny) == 0 with input as application(plain_source("gitops/environments/prod/"))
}

test_local_git_remote_rejected if {
	count(hosted.deny) == 1 with input as application({"repoURL": "git://plane-git/plane-platform.git", "targetRevision": "deploy/plane-prod", "path": "gitops/environments/prod"})
}

test_https_form_of_the_same_repository_rejected if {
	count(hosted.deny) == 1 with input as application({"repoURL": "https://github.com/BereketAbera/plane-platform.git", "targetRevision": "deploy/plane-prod", "path": "gitops/environments/prod"})
}

test_main_or_a_floating_revision_rejected if {
	count(hosted.deny) == 1 with input as application({"repoURL": git_url, "targetRevision": "main", "path": "gitops/environments/prod"})
	count(hosted.deny) == 1 with input as application({"repoURL": git_url, "targetRevision": "HEAD", "path": "gitops/environments/prod"})
	count(hosted.deny) == 1 with input as application({"repoURL": git_url, "path": "gitops/environments/prod"})
}

test_paths_outside_the_two_trees_rejected if {
	count(hosted.deny) == 1 with input as application(plain_source("gitops/applications"))
	count(hosted.deny) == 1 with input as application(plain_source("gitops/environments/prod-sim"))
	count(hosted.deny) == 1 with input as application(plain_source("gitops/environments/dev"))
	count(hosted.deny) == 1 with input as application(plain_source("helm/plane/overlays/prod"))
	count(hosted.deny) == 1 with input as application(plain_source("gitops/clusters/plane-prod"))
	count(hosted.deny) == 1 with input as application(plain_source("gitops/clusters/plane-prod/../../applications"))
	count(hosted.deny) == 1 with input as application(plain_source("."))
}

# Inside the tree, and nothing checks what they hold.
test_paths_no_check_reads_rejected if {
	count(hosted.deny) == 1 with input as application(plain_source("gitops/clusters/plane-prod/values"))
	count(hosted.deny) == 1 with input as application(plain_source("gitops/clusters/plane-prod/extras"))
	count(hosted.deny) == 1 with input as application(plain_source("gitops/clusters/plane-prod/platform"))
	count(hosted.deny) == 1 with input as application(plain_source("gitops/clusters/plane-prod/platform/backup/../.."))
	count(hosted.deny) == 1 with input as application(plain_source("gitops/clusters/plane-prod/bootstrap-chart"))
	count(hosted.deny) == 1 with input as application(plain_source("gitops/clusters/plane-prod/applications"))
}

test_overrides_on_a_source_rejected if {
	count(hosted.deny) == 1 with input as application(object.union(plain_source("gitops/clusters/plane-prod/platform/backup"), {"kustomize": {"images": ["docker.io/restic/restic=ghcr.io/attacker/evil:latest"]}}))
	count(hosted.deny) == 1 with input as application(object.union(plain_source("gitops/clusters/plane-prod/platform/backup"), {"directory": {"recurse": true}}))
	count(hosted.deny) == 1 with input as application(object.union(plain_source("gitops/clusters/plane-prod/platform/backup"), {"plugin": {"name": "anything"}}))
}

chart_with_helm(helm) := json.patch(chart_application(hosted_values, "42.3.0", values_ref), [{"op": "add", "path": "/spec/sources/0/helm", "value": helm}])

test_helm_overrides_rejected if {
	count(hosted.deny) == 1 with input as chart_with_helm({"valueFiles": [hosted_values], "parameters": [{"name": "image.registry", "value": "ghcr.io"}]})
	count(hosted.deny) == 1 with input as chart_with_helm({"valueFiles": [hosted_values], "fileParameters": [{"name": "x", "path": "y"}]})
	count(hosted.deny) == 1 with input as chart_with_helm({"valueFiles": [hosted_values], "values": "image: {registry: ghcr.io}"})
	count(hosted.deny) == 1 with input as chart_with_helm({"valueFiles": [hosted_values], "valuesObject": {"extraObjects": []}})
	count(hosted.deny) == 1 with input as chart_with_helm({"valueFiles": [hosted_values], "releaseName": "other"})
}

test_helm_with_only_value_files_accepted if {
	count(hosted.deny) == 0 with input as chart_with_helm({"valueFiles": [hosted_values]})
}

test_application_with_no_source_rejected if {
	count(hosted.deny) == 1 with input as json.remove(application(plain_source("gitops/environments/prod")), ["spec/source"])
}

test_source_hydrator_rejected if {
	count(hosted.deny) == 2 with input as json.patch(json.remove(application(plain_source("gitops/environments/prod")), ["spec/source"]), [{"op": "add", "path": "/spec/sourceHydrator", "value": {"drySource": {"repoURL": git_url, "targetRevision": "main", "path": "anything"}}}])
}

test_git_source_with_no_path_and_no_ref_rejected if {
	count(hosted.deny) == 1 with input as application({"repoURL": git_url, "targetRevision": "deploy/plane-prod"})
}

chart_application(value_file, version, git_part) := {
	"kind": "Application",
	"metadata": {"name": "traefik", "namespace": "argocd"},
	"spec": {
		"project": "platform",
		"destination": {"server": "https://kubernetes.default.svc", "namespace": "traefik"},
		"sources": [
			{"repoURL": "https://traefik.github.io/charts", "chart": "traefik", "targetRevision": version, "helm": {"valueFiles": [value_file]}},
			git_part,
		],
	},
}

values_ref := {"repoURL": git_url, "targetRevision": "deploy/plane-prod", "ref": "values"}

hosted_values := "$values/gitops/clusters/plane-prod/values/traefik.yaml"

test_chart_with_values_from_the_tree_accepted if {
	count(hosted.deny) == 0 with input as chart_application(hosted_values, "42.3.0", values_ref)
	count(hosted.deny) == 0 with input as chart_application(hosted_values, "v1.21.3", values_ref)
}

test_chart_values_outside_the_tree_rejected if {
	count(hosted.deny) == 1 with input as chart_application("$values/helm/values/traefik.yaml", "42.3.0", values_ref)
	count(hosted.deny) == 1 with input as chart_application("$values/gitops/clusters/plane-prod/../../../helm/values/traefik.yaml", "42.3.0", values_ref)
	count(hosted.deny) == 1 with input as chart_application("values-production.yaml", "42.3.0", values_ref)
}

test_values_ref_from_elsewhere_rejected if {
	count(hosted.deny) == 1 with input as chart_application(hosted_values, "42.3.0", object.union(values_ref, {"repoURL": "git://plane-git/plane-platform.git"}))
	count(hosted.deny) == 1 with input as chart_application(hosted_values, "42.3.0", object.union(values_ref, {"targetRevision": "main"}))
}

test_chart_version_range_rejected if {
	count(hosted.deny) == 1 with input as chart_application(hosted_values, "42.*", values_ref)
	count(hosted.deny) == 1 with input as chart_application(hosted_values, ">=42", values_ref)
	count(hosted.deny) == 1 with input as chart_application(hosted_values, "", values_ref)
}

test_local_only_project_rejected if {
	doc := json.patch(application(plain_source("gitops/environments/prod")), [{"op": "replace", "path": "/spec/project", "value": "plane-dev"}])
	count(hosted.deny) == 1 with input as doc
}

test_plane_prod_project_accepted if {
	doc := json.patch(application(plain_source("gitops/environments/prod")), [{"op": "replace", "path": "/spec/project", "value": "plane-prod"}])
	count(hosted.deny) == 0 with input as doc
}

test_another_cluster_rejected if {
	doc := json.patch(application(plain_source("gitops/environments/prod")), [{"op": "replace", "path": "/spec/destination/server", "value": "https://example.com:6443"}])
	count(hosted.deny) == 1 with input as doc
}

test_application_set_rejected if {
	count(hosted.deny) == 1 with input as {"kind": "ApplicationSet", "metadata": {"name": "x", "namespace": "argocd"}}
}

project(name, spec) := {"kind": "AppProject", "metadata": {"name": name, "namespace": "argocd"}, "spec": spec}

test_platform_project_with_chart_repositories_accepted if {
	count(hosted.deny) == 0 with input as project("platform", {"sourceRepos": [git_url, "https://traefik.github.io/charts", "quay.io/jetstack/charts"], "clusterResourceWhitelist": [{"group": "*", "kind": "*"}], "destinations": [{"namespace": "*"}]})
}

test_project_with_any_other_git_repository_rejected if {
	count(hosted.deny) == 1 with input as project("platform", {"sourceRepos": ["*"]})
	count(hosted.deny) == 1 with input as project("platform", {"sourceRepos": ["git://plane-git/plane-platform.git"]})
	count(hosted.deny) == 1 with input as project("platform", {"sourceRepos": ["https://github.com/someone/else.git"]})
	count(hosted.deny) == 1 with input as project("platform", {"sourceRepos": ["ssh://git@github.com/someone/else"]})
}

test_plane_project_stays_in_its_namespace if {
	count(hosted.deny) == 0 with input as project("plane-prod", {"sourceRepos": [git_url], "destinations": [{"namespace": "plane-prod"}]})
	count(hosted.deny) == 1 with input as project("plane-prod", {"sourceRepos": [git_url], "destinations": [{"namespace": "*"}]})
	count(hosted.deny) == 1 with input as project("plane-prod", {"sourceRepos": [git_url], "destinations": [{"namespace": "plane-prod"}], "clusterResourceWhitelist": [{"group": "*", "kind": "*"}]})
}

test_unrelated_document_ignored if {
	count(hosted.deny) == 0 with input as {"kind": "NetworkPolicy", "metadata": {"name": "x", "namespace": "plane-prod"}}
	count(hosted.deny) == 0 with input as {}
}

# Grafana's login and its token. The good grafana.ini is the render's, in its order, with the rest of its sections cut.
good_grafana_ini := concat("\n", [
	"[analytics]",
	"check_for_updates = false",
	"[auth.anonymous]",
	"enabled = false",
	"hide_version = true",
	"[auth.basic]",
	"enabled = false",
	"[auth.proxy]",
	"enabled = false",
	"[security]",
	"cookie_secure = true",
	"disable_brute_force_login_protection = false",
	"disable_ip_address_login_protection = false",
	"disable_username_login_protection = true",
	"[users]",
	"allow_sign_up = false",
	"",
])

grafana_config(ini) := {"kind": "ConfigMap", "metadata": {"name": "kps-grafana", "namespace": "monitoring"}, "data": {"grafana.ini": ini}}

# The good file with one line swapped for another, or taken out when the new one is empty.
grafana_ini_with(old, new) := replace(good_grafana_ini, sprintf("%s\n", [old]), new)

test_grafana_ini_accepted if {
	count(hosted.deny) == 0 with input as grafana_config(good_grafana_ini)
}

test_grafana_ini_with_any_guard_reverted_rejected if {
	every swap in [
		["[auth.basic]\nenabled = false", "[auth.basic]\nenabled = true", "[auth.basic] enabled = true"],
		["disable_username_login_protection = true", "disable_username_login_protection = false", "[security] disable_username_login_protection = false"],
		["disable_ip_address_login_protection = false", "disable_ip_address_login_protection = true", "[security] disable_ip_address_login_protection = true"],
		["disable_brute_force_login_protection = false", "disable_brute_force_login_protection = true", "[security] disable_brute_force_login_protection = true"],
		["hide_version = true", "hide_version = false", "[auth.anonymous] hide_version = false"],
		["[auth.anonymous]\nenabled = false", "[auth.anonymous]\nenabled = true", "[auth.anonymous] enabled = true"],
		["[auth.proxy]\nenabled = false", "[auth.proxy]\nenabled = true", "[auth.proxy] enabled = true"],
	] {
		doc := grafana_config(replace(good_grafana_ini, swap[0], swap[1]))
		count(hosted.deny) == 1 with input as doc
		says(doc, sprintf("grafana.ini sets %s, and it must be", [swap[2]]))
	}
}

# Grafana's own default is what runs when the line is gone: basic auth on, and a count per username.
test_grafana_ini_with_any_guard_missing_rejected if {
	every line in [
		"disable_username_login_protection = true",
		"disable_ip_address_login_protection = false",
		"disable_brute_force_login_protection = false",
		"hide_version = true",
	] {
		doc := grafana_config(grafana_ini_with(line, ""))
		count(hosted.deny) == 1 with input as doc
		says(doc, "grafana.ini must set")
	}
	says(grafana_config(replace(good_grafana_ini, "[auth.basic]\nenabled = false\n", "")), "must set [auth.basic] enabled = false")
	count(hosted.deny) == 7 with input as grafana_config("")
	count(hosted.deny) == 7 with input as {"kind": "ConfigMap", "metadata": {"name": "kps-grafana", "namespace": "monitoring"}, "data": {}}
}

# A second line for the same key, a key under another section, or one Grafana would not read as that key.
test_grafana_ini_read_as_grafana_reads_it if {
	says(grafana_config(concat("", [good_grafana_ini, "[auth.basic]\nenabled = true\n"])), "[auth.basic] enabled = true")
	says(grafana_config(replace(good_grafana_ini, "[auth.basic]\nenabled = false\n", "[auth]\nbasic.enabled = false\n")), "must set [auth.basic] enabled = false")
	says(grafana_config(replace(good_grafana_ini, "[auth.basic]\nenabled = false\n", "[auth.basic]\nEnabled = false\n")), "must set [auth.basic] enabled = false")
	says(grafana_config(replace(good_grafana_ini, "[auth.basic]\nenabled = false\n", "[auth.basic]\n; enabled = false\n")), "must set [auth.basic] enabled = false")
	says(grafana_config(replace(good_grafana_ini, "[auth.basic]\nenabled = false\n", "[auth.basic]\nenabled = $__env{BASIC}\n")), "[auth.basic] enabled = $__env{BASIC}")
	count(hosted.deny) == 0 with input as grafana_config(replace(good_grafana_ini, "[auth.basic]\nenabled = false\n", "[ auth.basic ]\n  enabled   =   false  \n"))
}

test_other_grafana_ini_ignored if {
	count(hosted.deny) == 0 with input as {"kind": "ConfigMap", "metadata": {"name": "kps-grafana", "namespace": "other"}, "data": {"grafana.ini": ""}}
	count(hosted.deny) == 0 with input as {"kind": "ConfigMap", "metadata": {"name": "kps-grafana-overview", "namespace": "monitoring"}, "data": {"grafana.ini": ""}}
}

grafana_deployment(containers) := {
	"kind": "Deployment",
	"metadata": {"name": "kps-grafana", "namespace": "monitoring"},
	"spec": {"template": {"spec": {"serviceAccountName": "kps-grafana", "containers": containers}}},
}

grafana_container(env) := {"name": "grafana", "image": "i", "env": env}

dashboard_sidecar(env) := {"name": "grafana-sc-dashboard", "image": "i", "env": array.concat([{"name": "FOLDER", "value": "/tmp/dashboards"}], env)}

good_grafana := grafana_deployment([
	dashboard_sidecar([{"name": "METHOD", "value": "WATCH"}]),
	grafana_container([
		{"name": "GF_SECURITY_ADMIN_USER", "valueFrom": {"secretKeyRef": {"name": "grafana-admin", "key": "admin-user"}}},
		{"name": "GF_SECURITY_ADMIN_PASSWORD", "valueFrom": {"secretKeyRef": {"name": "grafana-admin", "key": "admin-password"}}},
		{"name": "GF_PATHS_DATA", "value": "/var/lib/grafana/"},
	]),
])

test_grafana_deployment_accepted if {
	count(hosted.deny) == 0 with input as good_grafana
}

test_grafana_settings_from_the_environment_rejected if {
	every name in [
		"GF_AUTH_BASIC_ENABLED",
		"GF_SECURITY_DISABLE_USERNAME_LOGIN_PROTECTION",
		"GF_SECURITY_DISABLE_IP_ADDRESS_LOGIN_PROTECTION",
		"GF_SECURITY_DISABLE_BRUTE_FORCE_LOGIN_PROTECTION",
		"GF_AUTH_ANONYMOUS_ENABLED",
		"GF_AUTH_ANONYMOUS_HIDE_VERSION",
	] {
		doc := grafana_deployment([grafana_container([{"name": name, "value": "false"}])])
		count(hosted.deny) == 1 with input as doc
		says(doc, sprintf("sets %s, which Grafana takes over", [name]))
	}
	says(grafana_deployment([grafana_container([{"name": "GF_AUTH_BASIC_ENABLED", "valueFrom": {"configMapKeyRef": {"name": "x", "key": "y"}}}])]), "sets GF_AUTH_BASIC_ENABLED")
	says(grafana_deployment([object.union(grafana_container([]), {"envFrom": [{"secretRef": {"name": "grafana-env"}}]})]), "takes envFrom")
}

# The chart's reload calls, with skipReload left at its default.
test_grafana_reload_call_rejected if {
	reload := {"name": "REQ_URL", "value": "http://localhost:3000/api/admin/provisioning/dashboards/reload"}
	doc := grafana_deployment([dashboard_sidecar([reload]), grafana_container([])])
	count(hosted.deny) == 1 with input as doc
	says(doc, "that reload needs basic auth")
}

# The chart's datasource sidecar and its init container, whatever label they read, and a ConfigMap left for them.
test_grafana_datasources_written_while_it_runs_rejected if {
	writer := {"name": "grafana-sc-datasources", "image": "i", "env": [{"name": "LABEL", "value": "other"}, {"name": "FOLDER", "value": "/etc/grafana/provisioning/datasources"}]}
	says(grafana_deployment([writer, grafana_container([])]), "writes Grafana's datasources")
	init := {"kind": "Deployment", "metadata": {"name": "kps-grafana", "namespace": "monitoring"}, "spec": {"template": {"spec": {
		"serviceAccountName": "kps-grafana",
		"initContainers": [object.union(writer, {"name": "grafana-init-sc-datasources"})],
		"containers": [grafana_container([])],
	}}}}
	says(init, "container \"grafana-init-sc-datasources\" writes Grafana's datasources")
	labelled := {"kind": "ConfigMap", "metadata": {"name": "loki-datasource", "namespace": "monitoring", "labels": {"grafana_datasource": "1"}}, "data": {}}
	count(hosted.deny) == 1 with input as labelled
	says(labelled, "is labelled grafana_datasource, and nothing reads that label")
}

test_grafana_as_another_account_rejected if {
	says(json.patch(good_grafana, [{"op": "replace", "path": "/spec/template/spec/serviceAccountName", "value": "default"}]), "runs as ServiceAccount \"default\"")
	says(json.remove(good_grafana, ["spec/template/spec/serviceAccountName"]), "runs as ServiceAccount \"default\"")
}

grafana_role(rules) := {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "Role", "metadata": {"name": "kps-grafana", "namespace": "monitoring"}, "rules": rules}

configmaps_rule := {"apiGroups": [""], "resources": ["configmaps"], "verbs": ["get", "list", "watch"]}

test_grafana_role_reading_configmaps_accepted if {
	count(hosted.deny) == 0 with input as grafana_role([configmaps_rule])
	count(hosted.deny) == 0 with input as grafana_role([{"apiGroups": [""], "resources": ["configmaps"], "verbs": ["watch", "get", "list"]}])
}

# The chart's own Role, and anything else past ConfigMaps.
test_grafana_role_reading_more_rejected if {
	every rules in [
		[{"apiGroups": [""], "resources": ["configmaps", "secrets"], "verbs": ["get", "watch", "list"]}],
		[configmaps_rule, {"apiGroups": [""], "resources": ["secrets"], "verbs": ["get"]}],
		[{"apiGroups": ["*"], "resources": ["configmaps"], "verbs": ["get", "list", "watch"]}],
		[{"apiGroups": [""], "resources": ["*"], "verbs": ["get", "list", "watch"]}],
		[{"apiGroups": [""], "resources": ["configmaps"], "verbs": ["*"]}],
		[{"apiGroups": [""], "resources": ["configmaps"], "verbs": ["get", "list", "watch", "update"]}],
		[object.union(configmaps_rule, {"nonResourceURLs": ["*"]})],
		[],
	] {
		says(grafana_role(rules), "and must be exactly")
	}
	says(json.remove(grafana_role([]), ["rules"]), "and must be exactly")
}

grafana_role_binding(ref) := {
	"kind": "RoleBinding",
	"metadata": {"name": "kps-grafana", "namespace": "monitoring"},
	"roleRef": ref,
	"subjects": [{"kind": "ServiceAccount", "name": "kps-grafana", "namespace": "monitoring"}],
}

test_grafana_role_binding_accepted if {
	count(hosted.deny) == 0 with input as grafana_role_binding({"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": "kps-grafana"})
}

test_grafana_bound_to_anything_else_rejected if {
	says(grafana_role_binding({"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "kps-grafana"}), "roleRef is")
	says(grafana_role_binding({"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": "other"}), "roleRef is")
	cluster_wide := {
		"kind": "ClusterRoleBinding",
		"metadata": {"name": "kps-grafana-clusterrolebinding"},
		"roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "kps-grafana-clusterrole"},
		"subjects": [{"kind": "ServiceAccount", "name": "kps-grafana", "namespace": "monitoring"}],
	}
	count(hosted.deny) == 1 with input as cluster_wide
	says(cluster_wide, "binds Grafana's ServiceAccount")
	elsewhere := json.patch(grafana_role_binding({"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": "reader"}), [
		{"op": "replace", "path": "/metadata/name", "value": "reader"},
		{"op": "replace", "path": "/metadata/namespace", "value": "plane-prod"},
	])
	count(hosted.deny) == 1 with input as elsewhere
	says(elsewhere, "binds Grafana's ServiceAccount")
}

test_other_accounts_bindings_ignored if {
	other := json.patch(grafana_role_binding({"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": "reader"}), [
		{"op": "replace", "path": "/metadata/name", "value": "reader"},
		{"op": "replace", "path": "/subjects/0/name", "value": "alloy"},
	])
	count(hosted.deny) == 0 with input as other
	count(hosted.deny) == 0 with input as json.patch(other, [{"op": "replace", "path": "/subjects/0", "value": {"kind": "ServiceAccount", "name": "kps-grafana", "namespace": "other"}}])
}

# Infisical's four, written out here and not read from the policy, so a change there has to be made twice.
infisical_guess_route := {
	"kind": "Rule",
	"match": "Host(`infisical.bereket.dev`) && Method(`POST`) && (Path(`/api/v3/auth/login`) || Path(`/api/v2/auth/mfa/send`) || Path(`/api/v2/auth/mfa/verify`) || Path(`/api/v2/auth/mfa/verify/recovery-code`) || PathRegexp(`^/api/v2/mfa-sessions/[^/]+/verify$`) || Path(`/api/v2/password/user/password-reset`) || Path(`/api/v1/password/password-setup`) || Path(`/api/v1/password/email/password-setup`))",
	"middlewares": [{"name": "infisical-guess-limit"}],
	"services": [{"name": "infisical", "port": 8080}],
}

infisical_session_route := {
	"kind": "Rule",
	"match": "Host(`infisical.bereket.dev`) && ((Method(`POST`) && (Path(`/api/v3/auth/select-organization`) || Path(`/api/v1/auth/token`) || Path(`/api/v1/auth/logout`))) || (Method(`GET`) && (Path(`/api/v2/auth/mfa/check/totp`) || Path(`/api/v2/auth/mfa/check/webauthn`))))",
	"middlewares": [{"name": "infisical-session-limit"}],
	"services": [{"name": "infisical", "port": 8080}],
}

infisical_api_route := {
	"kind": "Rule",
	"match": "Host(`infisical.bereket.dev`) && PathRegexp(`^/api/(status$|v1/auth/([a-z-]+-auth/identities|token-auth/tokens)/|v1/(access-approvals|admin|agent-vault|alerts|announcement|app-connections|approval-policies|audit-log-streams|cert-manager|dashboard|delegated-approvals|dynamic-secrets|email-domains|external-kms|gateway-pools|github-apps|github-org-sync-config|groups|honey-tokens|identities|identity-templates|insights|integration|integration-auth|kmip|kms|ldap|notifications|oauth|organization|organization-admin|organizations|pam|pit|pki|project-folder-grants|project-templates|projects|proxied-services|relays|reminders|secret-approval-requests|secret-syncs|secret-validation-rules|secrets|sso|sub-organizations|user|user-activation|user-engagement|user-project-additional-privilege|webhooks|workflow-integrations)(/|$)|v2/(folders|gateways|identities|identity-project-additional-privilege|mfa-sessions|organizations|pki|relays|secret-approvals|secret-imports|secret-rotations|secret-scanning|secret-versions|service-token|users)(/|$)|v3/(external-migration|gateways)(/|$)|v4/secrets(/|$))`) && !PathRegexp(`(?i)^/api/(v1/(admin/(bootstrap|signup)|agent-vault/(proxy|session)/|announcement/assets/|cert-manager/(acme|crl|ocsp)/|delegated-approvals/callback|github-apps/manifest/callback|honey-tokens/aws/trigger|identities/details|kmip/(server-registration|servers/(connect|login)|spec/)|ldap/login|oauth/(authorize|token|validate)|organization/agent-proxy-ca|pam/accounts/[^/]+/web-access($|/)|pam/sessions/[^/]+/(chunks(/presigned-put)?|credentials|end)($|/)|pki/ca/[^/]+/certificates/[^/]+/der|proxied-services/[^/]+/report-usage|relays/(heartbeat|register)|sso/(github|gitlab|google|oidc/(callback|login)|redirect|saml2|token-exchange)|user/[^/]+/unlock|workflow-integrations/(microsoft-teams/message-endpoint|slack/oauth_redirect))|v2/(gateways/(heartbeat|metrics|pam-session-key)|mfa-sessions/[^/]+/verify|relays/(connect|heartbeat|login))|v3/gateways/(connect|login|token-auth/enroll))`) && !(Method(`POST`) && PathRegexp(`(?i)^/api/v2/gateways/?$`)) && !((Method(`GET`) || Method(`HEAD`)) && PathRegexp(`(?i)^/api/v2/service-token/?$`)) && !HeaderRegexp(`Authorization`, `[^ -~]|^.{7}st\\.|\\.eyJpZGVudGl0eUlkIjo`) && !HeaderRegexp(`X-Api-Key`, `.*`)",
	"services": [{"name": "infisical", "port": 8080}],
}

infisical_page_route := {
	"kind": "Rule",
	"match": "Host(`infisical.bereket.dev`) && PathRegexp(`^/([A-Za-z0-9._~@:$/-]|%20)*$`) && !PathRegexp(`(?i)^/(api|\\.well-known|scep|secret-scanning|signup|admin/signup|requestnewinvite|account-recovery|email-not-verified|login/(ldap|oidc|saml|provider)|cli-redirect|share-secret|shared|secret-request)`)",
	"services": [{"name": "infisical", "port": 8080}],
}

infisical_routes := [infisical_guess_route, infisical_session_route, infisical_api_route, infisical_page_route]

infisical_spec := {
	"entryPoints": ["websecure"],
	"routes": infisical_routes,
	"tls": {"secretName": "infisical-tls"},
}

infisical_route := object.union(route_doc("infisical", infisical_spec), {"metadata": {"name": "infisical"}})

infisical_with_routes(routes) := route_doc("infisical", object.union(infisical_spec, {"routes": routes}))

# The API route with one word changed, and the rule that names each change.
infisical_api_with(old, new) := infisical_with_routes([
	infisical_guess_route,
	infisical_session_route,
	object.union(infisical_api_route, {"match": replace(infisical_api_route.match, old, new)}),
	infisical_page_route,
])

not_infisicals := "is not one of Infisical's four"

test_infisical_route_accepted if {
	count(hosted.deny) == 0 with input as infisical_route
}

test_infisical_routes_in_any_order_accepted if {
	count(hosted.deny) == 0 with input as infisical_with_routes([infisical_page_route, infisical_api_route, infisical_session_route, infisical_guess_route])
}

test_infisical_route_missing_any_one_rejected if {
	every route in infisical_routes {
		says(infisical_with_routes([r | some r in infisical_routes; r != route]), "has no route")
	}
}

test_infisical_on_any_other_host_rejected if {
	every host in ["vault.bereket.dev", "infisical.wayline.bereket.dev", "infisical.localhost", "grafana.bereket.dev"] {
		says(infisical_api_with("Host(`infisical.bereket.dev`)", sprintf("Host(`%s`)", [host])), not_infisicals)
	}
	says(infisical_api_with("Host(`infisical.bereket.dev`)", "HostRegexp(`^infisical[.]bereket[.]dev$`)"), not_infisicals)
	says(infisical_api_with("Host(`infisical.bereket.dev`) && ", ""), not_infisicals)
}

test_infisical_on_the_web_entry_point_rejected if {
	count(hosted.deny) == 1 with input as route_doc("infisical", object.union(infisical_spec, {"entryPoints": ["web"]}))
	count(hosted.deny) == 1 with input as route_doc("infisical", object.union(infisical_spec, {"entryPoints": ["web", "websecure"]}))
	count(hosted.deny) == 1 with input as route_doc("infisical", json.remove(infisical_spec, ["entryPoints"]))
}

test_infisical_without_its_own_certificate_rejected if {
	says(route_doc("infisical", json.remove(infisical_spec, ["tls"])), "tls is {} and must name only secretName infisical-tls")
	says(route_doc("infisical", object.union(infisical_spec, {"tls": {"secretName": "grafana-tls"}})), "must name only secretName infisical-tls")
	says(route_doc("infisical", object.union(infisical_spec, {"tls": {"certResolver": "letsencrypt"}})), "must name only secretName infisical-tls")
}

# Its own Postgres and Redis sit in the same namespace, and only the server is ever a backend.
test_another_backend_under_the_infisical_host_rejected if {
	every service in [
		{"name": "infisical-postgres", "port": 5432},
		{"name": "infisical-redis", "port": 6379},
		{"name": "infisical", "port": 8081},
		{"name": "infisical", "namespace": "plane-prod", "port": 8080},
		{"name": "api@internal", "kind": "TraefikService"},
	] {
		says(infisical_with_routes([infisical_guess_route, infisical_session_route, object.union(infisical_api_route, {"services": [service]}), infisical_page_route]), not_infisicals)
	}
}

# A family more, a family that is a prefix of another, or a refusal less, is a public login that nobody read.
test_infisical_api_widened_rejected if {
	says(infisical_api_with("|webhooks|", "|webhooks|scim|"), not_infisicals)
	says(infisical_api_with("|webhooks|", "|webhooks|invite-org|"), not_infisicals)
	says(infisical_api_with("v4/secrets(/|$)", "v4/secrets(/|$)|v3/secrets(/|$)"), not_infisicals)
	says(infisical_api_with("|user|", "|user.*|"), not_infisicals)
	says(infisical_api_with("v1/auth/([a-z-]+-auth/identities|token-auth/tokens)/", "v1/auth/"), not_infisicals)
	says(infisical_api_with("admin/(bootstrap|signup)|", ""), not_infisicals)
	says(infisical_api_with("(?i)^/api/(v1/(admin", "^/api/(v1/(admin"), not_infisicals)
	says(infisical_api_with("|identities/details|", "|"), not_infisicals)
	says(infisical_api_with("|organization/agent-proxy-ca|", "|"), not_infisicals)
	says(infisical_api_with(" && !(Method(`POST`) && PathRegexp(`(?i)^/api/v2/gateways/?$`))", ""), not_infisicals)
	says(infisical_api_with(" && !((Method(`GET`) || Method(`HEAD`)) && PathRegexp(`(?i)^/api/v2/service-token/?$`))", ""), not_infisicals)
	says(infisical_api_with("(Method(`GET`) || Method(`HEAD`))", "Method(`GET`)"), not_infisicals)
}

# A machine's credential on a browser's call is refused by the header, whatever path it takes, and each part of that has to stay.
test_infisical_api_taking_a_machine_credential_rejected if {
	says(infisical_api_with(" && !HeaderRegexp(`Authorization`, `[^ -~]|^.{7}st\\.|\\.eyJpZGVudGl0eUlkIjo`)", ""), not_infisicals)
	says(infisical_api_with(" && !HeaderRegexp(`X-Api-Key`, `.*`)", ""), not_infisicals)
	says(infisical_api_with("`[^ -~]|^.{7}st\\.|", "`^.{7}st\\.|"), not_infisicals)
	says(infisical_api_with("|^.{7}st\\.|", "|"), not_infisicals)
	says(infisical_api_with("|\\.eyJpZGVudGl0eUlkIjo`", "`"), not_infisicals)
	says(infisical_api_with("\\.eyJpZGVudGl0eUlkIjo", "^Bearer [^.]+\\.eyJpZGVudGl0eUlkIjo"), not_infisicals)
	says(infisical_api_with("!HeaderRegexp(`Authorization`", "!HeaderRegexp(`X-Authorization`"), not_infisicals)
}

test_infisical_pages_widened_rejected if {
	says(infisical_with_routes([infisical_guess_route, infisical_session_route, infisical_api_route, object.union(infisical_page_route, {"match": replace(infisical_page_route.match, "|signup|", "|")})]), not_infisicals)
	says(infisical_with_routes([infisical_guess_route, infisical_session_route, infisical_api_route, object.union(infisical_page_route, {"match": replace(infisical_page_route.match, "(?i)^/(api|", "(?i)^/(")})]), not_infisicals)
	says(infisical_with_routes([infisical_guess_route, infisical_session_route, infisical_api_route, object.union(infisical_page_route, {"match": "Host(`infisical.bereket.dev`)"})]), not_infisicals)
}

test_infisical_login_without_its_limit_rejected if {
	says(infisical_with_routes([json.remove(infisical_guess_route, ["middlewares"]), infisical_session_route, infisical_api_route, infisical_page_route]), not_infisicals)
	says(infisical_with_routes([object.union(infisical_guess_route, {"middlewares": [{"name": "infisical-session-limit"}]}), infisical_session_route, infisical_api_route, infisical_page_route]), not_infisicals)
	says(infisical_with_routes([infisical_guess_route, json.remove(infisical_session_route, ["middlewares"]), infisical_api_route, infisical_page_route]), not_infisicals)
}

test_a_middleware_on_an_infisical_route_without_one_rejected if {
	says(infisical_with_routes([infisical_guess_route, infisical_session_route, object.union(infisical_api_route, {"middlewares": [{"name": "rewrite"}]}), infisical_page_route]), not_infisicals)
}

test_prometheus_on_a_path_of_the_infisical_host_rejected if {
	extra := page_rule("Host(`infisical.bereket.dev`) && PathPrefix(`/prometheus`)", {"name": "kps-prometheus", "namespace": "monitoring", "port": 9090})
	says(infisical_with_routes(array.concat(infisical_routes, [extra])), not_infisicals)
}

test_infisical_route_in_another_namespace_rejected if {
	says(route_doc("plane-prod", infisical_spec), "gives no console a public route but Grafana's")
	says(route_doc("monitoring", infisical_spec), not_grafanas)
	says(route_doc("argocd", infisical_spec), "a route may sit only in namespace")
}

test_grafana_route_in_the_infisical_namespace_rejected if {
	says(route_doc("infisical", grafana_spec), not_infisicals)
	says(route_doc("infisical", route_spec), not_infisicals)
	says(route_doc("infisical", route_spec), "must name only secretName infisical-tls")
}

infisical_limit(name, average, criterion) := middleware("infisical", name, {"rateLimit": {"average": average, "period": "1m", "burst": average, "sourceCriterion": criterion}})

test_infisical_limits_accepted if {
	count(hosted.deny) == 0 with input as infisical_limit("infisical-guess-limit", 10, {"ipStrategy": {"depth": 0}})
	count(hosted.deny) == 0 with input as infisical_limit("infisical-session-limit", 30, {"ipStrategy": {"depth": 0}})
}

test_an_infisical_limit_on_anything_but_the_connection_rejected if {
	every criterion in [{"ipStrategy": {"depth": 1}}, {"ipStrategy": {"excludedIPs": ["0.0.0.0/0"]}}, {"requestHeaderName": "X-Forwarded-For"}, {"requestHost": true}] {
		count(hosted.deny) == 1 with input as infisical_limit("infisical-guess-limit", 10, criterion)
		count(hosted.deny) == 1 with input as infisical_limit("infisical-session-limit", 30, criterion)
	}
}

test_a_looser_infisical_limit_rejected if {
	count(hosted.deny) == 1 with input as infisical_limit("infisical-guess-limit", 30, {"ipStrategy": {"depth": 0}})
	count(hosted.deny) == 1 with input as infisical_limit("infisical-session-limit", 300, {"ipStrategy": {"depth": 0}})
	count(hosted.deny) == 1 with input as middleware("infisical", "infisical-guess-limit", {"stripPrefix": {"prefixes": ["/x"]}})
}

test_another_middleware_beside_infisical_rejected if {
	count(hosted.deny) == 1 with input as middleware("infisical", "rewrite", {"replacePath": {"path": "/api/v1/auth/universal-auth/login"}})
	count(hosted.deny) == 1 with input as middleware("infisical", "grafana-login-limit", {"rateLimit": {"average": 5, "period": "1m", "burst": 5, "sourceCriterion": {"ipStrategy": {"depth": 0}}}})
}

infisical_image := "docker.io/infisical/infisical:v0.167.6@sha256:ca5cbd14b2f170feaaca3fbe5b001b7594c8b9c0c62a491409910f10b05dbb2c"

# As values/infisical.yaml sets them, and the chart renders them, with no namespace.
infisical_env := [
	{"name": "NODE_OPTIONS", "value": "--max-old-space-size=640"},
	{"name": "SITE_URL", "value": "https://infisical.bereket.dev"},
	{"name": "HTTPS_ENABLED", "value": "true"},
	{"name": "TRUSTED_PROXY_CIDRS", "value": "10.244.0.0/16"},
	{"name": "DISABLE_PUBLIC_SECRET_SHARING", "value": "true"},
]

infisical_server(image, env) := {
	"kind": "Deployment",
	"metadata": {"name": "infisical"},
	"spec": {"template": {"spec": {"containers": [{"name": "infisical-standalone-infisical", "image": image, "env": env, "envFrom": [{"secretRef": {"name": "infisical-secrets"}}]}]}}},
}

test_infisical_at_the_version_its_route_was_read_from_accepted if {
	count(hosted.deny) == 0 with input as infisical_server(infisical_image, infisical_env)
}

# Another version may bring a login, a sign-up or a token its lists do not name, so the route is read again first. The whole reference counts,
# under any spelling of the registry.
test_infisical_at_another_version_rejected if {
	every image in [
		"docker.io/infisical/infisical:v0.168.0@sha256:0000000000000000000000000000000000000000000000000000000000000000",
		"docker.io/infisical/infisical:latest",
		"docker.io/infisical/infisical:v0.167.6",
		"docker.io/infisical/infisical:v0.167.6@sha256:1111111111111111111111111111111111111111111111111111111111111111",
		"infisical/infisical:v0.168.0@sha256:0000000000000000000000000000000000000000000000000000000000000000",
		"index.docker.io/infisical/infisical:v0.168.0@sha256:0000000000000000000000000000000000000000000000000000000000000000",
		"docker.io/infisical/infisical@sha256:0000000000000000000000000000000000000000000000000000000000000000",
		"registry.example:5000/mirror/infisical/infisical:v0.167.6@sha256:ca5cbd14b2f170feaaca3fbe5b001b7594c8b9c0c62a491409910f10b05dbb2c",
	] {
		says(infisical_server(image, infisical_env), "was read from v0.167.6")
	}
}

test_other_infisical_images_ignored if {
	every image in [
		"docker.io/infisical/kubernetes-operator:v0.10.2@sha256:0000000000000000000000000000000000000000000000000000000000000000",
		"docker.io/infisical/infisical-gateway:v1@sha256:0000000000000000000000000000000000000000000000000000000000000000",
		"docker.io/library/postgres:16.15-alpine@sha256:0000000000000000000000000000000000000000000000000000000000000000",
	] {
		count(hosted.deny) == 0 with input as deployment("infisical", "other", image, {})
	}
}

# Each value the public route needs, gone, changed, or from a reference, which nothing here can read.
test_infisical_without_what_its_route_needs_rejected if {
	every name in ["SITE_URL", "HTTPS_ENABLED", "TRUSTED_PROXY_CIDRS", "DISABLE_PUBLIC_SECRET_SHARING"] {
		says(infisical_server(infisical_image, [e | some e in infisical_env; e.name != name]), sprintf("sets %s to \"unset\"", [name]))
		says(infisical_server(infisical_image, array.concat(infisical_env, [{"name": name, "valueFrom": {"secretKeyRef": {"name": "x", "key": "y"}}}])), sprintf("sets %s to \"a reference\"", [name]))
	}
	says(infisical_server(infisical_image, array.concat(infisical_env, [{"name": "SITE_URL", "value": "http://localhost:18100"}])), "with a public route it must be")
	says(infisical_server(infisical_image, array.concat(infisical_env, [{"name": "DISABLE_PUBLIC_SECRET_SHARING", "value": "false"}])), "with a public route it must be")
	says(infisical_server(infisical_image, array.concat(infisical_env, [{"name": "TRUSTED_PROXY_CIDRS", "value": "0.0.0.0/0"}])), "with a public route it must be")
}

# The last of two entries is the one Kubernetes runs, so a good value later puts a bad one right.
test_infisical_env_read_as_kubernetes_runs_it if {
	count(hosted.deny) == 0 with input as infisical_server(infisical_image, array.concat([{"name": "HTTPS_ENABLED", "value": "false"}], infisical_env))
}

# The four Probes and their modules, written out here and not read from the policy.
infisical_probe(name, module, target) := {
	"apiVersion": "monitoring.coreos.com/v1",
	"kind": "Probe",
	"metadata": {"name": name, "namespace": "infisical"},
	"spec": {
		"jobName": "infisical-http",
		"interval": "30s",
		"scrapeTimeout": "10s",
		"module": module,
		"prober": {"url": "blackbox.monitoring.svc.cluster.local:9115", "path": "/probe"},
		"targets": {"staticConfig": {"static": [target], "labels": {"probe": name}}},
	},
}

infisical_probes := [
	infisical_probe("infisical", "http_infisical_login", "https://infisical.bereket.dev/login"),
	infisical_probe("infisical-claimed", "http_infisical_claimed", "https://infisical.bereket.dev/api/v1/admin/config"),
	infisical_probe("infisical-sign-in", "http_infisical_no_bearer_post", "https://infisical.bereket.dev/api/v1/password/password-setup"),
	infisical_probe("infisical-session", "http_infisical_no_refresh_cookie", "https://infisical.bereket.dev/api/v1/auth/token"),
]

test_infisical_probes_accepted if {
	every probe in infisical_probes {
		count(hosted.deny) == 0 with input as probe
	}
}

# What leaves the claim alerts quiet, or reading another thing.
test_infisical_probe_changed_rejected if {
	claimed := infisical_probes[1]
	says(json.patch(claimed, [{"op": "replace", "path": "/spec/module", "value": "http_infisical_login"}]), "must be exactly")
	says(json.patch(claimed, [{"op": "replace", "path": "/spec/targets/staticConfig/static/0", "value": "https://infisical.bereket.dev/api/status"}]), "must be exactly")
	says(json.patch(claimed, [{"op": "replace", "path": "/spec/targets/staticConfig/labels/probe", "value": "other"}]), "must be exactly")
	says(json.patch(claimed, [{"op": "replace", "path": "/spec/interval", "value": "1h"}]), "must be exactly")
	says(json.patch(infisical_probes[2], [{"op": "replace", "path": "/spec/module", "value": "http_infisical_no_refresh_cookie"}]), "must be exactly")
	says(infisical_probe("infisical-extra", "http_2xx", "https://infisical.bereket.dev/"), "the only Probes in namespace infisical")
}

test_infisical_probe_label_elsewhere_rejected if {
	elsewhere := json.patch(infisical_probes[1], [{"op": "replace", "path": "/metadata/namespace", "value": "monitoring"}])
	says(elsewhere, "carries probe label infisical-claimed")
	count(hosted.deny) == 0 with input as json.patch(elsewhere, [{"op": "replace", "path": "/spec/targets/staticConfig/labels/probe", "value": "grafana"}])
}

blackbox_modules := {
	"http_2xx": {"prober": "http"},
	"http_infisical_login": {"prober": "http", "timeout": "5s", "http": {"preferred_ip_protocol": "ip4", "fail_if_not_ssl": true, "valid_status_codes": [200], "fail_if_body_not_matches_regexp": [`<title id="initial-document-title">Infisical</title>`]}},
	"http_infisical_claimed": {"prober": "http", "timeout": "5s", "http": {"preferred_ip_protocol": "ip4", "fail_if_not_ssl": true, "valid_status_codes": [200], "fail_if_body_json_not_matches_cel": "body.config.initialized == true && body.config.allowSignUp == false"}},
	"http_infisical_no_bearer_post": {"prober": "http", "timeout": "5s", "http": {"method": "POST", "preferred_ip_protocol": "ip4", "fail_if_not_ssl": true, "valid_status_codes": [401], "fail_if_body_not_matches_regexp": [`"message":\s*"Token missing"`]}},
	"http_infisical_no_refresh_cookie": {"prober": "http", "timeout": "5s", "http": {"method": "POST", "preferred_ip_protocol": "ip4", "fail_if_not_ssl": true, "valid_status_codes": [404], "fail_if_body_not_matches_regexp": [`"error":\s*"AuthTokenNotFound"`]}},
}

blackbox_config(modules) := {"kind": "ConfigMap", "metadata": {"name": "blackbox-config-7c8f5b9t4k", "namespace": "monitoring"}, "data": {"blackbox.yml": yaml.marshal({"modules": modules})}}

test_blackbox_config_accepted if {
	count(hosted.deny) == 0 with input as blackbox_config(blackbox_modules)
}

test_blackbox_module_for_infisical_changed_rejected if {
	says(blackbox_config(json.remove(blackbox_modules, ["http_infisical_claimed"])), "blackbox module http_infisical_claimed is missing")
	says(blackbox_config(json.remove(blackbox_modules, ["http_infisical_claimed/http/fail_if_body_json_not_matches_cel"])), "blackbox module http_infisical_claimed")
	says(blackbox_config(json.patch(blackbox_modules, [{"op": "replace", "path": "/http_infisical_claimed/http/fail_if_body_json_not_matches_cel", "value": "body.config.initialized == true"}])), "blackbox module http_infisical_claimed")
	says(blackbox_config(json.patch(blackbox_modules, [{"op": "replace", "path": "/http_infisical_no_bearer_post/http/valid_status_codes", "value": [401, 404]}])), "blackbox module http_infisical_no_bearer_post")
	says(blackbox_config(json.remove(blackbox_modules, ["http_infisical_no_refresh_cookie/http/fail_if_body_not_matches_regexp"])), "blackbox module http_infisical_no_refresh_cookie")
	says(object.union(blackbox_config(blackbox_modules), {"data": {"blackbox.yml": "modules: [unclosed"}}), "blackbox.yml is not YAML")
}

test_other_config_maps_in_monitoring_ignored if {
	count(hosted.deny) == 0 with input as {"kind": "ConfigMap", "metadata": {"name": "alert-sink-5h2m8c", "namespace": "monitoring"}, "data": {"sink.py": "print()"}}
}

# Every policy in namespace infisical, as the hosted tree writes it, the ones that only let something out among them.
server_pods := {"matchLabels": {"app": "infisical-standalone", "component": "infisical"}}

traefik_peer := {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "traefik"}}, "podSelector": {"matchLabels": {"app.kubernetes.io/name": "traefik"}}}

netpol(namespace, name, spec) := {"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": {"name": name, "namespace": namespace}, "spec": spec}

infisical_postgres_policy := netpol("infisical", "infisical-postgres", {
	"podSelector": {"matchLabels": {"app.kubernetes.io/name": "infisical-postgres"}},
	"policyTypes": ["Ingress"],
	"ingress": [{"from": [{"podSelector": server_pods}, {"podSelector": {"matchLabels": {"app.kubernetes.io/component": "backup"}}}], "ports": [{"protocol": "TCP", "port": 5432}]}],
})

infisical_policies := [
	netpol("infisical", "infisical-server", {
		"podSelector": server_pods,
		"policyTypes": ["Ingress", "Egress"],
		"ingress": [
			{"from": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "plane-prod"}}, "podSelector": {"matchLabels": {"app.kubernetes.io/name": "secrets-operator"}}}], "ports": [{"protocol": "TCP", "port": 8080}]},
			{"from": [traefik_peer], "ports": [{"protocol": "TCP", "port": 8080}]},
		],
		"egress": [
			{"to": [{"podSelector": {"matchLabels": {"app.kubernetes.io/name": "infisical-postgres"}}}], "ports": [{"protocol": "TCP", "port": 5432}]},
			{"to": [{"podSelector": {"matchLabels": {"app.kubernetes.io/name": "infisical-redis"}}}], "ports": [{"protocol": "TCP", "port": 6379}]},
			{"to": [{"ipBlock": {"cidr": "5.253.234.127/32"}}], "ports": [{"protocol": "TCP", "port": 6443}]},
		],
	}),
	infisical_postgres_policy,
	netpol("infisical", "infisical-redis", {
		"podSelector": {"matchLabels": {"app.kubernetes.io/name": "infisical-redis"}},
		"policyTypes": ["Ingress"],
		"ingress": [{"from": [{"podSelector": server_pods}], "ports": [{"protocol": "TCP", "port": 6379}]}],
	}),
	netpol("infisical", "acme-http01-solver", {
		"podSelector": {"matchLabels": {"acme.cert-manager.io/http01-solver": "true"}},
		"policyTypes": ["Ingress"],
		"ingress": [{"from": [traefik_peer], "ports": [{"protocol": "TCP", "port": 8089}]}],
	}),
	netpol("infisical", "default-deny", {"podSelector": {}, "policyTypes": ["Ingress", "Egress"]}),
	infisical_dns_policy,
	infisical_backup_policy,
]

infisical_dns_policy := netpol("infisical", "allow-dns", {
	"podSelector": {},
	"policyTypes": ["Egress"],
	"egress": [{
		"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}}, "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}}}],
		"ports": [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}],
	}],
})

infisical_backup_policy := netpol("infisical", "backup", {
	"podSelector": {"matchLabels": {"app.kubernetes.io/component": "backup"}},
	"policyTypes": ["Egress"],
	"egress": [{"to": [{"podSelector": {"matchLabels": {"app.kubernetes.io/name": "infisical-postgres"}}}], "ports": [{"protocol": "TCP", "port": 5432}]}],
})

not_a_policy_there := "is not one of the NetworkPolicies in namespace infisical"

test_infisical_network_policies_accepted if {
	every policy in infisical_policies {
		count(hosted.deny) == 0 with input as policy
	}
}

# NetworkPolicy adds up, so a rule more anywhere in the namespace is a way in.
test_a_way_into_infisical_postgres_rejected if {
	says(json.patch(infisical_postgres_policy, [{"op": "add", "path": "/spec/ingress/0/from/-", "value": {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "traefik"}}}}]), "spec must be exactly")
	says(json.patch(infisical_postgres_policy, [{"op": "replace", "path": "/spec/ingress/0/from/0", "value": {"podSelector": {}}}]), "spec must be exactly")
	says(netpol("infisical", "open", {"podSelector": {"matchLabels": {"app.kubernetes.io/name": "infisical-postgres"}}, "ingress": [{}]}), not_a_policy_there)
	says(netpol("infisical", "allow-all", {"podSelector": {}, "policyTypes": ["Ingress"], "ingress": [{"from": [{"namespaceSelector": {}}]}]}), not_a_policy_there)
	says(json.patch(infisical_policies[0], [{"op": "replace", "path": "/spec/podSelector", "value": {}}]), "spec must be exactly")
}

# The same both ways: the server's egress is what bounds its relaxed SSRF protection, so a policy that only lets something out is a way out of
# the secret store, and the same in one written out here, or the default taken away, is one too.
test_a_way_out_of_infisical_rejected if {
	says(netpol("infisical", "server-egress-open", {"podSelector": server_pods, "policyTypes": ["Egress"], "egress": [{}]}), not_a_policy_there)
	says(netpol("infisical", "server-to-plane", {"podSelector": server_pods, "policyTypes": ["Egress"], "egress": [{"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "plane-prod"}}}]}]}), not_a_policy_there)
	says(netpol("infisical", "quiet", {"podSelector": {}, "policyTypes": ["Egress"]}), not_a_policy_there)
	says(json.patch(infisical_dns_policy, [{"op": "replace", "path": "/spec/egress", "value": [{}]}]), "spec must be exactly")
	says(json.patch(infisical_dns_policy, [{"op": "remove", "path": "/spec/egress/0/to/0/podSelector"}]), "spec must be exactly")
	says(json.patch(infisical_backup_policy, [{"op": "add", "path": "/spec/egress/-", "value": {"to": [{"ipBlock": {"cidr": "0.0.0.0/0"}}]}}]), "spec must be exactly")
	says(json.patch(infisical_policies[0], [{"op": "add", "path": "/spec/egress/-", "value": {"to": [{"ipBlock": {"cidr": "0.0.0.0/0"}}], "ports": [{"protocol": "TCP", "port": 443}]}}]), "spec must be exactly")
	says(netpol("infisical", "default-deny", {"podSelector": {}, "policyTypes": ["Ingress"]}), "spec must be exactly")
}

traefik_egress_rules := [
	{"to": [{"ipBlock": {"cidr": "5.253.234.127/32"}}], "ports": [{"protocol": "TCP", "port": 6443}]},
	{"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "plane-prod"}}}], "ports": [{"protocol": "TCP", "port": 3000}, {"protocol": "TCP", "port": 8000}, {"protocol": "TCP", "port": 8089}, {"protocol": "TCP", "port": 9000}]},
	{"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "monitoring"}}, "podSelector": {"matchLabels": {"app.kubernetes.io/name": "grafana"}}}], "ports": [{"protocol": "TCP", "port": 3000}]},
	{"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "infisical"}}, "podSelector": server_pods}], "ports": [{"protocol": "TCP", "port": 8080}]},
	{"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "infisical"}}, "podSelector": {"matchLabels": {"acme.cert-manager.io/http01-solver": "true"}}}], "ports": [{"protocol": "TCP", "port": 8089}]},
]

traefik_egress(rules) := netpol("traefik", "traefik-egress", {"podSelector": {"matchLabels": {"app.kubernetes.io/name": "traefik"}}, "policyTypes": ["Egress"], "egress": rules})

test_traefik_egress_accepted if {
	count(hosted.deny) == 0 with input as traefik_egress(traefik_egress_rules)
}

test_traefik_egress_wider_into_infisical_rejected if {
	every rule in [
		{"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "infisical"}}, "podSelector": {}}], "ports": [{"protocol": "TCP", "port": 8080}, {"protocol": "TCP", "port": 5432}]},
		{"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "infisical"}}, "podSelector": server_pods}], "ports": [{"protocol": "TCP", "port": 8080}, {"protocol": "TCP", "port": 6379}]},
		{"to": [{"namespaceSelector": {}}], "ports": [{"protocol": "TCP", "port": 5432}]},
		{"to": [{"namespaceSelector": {"matchExpressions": [{"key": "kubernetes.io/metadata.name", "operator": "In", "values": ["infisical"]}]}}]},
		{"to": [{"ipBlock": {"cidr": "10.244.0.0/16"}}], "ports": [{"protocol": "TCP", "port": 5432}]},
		{"to": [{"ipBlock": {"cidr": "0.0.0.0/0"}}]},
		{"ports": [{"protocol": "TCP", "port": 5432}]},
	] {
		says(traefik_egress(array.concat(traefik_egress_rules, [rule])), "where Traefik reaches only Infisical's server on 8080 and a solver on 8089")
	}
}
