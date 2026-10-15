# Hosted production read as a whole: the hosted tree and what its charts render, together, which is what Argo CD applies. Run with --combine
# and --namespace hosted_combined, with infrastructure/hosted/plane-prod/target.yaml among the files. policy/hosted.rego reads one object at a
# time, so it can say what an object holds and never that it is there at all, and its rules on Grafana pass when the object they read is
# missing. These say it is there.
package hosted_combined

import data.hosted
import data.lib.kube
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

# Each of Infisical's Probes asks the prober policy/hosted.rego names for a module, and what a module means is what the pods behind that
# Service read: the file their --config.file names, in the ConfigMap mounted at its directory. policy/hosted.rego holds a ConfigMap by its
# name, so with kustomize's generator renamed, the flag pointed at a second file, or a second ConfigMap mounted by subPath over the file, a
# claim module loosened to read no body passed, and it would leave all three claim alerts quiet. So this follows that Service to every pod it
# selects, and wants each module those Probes use in the file that pod reads, as policy/hosted.rego writes it, with no other mount at or under
# that file's directory.
prober_host := split(hosted.infisical_prober.url, ":")[0]

blackbox := {"name": split(prober_host, ".")[0], "namespace": split(prober_host, ".")[1]}

infisical_watched if {
	some doc in documents
	doc.kind == "Probe"
	object.get(doc.metadata, "namespace", "") == "infisical"
}

blackbox_services := [doc |
	some doc in documents
	doc.kind == "Service"
	doc.metadata.name == blackbox.name
	object.get(doc.metadata, "namespace", "") == blackbox.namespace
]

deny contains msg if {
	infisical_watched
	count(blackbox_services) == 0
	msg := sprintf("Infisical's Probes ask %s for their modules, and Service %s/%s is not here, so nothing here says what they read", [hosted.infisical_prober.url, blackbox.namespace, blackbox.name])
}

# With no selector, or as an ExternalName, a Service sends its traffic where something other than its pods says, and nothing here reads that.
selects_pods(service) if {
	selector := object.get(service, ["spec", "selector"], {})
	is_object(selector)
	count(selector) > 0
	object.get(service, ["spec", "type"], "ClusterIP") != "ExternalName"
}

deny contains msg if {
	infisical_watched
	some service in blackbox_services
	not selects_pods(service)
	msg := sprintf("Service %s/%s, which Infisical's Probes ask for their modules, selects no pods by label, so nothing here says where they go. Give it a selector", [blackbox.namespace, blackbox.name])
}

pod_labels(doc) := object.get(doc, ["spec", "template", "metadata", "labels"], {}) if kube.template_kinds[doc.kind]

pod_labels(doc) := object.get(doc, ["spec", "jobTemplate", "spec", "template", "metadata", "labels"], {}) if doc.kind == "CronJob"

pod_labels(doc) := object.get(doc, ["metadata", "labels"], {}) if doc.kind == "Pod"

blackbox_pods contains doc if {
	some service in blackbox_services
	selects_pods(service)
	some doc in documents
	kube.is_workload(doc)
	object.get(doc.metadata, "namespace", "") == blackbox.namespace
	labels := pod_labels(doc)
	every key, value in service.spec.selector {
		labels[key] == value
	}
}

deny contains msg if {
	infisical_watched
	some service in blackbox_services
	selects_pods(service)
	count(blackbox_pods) == 0
	msg := sprintf("Service %s/%s selects pods labelled %v, and nothing here runs one, so nothing here says what Infisical's Probes read", [blackbox.namespace, blackbox.name, service.spec.selector])
}

# blackbox_exporter reads its modules from the one file this flag names, so a container must run the exporter's own image and entrypoint, with
# the flag once and in one argument, for anything here to say which file that is.
config_flag := "--config.file="

config_file(c) := substring(flags[0], count(config_flag), -1) if {
	endswith(hosted.image_repository(c.image), "prometheus/blackbox-exporter")
	not c.command
	flags := [arg | some arg in object.get(c, "args", []); contains(arg, "config.file")]
	count(flags) == 1
	startswith(flags[0], config_flag)
}

# The ConfigMap and key that file comes from: a configMap volume mounted at the file's directory, whole or with items that name the file. A
# set, so two that could each be it read as neither. A mount with subPath is never a source here, and the rule on mounts_over_config below
# refuses one at or under that directory, with every other mount there.
config_sources(doc, c) := {source |
	file := config_file(c)
	some mount in object.get(c, "volumeMounts", [])
	not mount.subPath
	not mount.subPathExpr
	directory := trim_suffix(mount.mountPath, "/")
	startswith(file, concat("", [directory, "/"]))
	name := substring(file, count(directory) + 1, -1)
	not contains(name, "/")
	some volume in object.get(kube.pod_spec(doc), "volumes", [])
	volume.name == mount.name
	some key in configmap_keys(volume.configMap, name)
	source := {"file": file, "configmap": volume.configMap.name, "key": key}
}

configmap_keys(configmap, name) := {name} if not configmap.items

configmap_keys(configmap, name) := {item.key | some item in configmap.items; item.path == name} if configmap.items

# A path as the runtime mounts it: empty and "." segments mean nothing, so "/config/", "//config" and "/config/." are all "/config".
path_segments(path) := [segment | some segment in split(path, "/"); segment != ""; segment != "."]

config_directory(c) := array.slice(segments, 0, count(segments) - 1) if {
	segments := path_segments(config_file(c))
	count(segments) > 0
}

# The runtime mounts the deeper path last, so a mount at or under the file's directory, a subPath mount of a second ConfigMap at the file
# itself above all, lays its own file over what the mount config_sources reads, and the exporter reads that one. A path with ".." could land
# anywhere, so it counts as there too.
at_or_under(path, directory) if {
	segments := path_segments(path)
	count(segments) >= count(directory)
	array.slice(segments, 0, count(directory)) == directory
}

at_or_under(path, _) if ".." in split(path, "/")

mounts_over_config(c) := [mount.mountPath |
	directory := config_directory(c)
	some mount in object.get(c, "volumeMounts", [])
	at_or_under(object.get(mount, "mountPath", ""), directory)
]

configmap_text(source) := texts[0] if {
	texts := [text |
		some doc in documents
		doc.kind == "ConfigMap"
		doc.metadata.name == source.configmap
		object.get(doc.metadata, "namespace", "") == blackbox.namespace
		text := object.get(doc, ["data", source.key], null)
		is_string(text)
	]
	count(texts) == 1
}

config_modules(text) := modules if {
	yaml.is_valid(text)
	config := yaml.unmarshal(text)
	is_object(config)
	modules := object.get(config, "modules", {})
	is_object(modules)
}

# Every container of those pods, because the port the Service sends to could be any of theirs.
blackbox_containers contains [doc, c] if {
	infisical_watched
	some doc in blackbox_pods
	some c in object.get(kube.pod_spec(doc), "containers", [])
}

# The one source a container reads, where there is exactly one.
blackbox_reads contains [doc, c, source] if {
	some [doc, c] in blackbox_containers
	sources := config_sources(doc, c)
	count(sources) == 1
	some source in sources
}

deny contains msg if {
	some [doc, c] in blackbox_containers
	count(config_sources(doc, c)) != 1
	msg := sprintf("%s: container %q is behind Service %s/%s, which Infisical's Probes ask for their modules, and nothing here can say which file it reads them from. Run the blackbox exporter's own image and entrypoint with one --config.file=<file>, and mount the ConfigMap that holds it at its directory", [kube.label(doc), object.get(c, "name", ""), blackbox.namespace, blackbox.name])
}

# Only the mount of that directory may be there, so the file it holds is the file read.
deny contains msg if {
	some [doc, c] in blackbox_containers
	paths := mounts_over_config(c)
	count(paths) > 1
	directory := concat("", ["/", concat("/", config_directory(c))])
	msg := sprintf("%s: container %q mounts %v at or under %s, the directory of %s, which it reads Infisical's Probes' modules from. Only the mount that holds that file may be there, because another, a subPath mount of a second ConfigMap among them, lays its own file over it", [kube.label(doc), object.get(c, "name", ""), paths, directory, config_file(c)])
}

deny contains msg if {
	some [doc, c, source] in blackbox_reads
	not configmap_text(source)
	msg := sprintf("%s: container %q reads %s, which is key %s of ConfigMap %s/%s, and no one ConfigMap here by that name holds that key", [kube.label(doc), object.get(c, "name", ""), source.file, source.key, blackbox.namespace, source.configmap])
}

deny contains msg if {
	some [doc, c, source] in blackbox_reads
	text := configmap_text(source)
	not config_modules(text)
	msg := sprintf("%s: container %q reads %s from ConfigMap %s/%s, and that is no blackbox configuration, a map of modules, so nothing here can say what Infisical's Probes read", [kube.label(doc), object.get(c, "name", ""), source.file, blackbox.namespace, source.configmap])
}

deny contains msg if {
	some [doc, c, source] in blackbox_reads
	modules := config_modules(configmap_text(source))
	some name, want in hosted.infisical_blackbox_modules
	object.get(modules, name, "missing") != want
	msg := sprintf("%s: container %q reads %s from ConfigMap %s/%s, where blackbox module %s is %v, and must be exactly %v, because Infisical's alerts read what it reports", [kube.label(doc), object.get(c, "name", ""), source.file, blackbox.namespace, source.configmap, name, object.get(modules, name, "missing"), want])
}
