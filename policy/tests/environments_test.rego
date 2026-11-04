package environments_test

import data.environments
import rego.v1

good_digest := "sha256:54e0dd8e8cddcdbb9156c2486eed5a43eccb7214d7c6828097d41ce049fb3984"

deployment(image) := {
	"kind": "Deployment",
	"metadata": {"name": "plane-web-wl", "namespace": "plane-dev"},
	"spec": {"template": {"spec": {"containers": [{"name": "web", "image": image}]}}},
}

test_digest_pin_accepted if {
	count(environments.deny) == 0 with input as deployment(concat("@", ["localhost:5001/wayline/web", good_digest]))
}

test_tag_rejected if {
	count(environments.deny) == 1 with input as deployment("makeplane/plane-frontend:v1.4.3")
}

test_truncated_digest_rejected if {
	count(environments.deny) == 1 with input as deployment("makeplane/plane-frontend@sha256:abc")
}

test_tag_plus_digest_accepted if {
	count(environments.deny) == 0 with input as deployment(concat("@", ["postgres:15.19-alpine", good_digest]))
}

test_init_container_checked if {
	doc := {
		"kind": "StatefulSet",
		"metadata": {"name": "plane-pgdb-wl"},
		"spec": {"template": {"spec": {
			"containers": [{"name": "pg", "image": concat("@", ["postgres", good_digest])}],
			"initContainers": [{"name": "init", "image": "busybox:1.37"}],
		}}},
	}
	count(environments.deny) == 1 with input as doc
}

test_cronjob_checked if {
	doc := {
		"kind": "CronJob",
		"metadata": {"name": "backup"},
		"spec": {"jobTemplate": {"spec": {"template": {"spec": {"containers": [{"name": "b", "image": "postgres:15"}]}}}}},
	}
	count(environments.deny) == 1 with input as doc
}

test_networkpolicy_rejected if {
	count(environments.deny) == 1 with input as {"kind": "NetworkPolicy", "metadata": {"name": "allow-api"}}
}

test_cluster_scoped_rejected if {
	count(environments.deny) == 1 with input as {"kind": "ClusterRoleBinding", "metadata": {"name": "x"}}
}

test_presync_hook_rejected if {
	doc := {
		"kind": "ConfigMap",
		"metadata": {"name": "x", "annotations": {"argocd.argoproj.io/hook": "PreSync"}},
	}
	count(environments.deny) == 1 with input as doc
}

test_sync_hook_accepted if {
	doc := {
		"kind": "ConfigMap",
		"metadata": {"name": "x", "annotations": {"argocd.argoproj.io/hook": "Sync"}},
	}
	count(environments.deny) == 0 with input as doc
}

test_empty_document_ignored if {
	count(environments.deny) == 0 with input as {}
}
