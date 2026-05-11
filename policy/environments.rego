# Rendered Plane manifests only: gitops/environments/**. Run with --namespace environments.
package environments

import data.lib.kube
import rego.v1

digest_pinned := `@sha256:[a-f0-9]{64}$`

# Contract section 7: the plane-dev and plane-prod-sim AppProjects refuse these, so a rendered
# manifest carrying one fails the whole sync rather than one resource (critique C9).
platform_only_kinds := {
	"NetworkPolicy", "Namespace", "ResourceQuota", "LimitRange",
	"ClusterRole", "ClusterRoleBinding", "CustomResourceDefinition",
	"PersistentVolume", "PriorityClass", "StorageClass",
	"MutatingWebhookConfiguration", "ValidatingWebhookConfiguration",
}

deny contains msg if {
	kube.is_workload(input)
	some c in kube.containers(input)
	not regex.match(digest_pinned, c.image)
	msg := sprintf("%s: container %q image %q is not pinned by @sha256 digest", [kube.label(input), c.name, c.image])
}

deny contains msg if {
	platform_only_kinds[input.kind]
	msg := sprintf("%s: belongs to the platform project, not a Plane environment", [kube.label(input)])
}

# Postgres is applied in the Sync phase, so a PreSync migrator exhausts its retries against a
# database that does not exist yet and stops a fresh install (critique C3).
deny contains msg if {
	input.metadata.annotations["argocd.argoproj.io/hook"] == "PreSync"
	msg := sprintf("%s: PreSync hook deadlocks a fresh install, use Sync at wave 2", [kube.label(input)])
}
