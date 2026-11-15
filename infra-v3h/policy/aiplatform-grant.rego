package main

import rego.v1

# T42: fail if any planned IAM resource grants a roles/aiplatform.* role to any member.
# Covers google_project_iam_member, _binding, _policy (policy_data is a JSON string of bindings).

is_aiplatform_role(role) if startswith(role, "roles/aiplatform.")

# Resources after the change; deletes have after == null and are skipped.
deny contains msg if {
	some rc in input.resource_changes
	rc.type == "google_project_iam_member"
	rc.change.after != null
	is_aiplatform_role(rc.change.after.role)
	msg := sprintf("%s grants %s", [rc.address, rc.change.after.role])
}

# A binding with members = [] (T40b) removes access, so only non-empty bindings count.
deny contains msg if {
	some rc in input.resource_changes
	rc.type == "google_project_iam_binding"
	rc.change.after != null
	is_aiplatform_role(rc.change.after.role)
	count(rc.change.after.members) > 0
	msg := sprintf("%s grants %s", [rc.address, rc.change.after.role])
}

deny contains msg if {
	some rc in input.resource_changes
	rc.type == "google_project_iam_policy"
	rc.change.after != null
	policy := json.unmarshal(rc.change.after.policy_data)
	some b in policy.bindings
	is_aiplatform_role(b.role)
	msg := sprintf("%s grants %s", [rc.address, b.role])
}
