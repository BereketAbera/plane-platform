package gitops_test

import data.gitops
import rego.v1

test_secret_rejected if {
	count(gitops.deny) == 1 with input as {"kind": "Secret", "metadata": {"name": "plane-app-env", "namespace": "plane-dev"}}
}

test_operator_cr_accepted if {
	count(gitops.deny) == 0 with input as {"kind": "InfisicalStaticSecret", "metadata": {"name": "plane-app-env"}}
}

test_configmap_accepted if {
	count(gitops.deny) == 0 with input as {"kind": "ConfigMap", "metadata": {"name": "x"}}
}
