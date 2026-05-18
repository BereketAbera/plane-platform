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
	count(plane.deny) == 0 with input as route_in("monitoring", "Host(`grafana.localhost`)", "grafana")
}

test_platform_route_naming_a_plane_host_rejected if {
	count(plane.deny) == 1 with input as route_in("monitoring", "Host(`plane.prod-sim.localhost`)", "grafana")
}

test_tcp_route_in_a_plane_namespace_rejected if {
	doc := {"kind": "IngressRouteTCP", "metadata": {"name": "x", "namespace": "plane-dev"}, "spec": {"routes": [{"match": "HostSNI(`*`)"}]}}
	count(plane.deny) == 1 with input as doc
}

test_tcp_route_elsewhere_ignored if {
	doc := {"kind": "IngressRouteTCP", "metadata": {"name": "x", "namespace": "monitoring"}, "spec": {"routes": [{"match": "HostSNI(`*`)"}]}}
	count(plane.deny) == 0 with input as doc
}
