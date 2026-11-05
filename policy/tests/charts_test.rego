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

good_digest := "sha256:54e0dd8e8cddcdbb9156c2486eed5a43eccb7214d7c6828097d41ce049fb3984"

pinned := concat("@", ["docker.io/traefik", good_digest])

workload(image, args) := {
	"kind": "Deployment",
	"metadata": {"name": "traefik"},
	"spec": {"template": {"spec": {"containers": [{"name": "c", "image": image, "args": args}]}}},
}

test_pinned_image_accepted if {
	count(charts.deny) == 0 with input as workload(pinned, [])
}

test_tag_only_image_rejected if {
	count(charts.deny) == 1 with input as workload("docker.io/traefik:v3.7.17", [])
}

test_init_container_checked if {
	doc := {
		"kind": "StatefulSet",
		"metadata": {"name": "loki"},
		"spec": {"template": {"spec": {
			"containers": [{"name": "c", "image": pinned}],
			"initContainers": [{"name": "i", "image": "busybox:1.37"}],
		}}},
	}
	count(charts.deny) == 1 with input as doc
}

test_prometheus_resource_checked if {
	count(charts.deny) == 1 with input as {"kind": "Prometheus", "metadata": {"name": "p"}, "spec": {"image": "quay.io/prometheus/prometheus:v3"}}
	count(charts.deny) == 0 with input as {"kind": "Prometheus", "metadata": {"name": "p"}, "spec": {"image": pinned}}
}

test_alertmanager_resource_with_no_image_rejected if {
	count(charts.deny) == 1 with input as {"kind": "Alertmanager", "metadata": {"name": "a"}, "spec": {}}
}

test_operator_reloader_flag_checked if {
	count(charts.deny) == 1 with input as workload(pinned, ["--prometheus-config-reloader=quay.io/x/reloader:v1"])
	count(charts.deny) == 0 with input as workload(pinned, [concat("", ["--prometheus-config-reloader=quay.io/x/reloader@", good_digest])])
}

test_operator_default_base_image_flag_checked if {
	count(charts.deny) == 1 with input as workload(pinned, ["--prometheus-default-base-image=quay.io/prometheus/prometheus:v3"])
}

test_reloader_resource_flags_ignored if {
	count(charts.deny) == 0 with input as workload(pinned, ["--config-reloader-cpu-limit=50m", "--log-level=info"])
}

test_thanos_default_flag_checked if {
	count(charts.deny) == 1 with input as workload(pinned, ["--thanos-default-base-image=quay.io/thanos/thanos:v0.42.5"])
	count(charts.deny) == 0 with input as workload(pinned, [concat("", ["--thanos-default-base-image=quay.io/thanos/thanos:v0.42.5@", good_digest])])
}

test_thanos_sidecar_image_checked if {
	count(charts.deny) == 1 with input as {"kind": "Prometheus", "metadata": {"name": "p"}, "spec": {"image": pinned, "thanos": {"image": "quay.io/thanos/thanos:v0.42.5"}}}
	count(charts.deny) == 0 with input as {"kind": "Prometheus", "metadata": {"name": "p"}, "spec": {"image": pinned, "thanos": {"image": pinned}}}
	count(charts.deny) == 0 with input as {"kind": "Prometheus", "metadata": {"name": "p"}, "spec": {"image": pinned, "thanos": {"version": "v0.42.5"}}}
}

test_thanos_ruler_image_checked if {
	count(charts.deny) == 1 with input as {"kind": "ThanosRuler", "metadata": {"name": "t"}, "spec": {"image": "quay.io/thanos/thanos:v0.42.5"}}
	count(charts.deny) == 0 with input as {"kind": "ThanosRuler", "metadata": {"name": "t"}, "spec": {"image": pinned}}
}
