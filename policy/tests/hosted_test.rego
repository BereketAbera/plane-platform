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
	some console in [
		["argocd-server", 80],
		["kps-grafana", 80],
		["kps-prometheus", 9090],
		["kps-alertmanager", 9093],
		["infisical", 8080],
		["plane-rabbitmq", 15672],
		["traefik", 8080],
	]
	count(hosted.deny) == 1 with input as route_to(console[0], console[1])
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
	count(hosted.deny) == 1 with input as route_doc("monitoring", route_spec)
	count(hosted.deny) == 1 with input as {"kind": "IngressRoute", "metadata": {"name": "x"}, "spec": route_spec}
}

test_tcp_and_udp_routes_rejected if {
	count(hosted.deny) == 1 with input as {"kind": "IngressRouteTCP", "metadata": {"name": "x", "namespace": "plane-prod"}, "spec": {}}
	count(hosted.deny) == 2 with input as {"kind": "IngressRouteUDP", "metadata": {"name": "x", "namespace": "monitoring"}, "spec": {}}
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

test_git_sources_in_the_two_trees_accepted if {
	count(hosted.deny) == 0 with input as application(plain_source("gitops/clusters/plane-prod/applications"))
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
