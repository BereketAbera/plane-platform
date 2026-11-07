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

infisical(kind, name) := {"kind": kind, "metadata": {"name": name, "namespace": "infisical"}}

# Found by the host it serves, so a route here needs a rule on that host, as the real one's four all are.
infisical_route(namespace, name, match) := {
	"kind": "IngressRoute",
	"metadata": {"name": name, "namespace": namespace},
	"spec": {"routes": [{"kind": "Rule", "match": match, "middlewares": [{"name": "infisical-guess-limit"}], "services": [{"name": "infisical", "port": 8080}]}]},
}

the_route := infisical_route("infisical", "infisical", "Host(`infisical.bereket.dev`) && Method(`POST`) && Path(`/api/v3/auth/login`)")

# What hosted production is, as validate-manifests.sh hands it over beside the manifests.
target_read(domain) := {"path": "infrastructure/hosted/plane-prod/target.yaml", "contents": {"name": "plane-prod", "domain": "wayline.bereket.dev", "infisical_domain": domain}}

with_target(objects) := array.concat(as_read(objects), [target_read("infisical.bereket.dev")])

infisical_everything := [
	the_route,
	infisical("Middleware", "infisical-guess-limit"),
	infisical("Middleware", "infisical-session-limit"),
	infisical("Probe", "infisical"),
	infisical("Probe", "infisical-claimed"),
	infisical("Probe", "infisical-sign-in"),
	infisical("Probe", "infisical-session"),
]

# The IngressRoute and a Probe share the name infisical, so this names the kind too.
infisical_without(kind, name) := [object | some object in infisical_everything; object != infisical(kind, name)]

test_infisical_route_with_its_limits_and_probes_accepted if {
	count(hosted_combined.deny) == 0 with input as with_target(infisical_everything)
}

# Each limit and each Probe, gone, is a route that fails closed or an alert that reads nothing, and neither shows in one object.
test_infisical_route_without_a_limit_or_a_probe_rejected if {
	every gone in [["Middleware", "infisical-guess-limit"], ["Middleware", "infisical-session-limit"], ["Probe", "infisical"], ["Probe", "infisical-claimed"], ["Probe", "infisical-sign-in"], ["Probe", "infisical-session"]] {
		denied := hosted_combined.deny with input as with_target(infisical_without(gone[0], gone[1]))
		count(denied) == 1
		some msg in denied
		contains(msg, sprintf("%s infisical/%s is not", gone))
	}
}

test_infisical_limit_in_another_namespace_rejected if {
	elsewhere := json.patch(infisical("Middleware", "infisical-guess-limit"), [{"op": "replace", "path": "/metadata/namespace", "value": "monitoring"}])
	count(hosted_combined.deny) == 1 with input as with_target(array.concat(infisical_without("Middleware", "infisical-guess-limit"), [elsewhere]))
}

# The name says nothing: a route renamed, in any namespace or in any case, is still the route on Infisical's host, and needs what it names.
test_infisical_route_found_by_its_host_rejected_without_its_limit if {
	every route in [
		infisical_route("infisical", "infisical-public", the_route.spec.routes[0].match),
		infisical_route("plane-prod", "infisical", the_route.spec.routes[0].match),
		infisical_route("infisical", "secrets", "Host(`Infisical.Bereket.Dev`) && PathPrefix(`/`)"),
		infisical_route("infisical", "secrets", "HostRegexp(`^infisical\\.bereket\\.dev$`)"),
	] {
		objects := array.concat([route], [o | some o in infisical_everything; o != the_route; o != infisical("Middleware", "infisical-guess-limit")])
		denied := hosted_combined.deny with input as with_target(objects)
		count(denied) == 1
		some msg in denied
		contains(msg, sprintf("IngressRoute %s/%s serves infisical.bereket.dev, and Middleware infisical/infisical-guess-limit is not", [route.metadata.namespace, route.metadata.name]))
	}
}

test_a_route_on_another_host_needs_nothing_of_infisicals if {
	grafanas := infisical_route("monitoring", "grafana", "Host(`grafana.bereket.dev`) && !PathPrefix(`/metrics`)")
	count(hosted_combined.deny) == 0 with input as with_target([grafanas])
}

test_no_infisical_route_accepted if {
	count(hosted_combined.deny) == 0 with input as with_target([infisical("Middleware", "infisical-guess-limit")])
	count(hosted_combined.deny) == 0 with input as as_read([infisical("Middleware", "infisical-guess-limit")])
}

# With no host to look for, no route would be Infisical's, so a route with nothing to say which one is refused.
test_a_route_with_no_target_to_read_rejected if {
	every read in [
		as_read(infisical_everything),
		array.concat(with_target(infisical_everything), [target_read("infisical.bereket.dev")]),
		array.concat(as_read(infisical_everything), [target_read("")]),
		array.concat(as_read(infisical_everything), [{"path": "target.yaml", "contents": {"infisical_domain": "infisical.bereket.dev"}}]),
	] {
		denied := hosted_combined.deny with input as read
		count(denied) == 1
		some msg in denied
		contains(msg, "so nothing here can say which route is Infisical's")
	}
}

# The record and the policy name one host, so neither moves alone.
test_a_target_unlike_the_policy_rejected if {
	denied := hosted_combined.deny with input as array.concat(as_read(infisical_everything), [target_read("vault.bereket.dev")])
	count(denied) == 1
	some msg in denied
	contains(msg, "puts Infisical at vault.bereket.dev, where Terraform points its A record, and policy/hosted.rego allows its routes only at infisical.bereket.dev")
}
