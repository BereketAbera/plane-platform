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

application(name, project, namespace, source) := {
	"kind": "Application",
	"metadata": {"name": name, "namespace": "argocd"},
	"spec": {"project": project, "destination": {"namespace": namespace}, "source": source},
}

rendered(env) := {"path": sprintf("gitops/environments/%s", [env])}

test_plane_application_in_its_own_project_accepted if {
	count(gitops.deny) == 0 with input as application("plane-dev", "plane-dev", "plane-dev", rendered("dev"))
	count(gitops.deny) == 0 with input as application("plane-prod-sim", "plane-prod-sim", "plane-prod-sim", rendered("prod-sim"))
}

test_platform_application_accepted if {
	count(gitops.deny) == 0 with input as application("loki", "platform", "monitoring", {"chart": "loki"})
}

test_operator_in_a_plane_namespace_under_platform_accepted if {
	count(gitops.deny) == 0 with input as application("infisical-operator-dev", "platform", "plane-dev", {"chart": "secrets-operator"})
}

test_default_project_rejected if {
	count(gitops.deny) == 1 with input as application("loki", "default", "monitoring", {"chart": "loki"})
}

test_missing_project_rejected if {
	doc := {"kind": "Application", "metadata": {"name": "loki"}, "spec": {"source": {"chart": "loki"}}}
	count(gitops.deny) == 1 with input as doc
}

test_plane_application_in_platform_rejected if {
	denied := gitops.deny with input as application("plane-dev", "platform", "plane-dev", rendered("dev"))
	count(denied) == 2 # the name, and what it syncs
}

test_plane_application_in_default_rejected if {
	denied := gitops.deny with input as application("plane-dev", "default", "plane-dev", rendered("dev"))
	count(denied) == 3 # default, the name, and what it syncs
}

test_plane_application_in_the_other_environments_project_rejected if {
	count(gitops.deny) > 0 with input as application("plane-dev", "plane-prod-sim", "plane-prod-sim", rendered("dev"))
}

test_renamed_application_syncing_rendered_manifests_rejected if {
	count(gitops.deny) == 1 with input as application("extras", "platform", "plane-dev", rendered("dev"))
}

test_multi_source_application_checked if {
	doc := {
		"kind": "Application",
		"metadata": {"name": "extras"},
		"spec": {
			"project": "platform",
			"destination": {"namespace": "plane-dev"},
			"sources": [{"chart": "loki"}, {"path": "gitops/environments/dev/"}],
		},
	}
	count(gitops.deny) == 1 with input as doc
}

test_parent_directory_of_environments_rejected if {
	count(gitops.deny) == 1 with input as application("plane-dev", "plane-dev", "plane-dev", {"path": "gitops/environments"})
}

test_plane_project_outside_its_namespace_rejected if {
	count(gitops.deny) == 1 with input as application("plane-dev", "plane-dev", "plane-prod-sim", rendered("dev"))
}
