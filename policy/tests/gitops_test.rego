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

wrapped_route := {
	"apiVersion": "traefik.io/v1alpha1",
	"kind": "IngressRoute",
	"metadata": {"name": "x", "namespace": "monitoring"},
	"spec": {"routes": [{"match": "Host(`prometheus.localhost`)", "services": [{"name": "kps-prometheus", "port": 9090}]}]},
}

test_a_list_of_any_kind_rejected if {
	count(gitops.deny) == 1 with input as {"apiVersion": "v1", "kind": "List", "items": [wrapped_route]}
	count(gitops.deny) == 1 with input as {"apiVersion": "v1", "kind": "ConfigMapList", "items": []}
	count(gitops.deny) == 1 with input as {"apiVersion": "traefik.io/v1alpha1", "kind": "IngressRouteList", "metadata": {"name": "x"}, "items": [wrapped_route]}
	count(gitops.deny) == 1 with input as {"apiVersion": "v1", "kind": "List", "items": null}
}

# Argo CD goes by the items array alone, so this one's good outer route would never be applied.
test_items_under_any_other_kind_rejected if {
	count(gitops.deny) == 1 with input as object.union(wrapped_route, {"items": [wrapped_route]})
	count(gitops.deny) == 1 with input as {"apiVersion": "example.com/v1", "kind": "Whatever", "items": []}
	count(gitops.deny) == 1 with input as {"items": [wrapped_route]}
}

test_items_lower_down_and_list_inside_a_kind_accepted if {
	count(gitops.deny) == 0 with input as {"kind": "ConfigMap", "metadata": {"name": "x"}, "data": {"items": "[1]"}}
	count(gitops.deny) == 0 with input as {"kind": "Thing", "metadata": {"name": "x"}, "spec": {"items": [1]}}
	count(gitops.deny) == 0 with input as {"kind": "ListenerSet", "metadata": {"name": "x"}}
	count(gitops.deny) == 0 with input as wrapped_route
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
	count(gitops.deny) == 0 with input as application("plane-prod", "plane-prod", "plane-prod", rendered("prod"))
}

test_hosted_render_only_under_its_own_project_rejected if {
	count(gitops.deny) > 0 with input as application("plane-prod", "platform", "plane-prod", rendered("prod"))
	count(gitops.deny) > 0 with input as application("plane-prod", "plane-prod", "plane-prod", rendered("prod-sim"))
	count(gitops.deny) > 0 with input as application("plane-prod", "plane-prod", "plane-dev", rendered("prod"))
	count(gitops.deny) == 1 with input as application("extras", "platform", "plane-prod", rendered("prod"))
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
