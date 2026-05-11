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

identity := kube.label(input) if input.metadata.name

else := "document"
