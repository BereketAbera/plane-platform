# Hosted production's tree as a person writes it: what collect_hosted in scripts/ci/lib-manifests.sh gathers from gitops/clusters/plane-prod,
# read one object at a time. Run with --namespace hosted_tree on that and on nothing else. A chart's render states no namespace for most of what
# it holds, because Helm leaves that to whatever applies it, and these rules read only what is written here.
package hosted_tree

import data.lib.kube
import rego.v1

# Kubernetes keeps these outside any namespace, so they state none. A list of what may, so a kind that is not here and states no namespace
# fails, and a new cluster-scoped kind is a line here that a person reads.
cluster_scoped_kinds := {
	"APIService",
	"ClusterIssuer",
	"ClusterRole",
	"ClusterRoleBinding",
	"CustomResourceDefinition",
	"IngressClass",
	"MutatingWebhookConfiguration",
	"Namespace",
	"PersistentVolume",
	"PriorityClass",
	"RuntimeClass",
	"StorageClass",
	"ValidatingAdmissionPolicy",
	"ValidatingAdmissionPolicyBinding",
	"ValidatingWebhookConfiguration",
}

# Argo CD puts an object that states no namespace in its Application's destination, and Helm in its release's, without a word. The rules in
# policy/hosted.rego on what may sit in a namespace read the namespace an object states, so one that states none would pass them all and land
# where they hold: a NetworkPolicy or a Middleware with no namespace in platform/infisical lands in namespace infisical, past every rule on
# what reaches the secret store and what limits its route. Argo CD reads the field as a string, so a blank, a null or anything else that is
# not a string is none to it either, as policy/plane.rego reads it for a route. A document that wraps others has no namespace of its own, and
# policy/gitops.rego refuses it.
deny contains msg if {
	is_string(input.kind)
	not cluster_scoped_kinds[input.kind]
	not kube.wraps_other_objects(input)
	not states_a_namespace
	msg := sprintf("%s: states no namespace, so Argo CD would put it in its Application's destination, past every rule here that reads the namespace an object states. Name the namespace it is for", [identity])
}

states_a_namespace if {
	is_string(input.metadata.namespace)
	input.metadata.namespace != ""
}

identity := kube.label(input) if input.metadata.name

else := sprintf("%s with no name", [input.kind])
