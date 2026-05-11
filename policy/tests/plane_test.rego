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

route(match, service) := {
	"kind": "IngressRoute",
	"metadata": {"name": "plane-ingress"},
	"spec": {"routes": [{"match": match, "kind": "Rule", "services": [{"name": service, "port": 9000}]}]},
}

test_uploads_route_accepted if {
	count(plane.deny) == 0 with input as route("Host(`plane.dev.localhost`) && PathPrefix(`/uploads`)", "plane-minio")
}

test_uploads_slash_route_accepted if {
	count(plane.deny) == 0 with input as route("Path(`/uploads`) || PathPrefix(`/uploads/`)", "plane-minio")
}

test_other_bucket_route_rejected if {
	count(plane.deny) == 1 with input as route("Host(`plane.dev.localhost`) && PathPrefix(`/plane-dev-uploads`)", "plane-minio")
}

test_route_to_other_service_ignored if {
	count(plane.deny) == 0 with input as route("PathPrefix(`/api`)", "plane-api")
}
