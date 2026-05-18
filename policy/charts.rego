# Third-party platform charts, rendered in CI only. Run with --namespace charts.
#
# We set their values but do not author their templates, so a missing memory limit only warns. A
# digest is different: every chart here can take one through its values, and an image is what runs.
package charts

import data.lib.kube
import rego.v1

warn contains msg if {
	kube.is_workload(input)
	some c in kube.containers(input)
	not c.resources.limits.memory
	msg := sprintf("%s: container %q has no memory limit, so set one in helm/values", [kube.label(input), c.name])
}

digest_pinned := `@sha256:[a-f0-9]{64}$`

deny contains msg if {
	kube.is_workload(input)
	some c in kube.containers(input)
	not regex.match(digest_pinned, c.image)
	msg := sprintf("%s: container %q runs %q, and a platform chart image must be pinned by @sha256 digest in helm/values", [kube.label(input), c.name, c.image])
}

# The operator builds these pods from the resource, so the image is here and not in a pod template.
operator_managed_kinds := {"Prometheus", "PrometheusAgent", "Alertmanager", "ThanosRuler"}

deny contains msg if {
	operator_managed_kinds[input.kind]
	image := object.get(input.spec, "image", "")
	not regex.match(digest_pinned, image)
	msg := sprintf("%s: spec.image is %q, and a platform chart image must be pinned by @sha256 digest in helm/values", [kube.label(input), image])
}

# The operator also takes images on its command line, and runs the config reloader as a sidecar.
deny contains msg if {
	kube.is_workload(input)
	some c in kube.containers(input)
	some arg in object.get(c, "args", [])
	parts := regex.find_all_string_submatch_n(`^(--[a-z-]*(?:-base-image|config-reloader))=(.+)$`, arg, 1)[0]
	not unused_image_flags[parts[1]]
	not regex.match(digest_pinned, parts[2])
	msg := sprintf("%s: container %q has %s=%s, and a platform chart image must be pinned by @sha256 digest in helm/values", [kube.label(input), c.name, parts[1], parts[2]])
}

# The real exceptions: images a chart names that nothing here runs, each with why. scan-images.sh
# leaves these out for the same reason.
unused_image_flags := {
	# A default for Thanos, which the operator starts only for a Prometheus with spec.thanos or for a
	# ThanosRuler, and the rule below refuses both. prometheusOperator.thanosImage.sha could pin it.
	"--thanos-default-base-image",
}

deny contains msg if {
	input.kind == "ThanosRuler"
	msg := sprintf("%s: Thanos would start from an unpinned default, so pin prometheusOperator.thanosImage.sha and drop the exception in policy/charts.rego first", [kube.label(input)])
}

deny contains msg if {
	input.kind == "Prometheus"
	input.spec.thanos
	msg := sprintf("%s: spec.thanos would start from an unpinned default, so pin prometheusOperator.thanosImage.sha and drop the exception in policy/charts.rego first", [kube.label(input)])
}
