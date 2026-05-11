package workloads_test

import data.workloads
import rego.v1

pod_template(name, automount, resources) := {
	"kind": "Deployment",
	"metadata": {"name": name, "namespace": "plane-dev"},
	"spec": {"template": {"spec": object.union(automount, {"containers": [object.union({"name": "c", "image": "i"}, resources)]})}},
}

limited := {"resources": {"limits": {"memory": "64Mi"}}}

token_off := {"automountServiceAccountToken": false}

token_on := {"automountServiceAccountToken": true}

test_compliant_accepted if {
	count(workloads.deny) == 0 with input as pod_template("plane-web-wl", token_off, limited)
}

test_missing_memory_limit_rejected if {
	count(workloads.deny) == 1 with input as pod_template("plane-web-wl", token_off, {})
}

test_cpu_limit_alone_rejected if {
	count(workloads.deny) == 1 with input as pod_template("plane-web-wl", token_off, {"resources": {"limits": {"cpu": "1"}}})
}

test_init_container_limit_required if {
	doc := {
		"kind": "Job",
		"metadata": {"name": "plane-migrator"},
		"spec": {"template": {"spec": {
			"automountServiceAccountToken": false,
			"containers": [object.union({"name": "c", "image": "i"}, limited)],
			"initContainers": [{"name": "i", "image": "i"}],
		}}},
	}
	count(workloads.deny) == 1 with input as doc
}

test_automount_absent_rejected if {
	count(workloads.deny) == 1 with input as pod_template("plane-web-wl", {}, limited)
}

test_automount_true_rejected if {
	count(workloads.deny) == 1 with input as pod_template("plane-web-wl", token_on, limited)
}

test_allowlisted_operator_may_automount if {
	count(workloads.deny) == 0 with input as pod_template("iso-dev-controller-manager", token_on, limited)
}

test_allowlisted_operator_still_needs_memory_limit if {
	count(workloads.deny) == 1 with input as pod_template("iso-dev-controller-manager", token_on, {})
}

test_serviceaccount_automount_rejected if {
	count(workloads.deny) == 1 with input as {"kind": "ServiceAccount", "metadata": {"name": "plane"}, "automountServiceAccountToken": true}
}

test_serviceaccount_token_off_accepted if {
	count(workloads.deny) == 0 with input as {"kind": "ServiceAccount", "metadata": {"name": "plane"}, "automountServiceAccountToken": false}
}

test_non_workload_ignored if {
	count(workloads.deny) == 0 with input as {"kind": "ConfigMap", "metadata": {"name": "x"}}
}
