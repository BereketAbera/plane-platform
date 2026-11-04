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
