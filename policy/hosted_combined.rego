# Hosted production read as a whole: the hosted tree and what its charts render, together, which is what Argo CD applies. Run with --combine
# and --namespace hosted_combined, with infrastructure/hosted/plane-prod/target.yaml among the files. policy/hosted.rego reads one object at a
# time, so it can say what an object holds and never that it is there at all, and its rules on Grafana pass when the object they read is
# missing. These say it is there.
package hosted_combined

import data.hosted
import rego.v1

documents := [doc.contents | some doc in input] if {
	is_array(input)
} else := []

grafana_deployed if {
	some doc in documents
	grafana_object(doc, "Deployment")
}

grafana_object(doc, kind) if {
	doc.kind == kind
	doc.metadata.name == "kps-grafana"
	object.get(doc.metadata, "namespace", "") == "monitoring"
}

# What Grafana's pod needs beside it. A ConfigMap counts only with its grafana.ini, which holds the settings that guard the login.
grafana_needs := {
	"ConfigMap": "its grafana.ini holds what guards the login, and with none here nothing has read those settings",
	"Role": "the RoleBinding then grants nothing, and the dashboard sidecar reads no ConfigMap. The chart's values write it in extraObjects",
	"RoleBinding": "the token then holds no Role, and the dashboard sidecar reads no ConfigMap",
}

present(kind) if {
	some doc in documents
	grafana_object(doc, kind)
	kind != "ConfigMap"
}

present("ConfigMap") if {
	some doc in documents
	grafana_object(doc, "ConfigMap")
	is_string(doc.data["grafana.ini"])
}

deny contains msg if {
	grafana_deployed
	some kind, why in grafana_needs
	not present(kind)
	msg := sprintf("Deployment monitoring/kps-grafana is here, and %s monitoring/kps-grafana is not: %s", [kind, why])
}

# What hosted production is. Terraform points Infisical's A record at the VPS from its infisical_domain, so a route on that host is Infisical's
# route, whatever it is called.
target_file := "infrastructure/hosted/plane-prod/target.yaml"

targets := [doc.contents | some doc in input; is_target(doc.path)] if {
	is_array(input)
} else := []

is_target(path) if path == target_file

is_target(path) if endswith(path, concat("", ["/", target_file]))

infisical_host := targets[0].infisical_domain if {
	count(targets) == 1
	is_string(targets[0].infisical_domain)
	targets[0].infisical_domain != ""
}

# With no host, no route below would be Infisical's, and every one of them would need nothing.
deny contains msg if {
	some doc in documents
	doc.kind == "IngressRoute"
	not infisical_host
	msg := sprintf("an IngressRoute is here, and no one %s with an infisical_domain beside it, so nothing here can say which route is Infisical's. Hand this check that file too, as scripts/ci/validate-manifests.sh does", [target_file])
}

# policy/hosted.rego allows Infisical's routes on one host, so it and the record must name the same one.
deny contains msg if {
	infisical_host
	infisical_host != hosted.infisical_host
	msg := sprintf("%s puts Infisical at %s, where Terraform points its A record, and policy/hosted.rego allows its routes only at %s. Change the two together", [target_file, infisical_host, hosted.infisical_host])
}

# Infisical's route names its two limits, and Traefik refuses a route whose Middleware is missing: sign-in or token refresh would answer 404,
# and policy/hosted.rego, reading one object at a time, says nothing of an object that is not there. The same goes for the Probes its alerts
# read, each of which would leave an alert reading nothing. The route is found by the host it serves, in any namespace, so one renamed still
# needs them. Traefik matches a host in any case, and a HostRegexp would escape its dots, so this reads the rule as policy/plane.rego does.
routes_serving_infisical contains doc if {
	some doc in documents
	doc.kind == "IngressRoute"
	some route in object.get(doc, ["spec", "routes"], [])
	contains(replace(lower(route.match), `\`, ""), lower(infisical_host))
}

infisical_object(doc, kind, name) if {
	doc.kind == kind
	doc.metadata.name == name
	object.get(doc.metadata, "namespace", "") == "infisical"
}

infisical_needs := {
	{"kind": "Middleware", "name": "infisical-guess-limit", "why": "the route's sign-in part names it, and without it Traefik answers every sign-in 404"},
	{"kind": "Middleware", "name": "infisical-session-limit", "why": "the route's session part names it, and without it Traefik answers select-organization and token refresh 404"},
	{"kind": "Probe", "name": "infisical", "why": "InfisicalRouteDown reads it for the sign-in page"},
	{"kind": "Probe", "name": "infisical-claimed", "why": "InfisicalOpenToClaim reads it, and nothing else says the secret store is open to sign-up"},
	{"kind": "Probe", "name": "infisical-sign-in", "why": "InfisicalRouteDown reads it for the part under the limit of guesses"},
	{"kind": "Probe", "name": "infisical-session", "why": "InfisicalRouteDown reads it for the part under the session limit"},
}

deny contains msg if {
	some route in routes_serving_infisical
	some need in infisical_needs
	not infisical_present(need)
	msg := sprintf("IngressRoute %s/%s serves %s, and %s infisical/%s is not: %s", [object.get(route, ["metadata", "namespace"], "-"), object.get(route, ["metadata", "name"], "with no name"), infisical_host, need.kind, need.name, need.why])
}

infisical_present(need) if {
	some doc in documents
	infisical_object(doc, need.kind, need.name)
}
