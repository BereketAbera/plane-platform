# Third-party platform charts, rendered in CI only. We set their values but do not author their
# templates, so these rules warn and do not fail. Run with --namespace charts.
package charts

import data.lib.kube
import rego.v1

warn contains msg if {
	kube.is_workload(input)
	some c in kube.containers(input)
	not c.resources.limits.memory
	msg := sprintf("%s: container %q has no memory limit, so set one in helm/values", [kube.label(input), c.name])
}
