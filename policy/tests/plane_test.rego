package plane_test

import data.plane
import rego.v1

test_banned_registry_in_image_rejected if {
	doc := {
		"kind": "Deployment",
		"metadata": {"name": "plane-web-wl"},
		"spec": {"template": {"spec": {"containers": [{"name": "c", "image": "artifacts.plane.so/makeplane/plane-frontend:v1.4.3"}]}}},
	}
	count(plane.deny) == 1 with input as doc
}

test_banned_registry_in_configmap_rejected if {
	doc := {"kind": "ConfigMap", "metadata": {"name": "x"}, "data": {"REGISTRY": "https://artifacts.plane.so"}}
	count(plane.deny) == 1 with input as doc
}

test_docker_io_accepted if {
	doc := {
		"kind": "Deployment",
		"metadata": {"name": "plane-web-wl"},
		"spec": {"template": {"spec": {"containers": [{"name": "c", "image": "docker.io/makeplane/plane-frontend@sha256:abc"}]}}},
	}
	count(plane.deny) == 0 with input as doc
}

test_wrong_bucket_in_configmap_rejected if {
	doc := {"kind": "ConfigMap", "metadata": {"name": "x"}, "data": {"AWS_S3_BUCKET_NAME": "plane-dev-uploads"}}
	count(plane.deny) == 1 with input as doc
}

test_right_bucket_in_configmap_accepted if {
	doc := {"kind": "ConfigMap", "metadata": {"name": "x"}, "data": {"AWS_S3_BUCKET_NAME": "uploads"}}
	count(plane.deny) == 0 with input as doc
}

test_wrong_bucket_in_container_env_rejected if {
	doc := {
		"kind": "Deployment",
		"metadata": {"name": "plane-api-wl"},
		"spec": {"template": {"spec": {"containers": [{
			"name": "c",
			"image": "i",
			"env": [{"name": "AWS_S3_BUCKET_NAME", "value": "other"}],
		}]}}},
	}
	count(plane.deny) == 1 with input as doc
}

route_in(namespace, match, service) := {
	"kind": "IngressRoute",
	"metadata": {"name": "plane-ingress", "namespace": namespace},
	"spec": {"routes": [{"match": match, "kind": "Rule", "services": [{"name": service, "port": 9000}]}]},
}

route(match, service) := route_in("plane-dev", match, service)

test_uploads_route_accepted if {
	count(plane.deny) == 0 with input as route("Host(`plane.dev.localhost`) && PathPrefix(`/uploads`)", "plane-minio")
}

test_uploads_slash_route_accepted if {
	count(plane.deny) == 0 with input as route("Host(`plane.dev.localhost`) && (Path(`/uploads`) || PathPrefix(`/uploads/`))", "plane-minio")
}

test_other_bucket_route_rejected if {
	count(plane.deny) == 1 with input as route("Host(`plane.dev.localhost`) && PathPrefix(`/plane-dev-uploads`)", "plane-minio")
}

test_route_to_other_service_ignored if {
	count(plane.deny) == 0 with input as route("Host(`plane.dev.localhost`) && PathPrefix(`/api`)", "plane-api")
}

test_host_alone_accepted if {
	count(plane.deny) == 0 with input as route("Host(`plane.dev.localhost`)", "plane-web")
	count(plane.deny) == 0 with input as route_in("plane-prod-sim", "Host(`plane.prod-sim.localhost`)", "plane-web")
}

test_hosted_route_on_its_host_accepted if {
	count(plane.deny) == 0 with input as route_in("plane-prod", "Host(`wayline.bereket.dev`) && PathPrefix(`/`)", "plane-web")
}

# Before plane-prod was in the host table, a route in that namespace with no Host at all passed.
test_hosted_route_with_no_host_rejected if {
	count(plane.deny) == 1 with input as route_in("plane-prod", "PathPrefix(`/`)", "plane-web")
}

test_hosted_route_on_another_host_rejected if {
	count(plane.deny) == 1 with input as route_in("plane-prod", "Host(`other.bereket.dev`)", "plane-web")
}

test_another_namespace_naming_the_hosted_host_rejected if {
	denied := plane.deny with input as route("Host(`wayline.bereket.dev`)", "plane-web")
	count(denied) == 2 # not its own host, and not the namespace that host belongs to
}

test_dev_route_on_the_prod_sim_host_rejected if {
	denied := plane.deny with input as route("Host(`plane.prod-sim.localhost`) && PathPrefix(`/`)", "plane-web")
	count(denied) == 2 # not its own host, and not the namespace that host belongs to
}

test_prod_sim_route_on_the_dev_host_rejected if {
	denied := plane.deny with input as route_in("plane-prod-sim", "Host(`plane.dev.localhost`)", "plane-web")
	count(denied) == 2
}

test_route_with_no_host_rejected if {
	count(plane.deny) == 1 with input as route("PathPrefix(`/`)", "plane-web")
}

test_host_regexp_rejected if {
	count(plane.deny) == 1 with input as route("HostRegexp(`.+`)", "plane-web")
}

test_top_level_or_escapes_the_host_rejected if {
	count(plane.deny) == 1 with input as route("Host(`plane.dev.localhost`) && Path(`/a`) || PathPrefix(`/`)", "plane-web")
	count(plane.deny) == 1 with input as route("PathPrefix(`/`) || Host(`plane.dev.localhost`)", "plane-web")
}

test_or_inside_parentheses_accepted if {
	count(plane.deny) == 0 with input as route("Host(`plane.dev.localhost`) && (Path(`/a`) || (Path(`/b`) && Method(`GET`)))", "plane-web")
}

test_unbalanced_rule_rejected if {
	count(plane.deny) == 1 with input as route("Host(`plane.dev.localhost`) && (Path(`/a`) || Path(`/b`)", "plane-web")
}

test_one_bad_route_among_good_ones_rejected if {
	doc := {
		"kind": "IngressRoute",
		"metadata": {"name": "plane-ingress", "namespace": "plane-dev"},
		"spec": {"routes": [
			{"match": "Host(`plane.dev.localhost`)", "services": [{"name": "plane-web"}]},
			{"match": "PathPrefix(`/`)", "services": [{"name": "plane-web"}]},
		]},
	}
	count(plane.deny) == 1 with input as doc
}

test_platform_route_on_its_own_host_accepted if {
	count(plane.deny) == 0 with input as route_in("traefik", "Host(`whoami.localhost`)", "whoami")
}

test_platform_route_naming_a_plane_host_rejected if {
	count(plane.deny) == 1 with input as route_in("traefik", "Host(`plane.prod-sim.localhost`)", "whoami")
}

test_tcp_route_in_a_plane_namespace_rejected if {
	doc := {"kind": "IngressRouteTCP", "metadata": {"name": "x", "namespace": "plane-dev"}, "spec": {"routes": [{"match": "HostSNI(`*`)"}]}}
	count(plane.deny) == 1 with input as doc
}

test_tcp_route_elsewhere_ignored if {
	doc := {"kind": "IngressRouteTCP", "metadata": {"name": "x", "namespace": "traefik"}, "spec": {"routes": [{"match": "HostSNI(`*`)", "services": [{"name": "whoami", "port": 80}]}]}}
	count(plane.deny) == 0 with input as doc
}

test_tcp_route_beside_or_to_an_internal_ui_rejected if {
	beside := {"kind": "IngressRouteTCP", "metadata": {"name": "x", "namespace": "monitoring"}, "spec": {"routes": [{"match": "HostSNI(`*`)", "services": [{"name": "kps-prometheus", "port": 9090}]}]}}
	count(plane.deny) == 1 with input as beside
	to_it := {"kind": "IngressRouteTCP", "metadata": {"name": "x", "namespace": "traefik"}, "spec": {"routes": [{"match": "HostSNI(`*`)", "services": [{"name": "kps-prometheus", "namespace": "monitoring", "port": 9090}]}]}}
	count(plane.deny) == 1 with input as to_it
	udp := {"kind": "IngressRouteUDP", "metadata": {"name": "x", "namespace": "infisical"}, "spec": {"routes": [{"services": [{"name": "infisical", "port": 8080}]}]}}
	count(plane.deny) == 1 with input as udp
}

workload_with_image(image) := {
	"kind": "Deployment",
	"metadata": {"name": "x"},
	"spec": {"template": {"spec": {"containers": [{"name": "c", "image": image}]}}},
}

test_bitnami_image_rejected if {
	count(plane.deny) == 1 with input as workload_with_image("docker.io/bitnami/postgresql:17")
	count(plane.deny) == 1 with input as workload_with_image("bitnamilegacy/redis:7")
	count(plane.deny) == 1 with input as workload_with_image("registry-1.docker.io/bitnamisecure/minio@sha256:abc")
}

application_from(repo) := {"kind": "Application", "metadata": {"name": "x"}, "spec": {"source": {"repoURL": repo, "chart": "postgresql"}}}

test_bitnami_chart_rejected if {
	count(plane.deny) == 1 with input as application_from("https://charts.bitnami.com/bitnami")
	count(plane.deny) == 1 with input as application_from("registry-1.docker.io/bitnamicharts")
}

test_bitnami_mention_in_prose_accepted if {
	doc := {"kind": "ConfigMap", "metadata": {"name": "x"}, "data": {"note": "The Bitnami images are frozen, so upstream's are used."}}
	count(plane.deny) == 0 with input as doc
}

test_similar_names_accepted if {
	count(plane.deny) == 0 with input as workload_with_image("docker.io/notbitnami/postgresql:17")
}

internal_route(namespace, match, middlewares) := {
	"kind": "IngressRoute",
	"metadata": {"name": "internal", "namespace": namespace},
	"spec": {"routes": [{"match": match, "kind": "Rule", "middlewares": middlewares, "services": [{"name": "ui", "port": 80}]}]},
}

test_internal_route_with_the_allow_list_accepted if {
	count(plane.deny) == 0 with input as internal_route("monitoring", "Host(`prometheus.localhost`)", [{"name": "node-network-only"}])
	count(plane.deny) == 0 with input as internal_route("argocd", "Host(`argocd.localhost`)", [{"name": "node-network-only"}])
	count(plane.deny) == 0 with input as internal_route("infisical", "Host(`infisical.localhost`)", [{"name": "node-network-only"}])
}

test_every_internal_host_needs_the_allow_list if {
	count(plane.deny) == 1 with input as internal_route("argocd", "Host(`argocd.localhost`)", [])
	count(plane.deny) == 1 with input as internal_route("monitoring", "Host(`grafana.localhost`)", [])
	count(plane.deny) == 1 with input as internal_route("monitoring", "Host(`prometheus.localhost`)", [])
	count(plane.deny) == 1 with input as internal_route("monitoring", "Host(`alertmanager.localhost`)", [])
	count(plane.deny) == 1 with input as internal_route("infisical", "Host(`infisical.localhost`)", [])
}

test_internal_route_with_no_middlewares_field_rejected if {
	doc := {
		"kind": "IngressRoute",
		"metadata": {"name": "internal", "namespace": "monitoring"},
		"spec": {"routes": [{"match": "Host(`grafana.localhost`)", "kind": "Rule", "services": [{"name": "ui", "port": 80}]}]},
	}
	count(plane.deny) == 1 with input as doc
}

test_internal_route_with_another_middleware_rejected if {
	count(plane.deny) == 1 with input as internal_route("monitoring", "Host(`grafana.localhost`)", [{"name": "strip-prefix"}])
}

test_internal_route_respelled_rejected if {
	count(plane.deny) == 1 with input as internal_route("monitoring", "Host(`PROMETHEUS.LOCALHOST`)", [])
	count(plane.deny) == 1 with input as internal_route("monitoring", "HostRegexp(`^prometheus\\.localhost$`)", [])
	count(plane.deny) == 1 with input as internal_route("monitoring", "Host(`x.localhost`) || Host(`alertmanager.localhost`)", [])
}

test_one_of_several_routes_missing_the_allow_list_rejected if {
	doc := {
		"kind": "IngressRoute",
		"metadata": {"name": "internal", "namespace": "monitoring"},
		"spec": {"routes": [
			{"match": "Host(`grafana.localhost`)", "middlewares": [{"name": "node-network-only"}]},
			{"match": "Host(`grafana.localhost`) && PathPrefix(`/api`)"},
		]},
	}
	count(plane.deny) == 1 with input as doc
}

test_other_hosts_elsewhere_need_no_allow_list if {
	count(plane.deny) == 0 with input as internal_route("traefik", "Host(`traefik.localhost`)", [])
	count(plane.deny) == 0 with input as route("Host(`plane.dev.localhost`)", "plane-web")
}

route_to(namespace, match, service, middlewares) := {
	"kind": "IngressRoute",
	"metadata": {"name": "x", "namespace": namespace},
	"spec": {"routes": [{"match": match, "kind": "Rule", "middlewares": middlewares, "services": [service]}]},
}

# The five real backends, from monitoring/manifests/shared/ingress-routes.yaml, infisical/manifests/ingressroute.yaml
# and gitops/bootstrap/argocd-route/ingressroute.yaml.
real_ui_backends := [
	["monitoring", {"name": "kps-grafana", "port": 80}],
	["monitoring", {"name": "kps-prometheus", "port": 9090}],
	["monitoring", {"name": "kps-alertmanager", "port": 9093}],
	["argocd", {"name": "argocd-server", "port": 80}],
	["infisical", {"name": "infisical", "port": 8080}],
]

test_every_real_backend_needs_the_allow_list_under_any_spelling if {
	every backend in real_ui_backends {
		every match in ["Host(`metrics.localhost`)", "PathPrefix(`/`)", "HostRegexp(`^prometheus\\..+$`)", "HostRegexp(`^prometheus[.]localhost$`)", "HostRegexp(`.+`)"] {
			denied := plane.deny with input as route_to(backend[0], match, backend[1], [])
			count(denied) == 1
		}
	}
}

test_every_real_backend_with_the_allow_list_accepted if {
	every backend in real_ui_backends {
		denied := plane.deny with input as route_to(backend[0], "Host(`metrics.localhost`)", backend[1], [{"name": "node-network-only"}])
		count(denied) == 0
	}
}

test_route_to_a_ui_from_another_namespace_rejected if {
	every pair in real_ui_backends {
		backend := object.union(pair[1], {"namespace": pair[0]})
		denied := plane.deny with input as route_to("traefik", "Host(`metrics.localhost`)", backend, [])
		count(denied) == 1
		allowed := plane.deny with input as route_to("traefik", "Host(`metrics.localhost`)", backend, [{"name": "node-network-only"}])
		count(allowed) == 0
		from_plane := plane.deny with input as route_to("plane-dev", "Host(`plane.dev.localhost`) && PathPrefix(`/metrics`)", backend, [])
		count(from_plane) == 1
	}
}

test_any_route_in_a_namespace_with_a_ui_needs_the_allow_list if {
	count(plane.deny) == 1 with input as route_to("monitoring", "Host(`logs.localhost`)", {"name": "loki", "port": 3100}, [])
	count(plane.deny) == 1 with input as route_to("argocd", "Host(`repo.localhost`)", {"name": "argocd-repo-server", "port": 8081}, [])
	count(plane.deny) == 1 with input as route_to("infisical", "Host(`db.localhost`)", {"name": "infisical-postgres", "port": 5432}, [])
}

test_a_route_with_no_namespace_counts_as_beside_a_ui if {
	route_with_none := {
		"kind": "IngressRoute",
		"metadata": {"name": "x"},
		"spec": {"routes": [{"match": "Host(`logs.localhost`)", "services": [{"name": "loki", "port": 3100}]}]},
	}
	count(plane.deny) == 1 with input as route_with_none
	tcp_with_none := {"kind": "IngressRouteTCP", "metadata": {"name": "x"}, "spec": {"routes": [{"match": "HostSNI(`*`)", "services": [{"name": "loki", "port": 3100}]}]}}
	count(plane.deny) == 1 with input as tcp_with_none
	no_metadata := {"kind": "IngressRoute", "spec": {"routes": [{"match": "Host(`logs.localhost`)", "services": [{"name": "loki", "port": 3100}]}]}}
	count(plane.deny) == 1 with input as no_metadata
}

# A blank `namespace:` reads as null, and Argo CD takes any of these for no namespace at all.
test_a_blank_or_null_namespace_counts_as_beside_a_ui if {
	every namespace in ["", null, false, 0] {
		ingress_denied := plane.deny with input as route_to(namespace, "Host(`logs.localhost`)", {"name": "loki", "port": 3100}, [])
		count(ingress_denied) == 1
		tcp_denied := plane.deny with input as {"kind": "IngressRouteTCP", "metadata": {"name": "x", "namespace": namespace}, "spec": {"routes": [{"match": "HostSNI(`*`)", "services": [{"name": "loki", "port": 3100}]}]}}
		count(tcp_denied) == 1
		udp_denied := plane.deny with input as {"kind": "IngressRouteUDP", "metadata": {"name": "x", "namespace": namespace}, "spec": {"routes": [{"services": [{"name": "loki", "port": 3100}]}]}}
		count(udp_denied) == 1
		allowed := plane.deny with input as route_to(namespace, "Host(`logs.localhost`)", {"name": "loki", "port": 3100}, [{"name": "node-network-only"}])
		count(allowed) == 0
	}
}

test_an_internal_host_on_a_backend_of_its_own_still_needs_the_allow_list if {
	count(plane.deny) == 1 with input as route_to("traefik", "Host(`grafana.localhost`)", {"name": "whoami", "port": 80}, [])
}

test_a_plane_service_named_like_nothing_internal_needs_no_allow_list if {
	count(plane.deny) == 0 with input as route_to("plane-dev", "Host(`plane.dev.localhost`) && PathPrefix(`/api`)", {"name": "plane-api", "port": 8000}, [])
}

allow_list(spec) := {"kind": "Middleware", "metadata": {"name": "node-network-only", "namespace": "monitoring"}, "spec": spec}

test_the_allow_list_itself_accepted if {
	count(plane.deny) == 0 with input as allow_list({"ipAllowList": {"sourceRange": ["172.16.0.0/12"]}})
}

test_an_opened_allow_list_rejected if {
	count(plane.deny) == 1 with input as allow_list({"ipAllowList": {"sourceRange": ["0.0.0.0/0"]}})
	count(plane.deny) == 1 with input as allow_list({"ipAllowList": {"sourceRange": ["172.16.0.0/12", "10.244.0.0/16"]}})
	count(plane.deny) == 1 with input as allow_list({"stripPrefix": {"prefixes": ["/"]}})
}

test_an_allow_list_reading_a_header_rejected if {
	count(plane.deny) == 1 with input as allow_list({"ipAllowList": {"sourceRange": ["172.16.0.0/12"], "ipStrategy": {"depth": 1}}})
}
