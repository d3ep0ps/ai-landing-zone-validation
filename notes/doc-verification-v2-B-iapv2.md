# v2 area B: switch Agent Gateway IAP authz to iapPolicyVersion V2 (doc verification)

Accessed 2026-10-28, docs only; no cloud state touched. Marks: VERIFIED (doc states it), INFERRED, NOT FOUND.
Note: the fetch tool paraphrases and caps quotes at about 125 characters, so "verbatim" below means short quotes plus
commands copied as the tool returned them; re-check long YAML on the page before the human runs it.

## Short answer
- Terraform: YES for the policy and the binding in provider 8.8.0 (lock file pins 8.8.0). VERIFIED that the resource doc files exist at tag v8.8.0 (`google_iam_project_access_policy`, `google_iam_projects_policy_binding` with `policy_kind = "ACCESS"` and `target.resource`; `target.resource` was added in 8.6.0 per CHANGELOG line "iam3: added `target.resource` field ..."). The extension metadata change is a one-line edit. UNVERIFIED: whether the provider accepts permission `iap.googleapis.com/resources.egressViaIAP` and condition key `iap.googleapis.com` (the provider doc lists only eventarc and iam as supported keys; the Google page's own Terraform example uses `iap.googleapis.com`).
- Org-policy blocker: `constraints/iam.managed.disableAccessPolicyBindings` is on by default for new organizations and blocks the binding. Must be set not-enforced where the binding is created.
- Roles: `roles/iam.accessPolicyAdmin` (create policy and binding), `roles/resourcemanager.projectIamAdmin` (bind to a project), `roles/iap.admin` or `roles/networksecurity.admin` (gateway/extension side), plus an org-policy admin role to turn the constraint off.

## 1. Resources needed for V2 (VERIFIED unless marked)
Source: https://docs.cloud.google.com/gemini-enterprise-agent-platform/govern/policies/configure-iam-policies-uap and .../manage-iam-policies-uap and .../iam-overview-uap
- Access policy (IAM v3beta): `projects/PROJECT_ID/locations/global/accessPolicies/POLICY_NAME`. REST: `POST https://iam.googleapis.com/v3beta/projects/PROJECT_ID/locations/global/accessPolicies?accessPolicyId=POLICY_NAME`. Scope: project (the project that contains the Agent Gateway; iam-overview-uap: "These policies are bound to the project that contains your Agent Gateway instances."). Org and folder access policies exist in the API (gcloud help: "--folder, --location, --organization") but the agent egress docs only show project scope (INFERRED: use project).
- Binding: `projects/PROJECT_ID/locations/global/policyBindings/BINDING_NAME`. REST: `POST https://iam.googleapis.com/v3beta/projects/PROJECT_ID/locations/global/policyBindings?policyBindingId=BINDING_NAME`. Manage page: "Before a policy takes effect, you must bind it to a target resource." Target: `//cloudresourcemanager.googleapis.com/projects/PROJECT_ID`. The configure page also lists an Agent Gateway target form `//networkservices.googleapis.com/projects/PROJECT_ID/locations/LOCATION/agentGateways/GATEWAY_NAME` (VERIFIED as listed; the Terraform doc says for the project binding resource that target.resource "must be the policy binding's parent (the project)").
- Rule shape: effect ALLOW or DENY; `operation.permissions = ["iap.googleapis.com/resources.egressViaIAP"]` ("The permission must be `iap.googleapis.com/resources.egressViaIAP` for all agent egress policies"). NOT roles/iap.egressor: V2 uses a permission in a rule, not a role. (The manage page text writes the permission as `iap.resources.egressViaIAP`, a doc inconsistency; the configure and overview pages use `iap.googleapis.com/resources.egressViaIAP`.)
- Principal for all agents of a project (VERIFIED, configure page): `principalSet://agents.global.org-ORG_ID.system.id.goog/attribute.platformContainer/aiplatform/projects/PROJECT_NUMBER`. This equals our `local.gw_agent_set`. Single agent: `principal://agents.global.org-ORG_ID.system.id.goog/resources/aiplatform/projects/PROJECT_NUMBER/locations/LOCATION/reasoningEngines/AGENT`. Doc inconsistency: the manage page example shows trust domain `agents.global.proj-PROJECT_NUMBER.system.id.goog`; use the `org-` form our agents use (INFERRED from existing V1 grant that worked for authz ALLOWED in run 6).
- Target of the rule is selected by CEL condition, not by a separate resource (cel-attributes-uap): registry-wide `destination.is_registered == true && destination.agent_registry.location == 'us-central1'` (configure page sample); per resource `destination.agent_registry.mcp_server.name == 'projects/.../locations/.../mcpServers/NAME'`; attributes `destination.agent_registry.resource_type` ('AGENT','ENDPOINT','MCP_SERVER','SKILL'), `.location`, `.project_id`; unregistered by `destination.unregistered.host` / `.path`. So both registry-wide and per-endpoint are possible.
- Default for unregistered destinations: NOT FOUND on the CEL page. Our T31b expectation (unregistered denied) is INFERRED from there being no ALLOW rule (the configure page says deny rules are evaluated first and override allow). Verify at run time.
- Also required: the authz extension with `iapPolicyVersion: "V2"` and the authz policy targeting the gateway (already in our Terraform). Optional `metadata.iamEnforcementMode: "DRY_RUN"` ("Remove it when you're ready to enforce"; configure page: set `iamEnforcementMode` to "ENFORCE"). Without it the default is enforcing (INFERRED; the page says to remove DRY_RUN to enforce).

## 2. Commands (VERIFIED, from configure-iam-policies-uap)
```
gcloud services enable agentregistry.googleapis.com aiplatform.googleapis.com
gcloud services enable iam.googleapis.com networkservices.googleapis.com
gcloud iam access-policies create POLICY_NAME --details-rules=POLICY_FILE --project=PROJECT_ID --location=global
gcloud iam policy-bindings create BINDING_NAME --policy="projects/PROJECT_ID/locations/global/accessPolicies/POLICY_NAME" --target-resource="TARGET_RESOURCE" --project=PROJECT_ID --location=global
```
Policy file (rule object; REST wraps rules in `details.rules`; for gcloud `--details-rules` accepts "shorthand, JSON, or a file path" per gcloud reference, whether the file is a bare list of rules is not shown, UNVERIFIED):
```
{"description":"RULE_DESCRIPTION","effect":"ALLOW","principals":["AGENT_PRINCIPALS"],
 "operation":{"permissions":["iap.googleapis.com/resources.egressViaIAP"]},
 "conditions":{"iap.googleapis.com":{"expression":"CEL_EXPRESSION"}}}
```
Extension and policy (delegate-authorization page, V2): extension YAML has `name`, `service: iap.googleapis.com`, `failOpen: false`, `timeout: 1s`, `metadata.iapPolicyVersion: "V2"`; import with `gcloud service-extensions authz-extensions import ... --source ... --location ...`; policy YAML `target.resources: projects/PROJECT_ID/locations/LOCATION/agentGateways/AGENT_GATEWAY_NAME`, `policyProfile: REQUEST_AUTHZ`, `action: CUSTOM`, `customProvider.authzExtension.resources`; import with `gcloud network-security authz-policies import ... --source ... --location ...`. The page gives no separate V1 steps. Quote: "We strongly recommend using Unified Access Policy (`iapPolicyVersion: \"V2\"`)". We already create these two via Terraform, so only `iapPolicyVersion` changes. Prerequisite quoted: grant `networkservices.agentGateways.use` on the gateway to attach authorization policies.
Other gcloud: `gcloud iam access-policies list|describe|update|delete`, `gcloud iam policy-bindings list|describe|update|delete`. Delete all bindings before deleting a policy ("you must first delete all policy bindings that reference it").
Debug filter: `protoPayload.serviceName="iap.googleapis.com"` plus `protoPayload.metadata.iapPolicyVersion="v2"`.

## 3. Terraform support (provider 8.8.0): YES
- Registry pages did not render for the fetch tool; read the provider source docs on GitHub at tag v8.8.0 instead (raw.githubusercontent.com/hashicorp/terraform-provider-google/v8.8.0/website/docs/r/iam_project_access_policy.html.markdown and iam_projects_policy_binding.html.markdown, both exist). Same resources are expected in google-beta (INFERRED; not checked).
- `google_iam_project_access_policy`: required `location`, `access_policy_id`; optional `project`, `display_name`, `annotations`, `details`. `details.rules` required; rule requires `effect` (DENY/ALLOW), `operation` (with `permissions`), `principals`; optional `conditions` (block with `service` required, `expression` optional), `description`, `excluded_principals`.
- `google_iam_projects_policy_binding`: required `target` (exactly one of `principal_set` or `resource`), `policy`, `location`, `policy_binding_id`; also `policy_kind = "ACCESS"` used in the doc example (required status of policy_kind not confirmed, UNVERIFIED); optional `project`, `display_name`. Policy value format `projects/PROJECT/locations/global/accessPolicies/ID`.
- Provider doc example comment: "Binding access policies can be blocked by the managed org policy constraint iam.managed.disableAccessPolicyBinding" (singular), and sets it with `google_org_policy_policy` ... `enforce = "FALSE"` at project level. Examples use `time_sleep` 60s between policy and binding (a pattern, not a documented delay).
- No Terraform resource for the V2 binding to the gateway as a separate target is documented beyond `target.resource`; the project binding is enough per docs.

## 4. Org policy `iam.managed.disableAccessPolicyBindings`
- delegate-authorization and configure pages: "Turn off enforcement for the Disable binding access policy to resource (`constraints/iam.managed.disableAccessPolicyBindings`) managed organization policy constraint. By default, this boolean constraint is enabled for new organizations and will prevent you from binding an IAM Unified Access Policy to a resource." (VERIFIED, plural spelling.)
- NAME CONFLICT: the provider doc and the org-policy-constraints reference (per the fetch summary, "This boolean constraint, when enforced, prevents binding V3 access policies to resources", listed under automatically enforced) use the singular `iam.managed.disableAccessPolicyBinding`. The raw org-policy-constraints page did not contain either string in my text grep (page is large, rendering differs). Which spelling is real: UNRESOLVED. Before the human changes anything, run read-only `gcloud org-policies list-available-constraints --organization=ORG_ID | grep -i AccessPolicyBinding` (or describe both names).
- Level: any level works by inheritance; the provider example sets it on the project. Smallest scope: the project holding the gateway (module.prj_runtime) or the test folder. Whether our org was created before the default applies is unknown, so run `gcloud org-policies describe <constraint> --effective --project=PROJECT_ID` (read-only) first.
- Role that sets it: NOT FOUND on these pages. INFERRED: `roles/orgpolicy.policyAdmin` (standard Organization Policy Administrator at the org/folder/project). We hold only iam.denyAdmin and modelarmor.floorSettingsAdmin, so a human with orgpolicy.policyAdmin is needed unless already held.

## 5. Operator roles (VERIFIED on configure page)
- Gateway instances: `roles/iap.admin` or `roles/networksecurity.admin`.
- Create and bind UAPs: `roles/iam.accessPolicyAdmin`.
- Bind policy to a project: `roles/resourcemanager.projectIamAdmin`.
- `networkservices.agentGateways.use` on the gateway to attach authz policies (delegate page).
- Viewer: `roles/iam.accessPolicyViewer`. iam.denyAdmin and modelarmor.floorSettingsAdmin do not cover these (INFERRED). Terraform runs as the seed/impersonated SA, which also needs the above.

## 6. Propagation delay: NOT FOUND
None of iam-overview-uap, configure, manage, troubleshoot-iam-policies-uap, delegate-authorization states one. Terraform examples wait 60 s (policy to binding) and 120 s (after org policy change), as a pattern only. Plan: poll with the test itself (DRY_RUN first, check audit log `iapPolicyVersion="v2"`) and treat the first minutes as INCONCLUSIVE, not FAIL.

## 7. V1 grant under V2: NOT FOUND (INFERRED ignored)
No page says the V1 `roles/iap.egressor` grant on the registry is ignored or still honoured under V2. The delegate page calls V1 the "legacy Allow policy" and V2 "separate policies". To keep the test attributable to V2, remove the V1 grant (`google_iap_agent_registry_iam_member.v2_egress`) in the same change, so an ALLOW can only come from the UAP.

## 8. Draft minimal change for infra/v2-gateway.tf (NOT applied; the .tf is untouched)
```hcl
# (a) existing extension: change only this value                                  -- VERIFIED field and value
  metadata = {
    iapPolicyVersion = "V2"
    # iamEnforcementMode = "DRY_RUN"   # optional; VERIFIED name/value on delegate page; omit to enforce (INFERRED)
  }

# (b) remove or count=0 the V1 grant google_iap_agent_registry_iam_member.v2_egress   -- INFERRED (see 7)

# (c) V2 access policy (project scope)
resource "google_iam_project_access_policy" "v2_egress" {                          # VERIFIED resource name
  count            = local.gw_on ? 1 : 0
  project          = local.gw_project                                              # VERIFIED
  location         = "global"                                                      # VERIFIED
  access_policy_id = "lzv-gw-egress"                                               # VERIFIED (argument)
  details {                                                                        # VERIFIED
    rules {
      description = "LZV agents may call registered MCP tools and endpoints"
      effect      = "ALLOW"                                                        # VERIFIED
      principals  = [local.gw_agent_grant]                                         # VERIFIED format (principalSet agents.global.org-...)
      operation {
        permissions = ["iap.googleapis.com/resources.egressViaIAP"]                # VERIFIED text; provider acceptance UNVERIFIED
      }
      conditions {
        service    = "iap.googleapis.com"                                          # VERIFIED in Google example; provider-doc key list omits it -> UNVERIFIED
        expression = "destination.is_registered == true && destination.agent_registry.location == '${var.region}'"  # sample VERIFIED; our region value UNVERIFIED
      }
    }
  }
  depends_on = [google_project_service.v2_gw]   # also needs iam.googleapis.com enabled (VERIFIED as prerequisite; check it is in the list)
}

# (d) binding to the project
resource "google_iam_projects_policy_binding" "v2_egress" {                        # VERIFIED resource name
  count             = local.gw_on ? 1 : 0
  project           = local.gw_project
  location          = "global"
  policy_binding_id = "lzv-gw-egress"
  policy_kind       = "ACCESS"                                                     # VERIFIED in provider example
  policy            = "projects/${local.gw_project}/locations/global/accessPolicies/${google_iam_project_access_policy.v2_egress[0].access_policy_id}"  # VERIFIED format
  target {
    resource = "//cloudresourcemanager.googleapis.com/projects/${local.gw_project}"  # VERIFIED; needs provider >= 8.6.0 (pinned 8.8.0)
  }
}
```
Notes on the draft: (1) add `iam.googleapis.com` to `google_project_service.v2_gw`; (2) the binding fails until the constraint is not enforced for the project; (3) `local.gw_agent_set` already has the right principalSet form; (4) first `terraform plan` will show whether the provider schema accepts the `conditions` and `permissions` values only at apply, so run plan then apply (INFERRED: values are validated server-side).

### Human steps (gcloud, no --quiet; read-only checks first)
1. `gcloud org-policies describe iam.managed.disableAccessPolicyBindings --effective --project=PROJECT_ID` (repeat with the singular name if the first is NOT_FOUND).
2. If enforced: with a role that holds orgpolicy.policyAdmin, set a boolean policy enforce=false on the gateway project or fldr-lz-validation (via `gcloud org-policies set-policy` with a YAML file, or the Terraform `google_org_policy_policy` resource as the provider example does). Org-level v2 changes need per-change approval (memory note).
3. Fallback if Terraform rejects the policy or binding values, create by hand:
   - `gcloud iam access-policies create lzv-gw-egress --details-rules=POLICY_FILE --project=PROJECT_ID --location=global`
   - `gcloud iam policy-bindings create lzv-gw-egress --policy="projects/PROJECT_ID/locations/global/accessPolicies/lzv-gw-egress" --target-resource="//cloudresourcemanager.googleapis.com/projects/PROJECT_ID" --project=PROJECT_ID --location=global`
4. Delete order on teardown: binding first, then policy.

## Open questions
- Constraint name spelling (plural vs singular) and whether it is enforced in our org.
- Provider acceptance of `iap.googleapis.com` condition key and the egressViaIAP permission.
- Propagation delay; default handling of unregistered destinations under V2; whether a lone project binding applies to a gateway in another region (global policy, INFERRED yes).
- Effect on the run-6 401: none expected (see doc-verification-v2-B-401.md section 4).

## Doc URLs (accessed 2026-10-28)
- https://docs.cloud.google.com/gemini-enterprise-agent-platform/govern/gateways/delegate-authorization
- https://docs.cloud.google.com/gemini-enterprise-agent-platform/govern/policies/iam-overview-uap
- https://docs.cloud.google.com/gemini-enterprise-agent-platform/govern/policies/configure-iam-policies-uap
- https://docs.cloud.google.com/gemini-enterprise-agent-platform/govern/policies/manage-iam-policies-uap
- https://docs.cloud.google.com/gemini-enterprise-agent-platform/govern/policies/cel-attributes-uap
- https://docs.cloud.google.com/gemini-enterprise-agent-platform/troubleshooting/troubleshoot-iam-policies-uap
- https://docs.cloud.google.com/sdk/gcloud/reference/beta/iam/access-policies/create
- https://docs.cloud.google.com/resource-manager/docs/organization-policy/org-policy-constraints
- https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/iam_project_access_policy and .../iam_projects_policy_binding (content read from the provider repo at tag v8.8.0 and main, plus CHANGELOG.md)
- Confidence: medium (resources and commands VERIFIED; constraint name, provider value acceptance, propagation, V1 behaviour open)

## Observed 2026-10-28 (read-only, operator)
- `gcloud org-policies describe iam.managed.disableAccessPolicyBindings --effective` -> NOT_FOUND. The singular `iam.managed.disableAccessPolicyBinding` exists; effective policy on the runtime project: `enforce: false`. The constraint name question is resolved: singular. (Needs `--billing-project` = seed; the runtime project has the Org Policy API off.)
