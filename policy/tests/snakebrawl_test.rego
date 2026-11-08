package hosted_test

import data.hosted
import rego.v1

snakebrawl_edge(match, backend, port) := {
	"kind": "IngressRoute",
	"metadata": {"name": "snakebrawl", "namespace": "snakebrawl"},
	"spec": {"entryPoints": ["websecure"], "tls": {"secretName": "snakebrawl-tls"}, "routes": [
		{"kind": "Rule", "match": match, "services": [{"name": backend, "port": port}]},
	]},
}

test_snakebrawl_apex_web_allowed if {
	count(hosted.deny) == 0 with input as snakebrawl_edge("Host(`snakebrawl.io`)", "snakebrawl-web", 3100)
}

test_snakebrawl_arena_requires_the_protocol_allowlist if {
	some message in hosted.deny with input as snakebrawl_edge("Host(`ws.snakebrawl.io`)", "snakebrawl-arena", 2567)
	contains(message, "public Colyseus protocol")
}

test_snakebrawl_cannot_route_private_metrics if {
	count(hosted.deny) > 0 with input as snakebrawl_edge("Host(`ws.snakebrawl.io`) && Path(`/metrics`)", "snakebrawl-arena", 9464)
}

test_snakebrawl_cannot_redirect_to_another_host if {
	count(hosted.deny) > 0 with input as {"kind":"Middleware","metadata":{"name":"canonical","namespace":"snakebrawl"},"spec":{"redirectRegex":{"regex":".*","replacement":"https://elsewhere.invalid","permanent":true}}}
}

test_node_import_cannot_fall_back_to_a_registry if {
	count(hosted.deny) > 0 with input as {"kind":"Deployment","metadata":{"name":"snakebrawl-arena","namespace":"snakebrawl"},"spec":{"template":{"spec":{"containers":[{"name":"arena","image":"docker.io/library/snake-production-arena@sha256:e86220faca6c3ee4b16e66508a6750589ec0dd9673a8574b2958e33fc98790c6","imagePullPolicy":"IfNotPresent"}]}}}}
}
