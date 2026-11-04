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
