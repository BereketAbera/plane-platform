package hosted_combined_test

import data.hosted_combined
import rego.v1

# As conftest --combine hands them over: every document of every file, each with the file it came from.
as_read(objects) := [{"path": "kube-prometheus-stack.yaml", "contents": object} | some object in objects]

grafana(kind) := {"kind": kind, "metadata": {"name": "kps-grafana", "namespace": "monitoring"}}

grafana_config := object.union(grafana("ConfigMap"), {"data": {"grafana.ini": "[auth.basic]\nenabled = false\n"}})

everything := [grafana("Deployment"), grafana_config, grafana("Role"), grafana("RoleBinding"), grafana("ServiceAccount")]

without(kind) := [object | some object in everything; object.kind != kind]

test_grafana_with_all_it_needs_accepted if {
	count(hosted_combined.deny) == 0 with input as as_read(everything)
}

test_grafana_without_its_role_rejected if {
	denied := hosted_combined.deny with input as as_read(without("Role"))
	count(denied) == 1
	some msg in denied
	contains(msg, "Role monitoring/kps-grafana is not")
}

test_grafana_without_its_binding_or_config_rejected if {
	count(hosted_combined.deny) == 1 with input as as_read(without("RoleBinding"))
	count(hosted_combined.deny) == 1 with input as as_read(without("ConfigMap"))
	count(hosted_combined.deny) == 1 with input as as_read(array.concat(without("ConfigMap"), [object.union(grafana("ConfigMap"), {"data": {}})]))
}

# The same names elsewhere are not Grafana's.
test_grafana_objects_in_another_namespace_rejected if {
	elsewhere := json.patch(grafana("Role"), [{"op": "replace", "path": "/metadata/namespace", "value": "other"}])
	count(hosted_combined.deny) == 1 with input as as_read(array.concat(without("Role"), [elsewhere]))
}

test_no_grafana_at_all_accepted if {
	count(hosted_combined.deny) == 0 with input as as_read([grafana("Role")])
	count(hosted_combined.deny) == 0 with input as []
}

# Read one object at a time, as every other conftest run here does, this says nothing.
test_one_object_alone_ignored if {
	count(hosted_combined.deny) == 0 with input as grafana("Deployment")
	count(hosted_combined.deny) == 0 with input as {"kind": "ConfigMap", "data": {"contents": grafana("Deployment")}}
}
