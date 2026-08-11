# Workloads this repository authors or renders. Run with --namespace workloads.
package workloads

import data.lib.kube
import rego.v1

# Pods that must talk to the Kubernetes API, and so may keep a token. Keep this list short and
# name real operators only. It is keyed on name, never on a label or annotation the manifest
# could set for itself. These are the Deployment names the secrets-operator chart renders with the
# fullnameOverride in helm/values/infisical-operator-{dev,prod-sim}.yaml, and for hosted production in
# gitops/clusters/plane-prod/values.
api_clients := {"iso-dev-controller-manager", "iso-prod-sim-controller-manager", "iso-prod-controller-manager"}

deny contains msg if {
	kube.is_workload(input)
	some c in kube.containers(input)
	not c.resources.limits.memory
	msg := sprintf("%s: container %q has no memory limit", [kube.label(input), c.name])
}

deny contains msg if {
	kube.is_workload(input)
	not api_clients[input.metadata.name]
	not kube.pod_spec(input).automountServiceAccountToken == false
	msg := sprintf("%s: pod spec must set automountServiceAccountToken: false", [kube.label(input)])
}

# The chart hard-codes true on its ServiceAccount, and only the pod spec overrides it, so a
# new workload that forgets the field would silently get a token.
deny contains msg if {
	input.kind == "ServiceAccount"
	not api_clients[input.metadata.name]
	input.automountServiceAccountToken == true
	msg := sprintf("%s: ServiceAccount must not automount its token", [kube.label(input)])
}
