package charts_test

import data.charts
import rego.v1

test_missing_limit_warns if {
	doc := {
		"kind": "Deployment",
		"metadata": {"name": "traefik"},
		"spec": {"template": {"spec": {"containers": [{"name": "c", "image": "i"}]}}},
	}
	count(charts.warn) == 1 with input as doc
}

test_limit_present_is_quiet if {
	doc := {
		"kind": "Deployment",
		"metadata": {"name": "traefik"},
		"spec": {"template": {"spec": {"containers": [{"name": "c", "image": "i", "resources": {"limits": {"memory": "64Mi"}}}]}}},
	}
	count(charts.warn) == 0 with input as doc
}
