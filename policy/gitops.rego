# Everything under gitops/. Run with --namespace gitops.
package gitops

import data.lib.kube
import rego.v1

# Values come from Infisical through the operator. A Secret in Git is either a leak or a
# chart default password that an existingSecret key failed to suppress.
deny contains msg if {
	input.kind == "Secret"
	msg := sprintf("%s: kind Secret must never be committed under gitops/", [kube.label(input)])
}

deny contains kube.wrapper_denied(input) if kube.wraps_other_objects(input)

# Contract section 7: a Plane environment syncs under its own project, which cannot create a
# NetworkPolicy or leave its namespace. Under project platform or default it could do both.
plane_projects := {
	"plane-dev": "gitops/environments/dev",
	"plane-prod-sim": "gitops/environments/prod-sim",
	"plane-prod": "gitops/environments/prod",
}

# Project default allows everything. An Application with no project is the same mistake.
deny contains msg if {
	input.kind == "Application"
	project := object.get(input, ["spec", "project"], "")
	project in {"", "default"}
	msg := sprintf("%s: project %q is not allowed, use platform or the environment's own project", [kube.label(input), project])
}

deny contains msg if {
	input.kind == "Application"
	plane_projects[input.metadata.name]
	object.get(input, ["spec", "project"], "") != input.metadata.name
	msg := sprintf("%s: a Plane Application must use its own project, %q, not %q", [kube.label(input), input.metadata.name, object.get(input, ["spec", "project"], "")])
}

# Whatever an Application is called, the rendered manifests of an environment sync only under that
# environment's project, so a new name cannot carry them into project platform.
deny contains msg if {
	input.kind == "Application"
	some source in kube.app_sources(input)
	path := trim_suffix(trim_prefix(source.path, "./"), "/")
	startswith(path, "gitops/environments")
	project := object.get(input, ["spec", "project"], "")
	object.get(plane_projects, project, "") != path
	msg := sprintf("%s: project %q may not sync %q", [kube.label(input), project, source.path])
}

# The project refuses any other destination at sync. This says so before the merge.
deny contains msg if {
	input.kind == "Application"
	plane_projects[input.spec.project]
	object.get(input, ["spec", "destination", "namespace"], "") != input.spec.project
	msg := sprintf("%s: project %q deploys only to namespace %q", [kube.label(input), input.spec.project, input.spec.project])
}
