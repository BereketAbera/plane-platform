# Hosted production read as a whole: the hosted tree and what its charts render, together, which is what Argo CD applies. Run with --combine
# and --namespace hosted_combined. policy/hosted.rego reads one object at a time, so it can say what an object holds and never that it is
# there at all, and its rules on Grafana pass when the object they read is missing. These say it is there.
package hosted_combined

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

# Infisical's route names its two limits, and Traefik refuses a route whose Middleware is missing: sign-in or token refresh would answer 404,
# and policy/hosted.rego, reading one object at a time, says nothing of an object that is not there. The same goes for the Probes its alerts
# read, each of which would leave an alert reading nothing.
infisical_routed if {
	some doc in documents
	infisical_object(doc, "IngressRoute", "infisical")
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
	infisical_routed
	some need in infisical_needs
	not infisical_present(need)
	msg := sprintf("IngressRoute infisical/infisical is here, and %s infisical/%s is not: %s", [need.kind, need.name, need.why])
}

infisical_present(need) if {
	some doc in documents
	infisical_object(doc, need.kind, need.name)
}
