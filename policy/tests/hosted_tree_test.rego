package hosted_tree_test

import data.hosted_tree
import rego.v1

# The Postgres policy a commit could add to platform/infisical, and the guess limit keyed on a header any client sets: each with no namespace,
# which Argo CD fills in with namespace infisical.
open_postgres := {
	"apiVersion": "networking.k8s.io/v1",
	"kind": "NetworkPolicy",
	"metadata": {"name": "open-postgres"},
	"spec": {"podSelector": {"matchLabels": {"app.kubernetes.io/name": "infisical-postgres"}}, "policyTypes": ["Ingress"], "ingress": [{}]},
}

guess_limit_on_a_header := {
	"apiVersion": "traefik.io/v1alpha1",
	"kind": "Middleware",
	"metadata": {"name": "infisical-guess-limit"},
	"spec": {"rateLimit": {"average": 1000, "period": "1m", "burst": 1000, "sourceCriterion": {"requestHeaderName": "X-Forwarded-For"}}},
}

with_namespace(doc, namespace) := object.union(doc, {"metadata": {"namespace": namespace}})

says_no_namespace(doc) if {
	denied := hosted_tree.deny with input as doc
	count(denied) == 1
	some msg in denied
	contains(msg, "states no namespace")
}

test_objects_that_state_their_namespace_accepted if {
	count(hosted_tree.deny) == 0 with input as with_namespace(open_postgres, "infisical")
	count(hosted_tree.deny) == 0 with input as with_namespace(guess_limit_on_a_header, "infisical")
	count(hosted_tree.deny) == 0 with input as {"apiVersion": "argoproj.io/v1alpha1", "kind": "Application", "metadata": {"name": "infisical", "namespace": "argocd"}}
}

test_an_object_with_no_namespace_rejected if {
	says_no_namespace(open_postgres)
	says_no_namespace(guess_limit_on_a_header)
	says_no_namespace({"kind": "Probe", "metadata": {"name": "infisical-extra"}, "spec": {}})
	says_no_namespace({"kind": "ConfigMap", "metadata": {"name": "blackbox-config"}, "data": {}})
	says_no_namespace({"kind": "Deployment", "metadata": {"name": "planted"}, "spec": {}})
	says_no_namespace({"kind": "NetworkPolicy", "spec": {}})
}

# Argo CD reads the field as a string, so none of these is a namespace to it.
test_a_blank_null_or_odd_namespace_rejected if {
	every namespace in ["", null, 5, ["infisical"], {"name": "infisical"}] {
		says_no_namespace(with_namespace(open_postgres, namespace))
	}
}

# What the hosted tree holds outside any namespace today: the backups' volumes, the issuers and the token reviewer's binding.
test_cluster_scoped_objects_accepted if {
	every kind in ["PersistentVolume", "ClusterIssuer", "ClusterRoleBinding", "ClusterRole", "CustomResourceDefinition", "StorageClass"] {
		count(hosted_tree.deny) == 0 with input as {"kind": kind, "metadata": {"name": "x"}}
	}
}

test_documents_that_are_no_object_ignored if {
	count(hosted_tree.deny) == 0 with input as {}
	count(hosted_tree.deny) == 0 with input as {"note": "no kind"}
}
