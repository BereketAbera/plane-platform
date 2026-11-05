# Shared helpers for reading Kubernetes objects. Rules live in the sibling packages.
package lib.kube

import rego.v1

template_kinds := {"Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job"}

pod_spec(obj) := obj.spec.template.spec if template_kinds[obj.kind]

pod_spec(obj) := obj.spec.jobTemplate.spec.template.spec if obj.kind == "CronJob"

pod_spec(obj) := obj.spec if obj.kind == "Pod"

is_workload(obj) if pod_spec(obj)

# Every container the pod will run, init and ephemeral included: each one pulls an image
# and consumes memory, so the rules must not stop at spec.containers.
containers(obj) := [c |
	some field in ["containers", "initContainers", "ephemeralContainers"]
	some c in object.get(pod_spec(obj), field, [])
]

label(obj) := sprintf("%s %s/%s", [obj.kind, object.get(obj.metadata, "namespace", "-"), obj.metadata.name])

# Argo CD applies the items of a document with a top-level items array and drops the document itself, whatever its kind
# says (reposerver/repository/repository.go:1788 at v3.5.7, and Unstructured.IsList reads only items). Conftest reads only
# the outer document, so nothing inside would meet a rule here, and kubeconform passes both a kind: List and a route with
# items beside its spec. Nothing in this repository uses one. A List has no metadata, so this cannot use label.
wraps_other_objects(obj) if {
	is_string(obj.kind)
	endswith(obj.kind, "List")
}

wraps_other_objects(obj) if is_array(obj.items)

wrapper_denied(obj) := sprintf("kind %v wraps other objects, which these rules would not read, so write each as its own document", [object.get(obj, "kind", "")])

# An Application's sources, whichever of the two spec fields it uses.
app_sources(obj) := obj.spec.sources if obj.spec.sources

app_sources(obj) := [obj.spec.source] if {
	not obj.spec.sources
	obj.spec.source
}
