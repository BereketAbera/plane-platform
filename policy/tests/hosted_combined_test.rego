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

# The blackbox exporter the Probes ask, as kustomize builds monitoring-extras: the generator's ConfigMap under its hashed name, and the
# Deployment's volume renamed to match. The modules are written out here and not read from the policy.
claimed_cel := "body.config.initialized == true && body.config.allowSignUp == false"

blackbox_modules := {
	"http_2xx": {"prober": "http"},
	"http_infisical_login": {"prober": "http", "timeout": "5s", "http": {"preferred_ip_protocol": "ip4", "fail_if_not_ssl": true, "valid_status_codes": [200], "fail_if_body_not_matches_regexp": [`<title id="initial-document-title">Infisical</title>`]}},
	"http_infisical_claimed": {"prober": "http", "timeout": "5s", "http": {"preferred_ip_protocol": "ip4", "fail_if_not_ssl": true, "valid_status_codes": [200], "fail_if_body_json_not_matches_cel": claimed_cel}},
	"http_infisical_no_bearer_post": {"prober": "http", "timeout": "5s", "http": {"method": "POST", "preferred_ip_protocol": "ip4", "fail_if_not_ssl": true, "valid_status_codes": [401], "fail_if_body_not_matches_regexp": [`"message":\s*"Token missing"`]}},
	"http_infisical_no_refresh_cookie": {"prober": "http", "timeout": "5s", "http": {"method": "POST", "preferred_ip_protocol": "ip4", "fail_if_not_ssl": true, "valid_status_codes": [404], "fail_if_body_not_matches_regexp": [`"error":\s*"AuthTokenNotFound"`]}},
}

loosened_modules := json.patch(blackbox_modules, [{"op": "replace", "path": "/http_infisical_claimed/http/fail_if_body_json_not_matches_cel", "value": "has(body.config)"}])

blackbox_file(modules) := yaml.marshal({"modules": modules})

blackbox_service := {"apiVersion": "v1", "kind": "Service", "metadata": {"name": "blackbox", "namespace": "monitoring"}, "spec": {"selector": {"app.kubernetes.io/name": "blackbox-exporter"}, "ports": [{"name": "http", "port": 9115, "targetPort": "http"}]}}

blackbox_container := {
	"name": "blackbox",
	"image": "quay.io/prometheus/blackbox-exporter:v0.29.1@sha256:ea1c7aa3ef3f307cd03e85f34abb604478ccb90b567fc690da0cd9776da76b13",
	"args": ["--config.file=/config/blackbox.yml"],
	"volumeMounts": [{"name": "config", "mountPath": "/config", "readOnly": true}],
}

blackbox_deployment(name, container, volume) := {
	"apiVersion": "apps/v1",
	"kind": "Deployment",
	"metadata": {"name": name, "namespace": "monitoring"},
	"spec": {"template": {"metadata": {"labels": {"app.kubernetes.io/name": "blackbox-exporter"}}, "spec": {"containers": [container], "volumes": [volume]}}},
}

config_volume(configmap) := {"name": "config", "configMap": {"name": configmap}}

the_blackbox := blackbox_deployment("blackbox", blackbox_container, config_volume("blackbox-config-4mt2645788"))

blackbox_config(name, files) := {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": name, "namespace": "monitoring"}, "data": files}

the_blackbox_config := blackbox_config("blackbox-config-4mt2645788", {"blackbox.yml": blackbox_file(blackbox_modules)})

blackbox_everything := [blackbox_service, the_blackbox, the_blackbox_config]

infisical_everything := array.concat(
	[
		the_route,
		infisical("Middleware", "infisical-guess-limit"),
		infisical("Middleware", "infisical-session-limit"),
		infisical("Probe", "infisical"),
		infisical("Probe", "infisical-claimed"),
		infisical("Probe", "infisical-sign-in"),
		infisical("Probe", "infisical-session"),
	],
	blackbox_everything,
)

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

# Everything Infisical's route needs, with the blackbox exporter's three objects as given.
with_blackbox(objects) := with_target(array.concat([o | some o in infisical_everything; not o in blackbox_everything], objects))

says_once(read, text) if {
	denied := hosted_combined.deny with input as read
	count(denied) == 1
	some msg in denied
	contains(msg, text)
}

loosened := "where blackbox module http_infisical_claimed is"

# The generator renamed, and the Deployment's volume with it, or a second file in the same ConfigMap with the flag pointed at it: either way
# the claim module that pods read is the loosened one, and policy/hosted.rego's rule on blackbox-config sees none of it.
test_a_claim_module_loosened_where_blackbox_reads_it_rejected if {
	says_once(with_blackbox([blackbox_service, blackbox_deployment("blackbox", blackbox_container, config_volume("bb-config-7c8f5b9t4k")), blackbox_config("bb-config-7c8f5b9t4k", {"blackbox.yml": blackbox_file(loosened_modules)})]), loosened)
	second_file := object.union(blackbox_container, {"args": ["--config.file=/config/probes.yml"]})
	says_once(with_blackbox([blackbox_service, blackbox_deployment("blackbox", second_file, config_volume("blackbox-config-4mt2645788")), blackbox_config("blackbox-config-4mt2645788", {"blackbox.yml": blackbox_file(blackbox_modules), "probes.yml": blackbox_file(loosened_modules)})]), loosened)
	says_once(with_blackbox([blackbox_service, the_blackbox, blackbox_config("blackbox-config-4mt2645788", {"blackbox.yml": blackbox_file(json.remove(blackbox_modules, ["http_infisical_no_bearer_post"]))})]), "where blackbox module http_infisical_no_bearer_post is missing")
}

# Each pod the Service selects, so a second Deployment behind it, reading its own file, is read too.
test_a_second_blackbox_behind_the_service_read_too if {
	other := blackbox_deployment("blackbox-two", blackbox_container, config_volume("bb-other"))
	says_once(with_blackbox(array.concat(blackbox_everything, [other, blackbox_config("bb-other", {"blackbox.yml": blackbox_file(loosened_modules)})])), "Deployment monitoring/blackbox-two: container \"blackbox\" reads /config/blackbox.yml from ConfigMap monitoring/bb-other, where blackbox module http_infisical_claimed is")
	elsewhere := json.patch(other, [{"op": "replace", "path": "/spec/template/metadata/labels", "value": {"app.kubernetes.io/name": "other"}}])
	count(hosted_combined.deny) == 0 with input as with_blackbox(array.concat(blackbox_everything, [elsewhere]))
}

# Items may map the key to another file name, and that is still the file read.
test_blackbox_config_through_items_accepted if {
	renamed_file := object.union(blackbox_container, {"args": ["--config.file=/config/modules.yml"]})
	volume := {"name": "config", "configMap": {"name": "blackbox-config-4mt2645788", "items": [{"key": "blackbox.yml", "path": "modules.yml"}]}}
	count(hosted_combined.deny) == 0 with input as with_blackbox([blackbox_service, blackbox_deployment("blackbox", renamed_file, volume), the_blackbox_config])
}

# A file nothing here can name: another entrypoint, the flag twice or in two arguments, a file the mount does not hold, or another image.
test_a_blackbox_whose_file_cannot_be_named_rejected if {
	every container in [
		object.union(blackbox_container, {"command": ["/bin/sh", "-c", "exec /bin/blackbox_exporter --config.file=/tmp/x.yml"]}),
		object.union(blackbox_container, {"args": ["--config.file=/config/blackbox.yml", "--config.file=/config/probes.yml"]}),
		object.union(blackbox_container, {"args": ["--config.file", "/config/blackbox.yml"]}),
		object.union(blackbox_container, {"args": []}),
		object.union(blackbox_container, {"args": ["--config.file=/etc/blackbox_exporter/config.yml"]}),
		object.union(blackbox_container, {"volumeMounts": [{"name": "config", "mountPath": "/config/blackbox.yml", "subPath": "blackbox.yml"}]}),
		object.union(blackbox_container, {"image": "docker.io/library/nginx:1.29@sha256:0000000000000000000000000000000000000000000000000000000000000000"}),
	] {
		says_once(with_blackbox([blackbox_service, blackbox_deployment("blackbox", container, config_volume("blackbox-config-4mt2645788")), the_blackbox_config]), "nothing here can say which file it reads them from")
	}
}

test_a_blackbox_config_that_is_not_here_rejected if {
	says_once(with_blackbox([blackbox_service, the_blackbox]), "which is key blackbox.yml of ConfigMap monitoring/blackbox-config-4mt2645788, and no one ConfigMap here by that name holds that key")
	says_once(with_blackbox([blackbox_service, the_blackbox, blackbox_config("blackbox-config-4mt2645788", {"other.yml": blackbox_file(blackbox_modules)})]), "no one ConfigMap here by that name holds that key")
	says_once(with_blackbox([blackbox_service, the_blackbox, blackbox_config("blackbox-config-4mt2645788", {"blackbox.yml": "modules"})]), "that is no blackbox configuration")
	says_once(with_blackbox([blackbox_service, the_blackbox, blackbox_config("blackbox-config-4mt2645788", {"blackbox.yml": "modules: [unclosed"})]), "that is no blackbox configuration")
}

test_a_blackbox_service_that_reaches_no_pod_here_rejected if {
	says_once(with_blackbox([the_blackbox, the_blackbox_config]), "Service monitoring/blackbox is not here")
	says_once(with_blackbox([json.remove(blackbox_service, ["spec/selector"]), the_blackbox, the_blackbox_config]), "selects no pods by label")
	says_once(with_blackbox([object.union(blackbox_service, {"spec": {"type": "ExternalName", "externalName": "blackbox.example.com"}}), the_blackbox, the_blackbox_config]), "selects no pods by label")
	says_once(with_blackbox([object.union(blackbox_service, {"spec": {"selector": {"app.kubernetes.io/name": "other"}}}), the_blackbox, the_blackbox_config]), "and nothing here runs one")
	says_once(with_blackbox([blackbox_service, json.patch(the_blackbox, [{"op": "replace", "path": "/metadata/namespace", "value": "infisical"}]), the_blackbox_config]), "and nothing here runs one")
}

# With none of Infisical's Probes here, nothing reads those modules.
test_blackbox_without_infisicals_probes_ignored if {
	count(hosted_combined.deny) == 0 with input as with_target([blackbox_service])
	count(hosted_combined.deny) == 0 with input as with_target([blackbox_service, blackbox_deployment("blackbox", blackbox_container, config_volume("bb")), blackbox_config("bb", {"blackbox.yml": blackbox_file(loosened_modules)})])
}
