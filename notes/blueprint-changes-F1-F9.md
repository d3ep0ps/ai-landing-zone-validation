# Blueprint changes from findings F1 and F9 (draft)

Target: `../gcp-ai-cloudfoundation/GCP_Cloud_Foundation_AI_Landing_Zone_Architecture_and_Governance_Blueprint.md`, v2.2.0 (2026-10-15) → proposed v2.3.0.
Status: **applied** to the blueprint on 2026-10-27 at the owner's request (v2.3.0; backup of v2.2.0 as `...Blueprint.md.v2.2.0.bak`). Applied: C-F1-1, C-F1-2, C-F1-3 (as §8 Test 3b; the old role-based fleet check kept as Test 3b-2), C-F1-4 (as a CI check after the §8 script), C-F1-5, C-F1-6 (§9 R2 extended instead of a new row, so the "18-Point" count stays; §11.1 monthly row), C-F9-1, C-F9-2 (as "option to evaluate"), C-F9-3, C-F9-4. Not applied: "Related changes to consider" (not requested).
Run-6 update (2026-10-28): evidence lines below now include run 6 (one run of the v2 tests T37, T39, T39b). Run 6 contradicts the C-F9-2 text already in v2.3.0 (the egress rule needed Cloud Storage methods, not Service Usage); the correction is proposed as C-F9-2a for v2.3.1, not applied.

Each change says what evidence supports it. "Tested" means a test in this repo produced the result (IDs from [claims-register.md](../claims-register.md)). "Not tested" means design intent: a v2 candidate test is named (Appendix E of `EXECUTION-PLAN.md`).

---

## F1: the platform grants every agent inference access

### What we found

- Google grants `roles/aiplatform.agentDefaultAccess` to the project's agent principalSet (`principalSet://agents.global.org-ORG_ID.system.id.goog/attribute.platformContainer/aiplatform/projects/PROJECT_NUMBER`), even when no Terraform grants it. The role includes `aiplatform.endpoints.predict` (T12 FAIL in runs 1, 2 and 6; Policy Analyzer confirmed the path, and in run 6 the analyzer query itself returned it) (F1).
- The binding appears when the first agent is deployed (T19 run 4) and stays after all agents are deleted (T19 runs 5 and 6) (C13, F14).
- An IAM deny policy on the project, denying `aiplatform.googleapis.com/endpoints.predict` to that principalSet with the approved agent as an exception, refused the non-approved agent and let the approved agent's identical call through. This was tested in three runs, with the perimeter in dry-run (run 4) and enforced (runs 5 and 6) (C12). The refusal names the deny policy (F10).
- One deny policy at the test folder, on the organization-wide agent principalSet (`principalSet://agents.global.org-ORG_ID.system.id.goog/*`), with the approved agent as the exception, refused a second agent's model call with `PERMISSION_DENIED` and let the approved agent answer; the project deny policy was removed first (T37, run 6, one run) (C25).
- Creating the deny policy needed `roles/iam.denyAdmin`; Security Admin does not include it (F10). We waited 10 minutes after creation before testing.

### Why the blueprint needs to change

- §8 Test 3b looks for fleet grants with the roles `aiplatform.user`, `aiplatform.admin`, `editor` and `owner` only. It **passes** in a project where F1 applies, because the platform's role is `aiplatform.agentDefaultAccess`.
- §8 Test 3c and the note "inference permissions belong to the gateway identity only" assume that agents hold no inference permission unless someone grants it. F1 shows that this is false by default.
- §6.1 and Phase 4 do not mention the platform grant or a deny policy.

### Proposed changes

**C-F1-1. New subsection §6.1.1 "Platform default inference grant and the deny-policy guardrail"** (after "Technical Specification"):

> Agent Runtime grants `roles/aiplatform.agentDefaultAccess` to every agent in a project, through the project's agent principalSet, when the first agent is deployed. The role includes `aiplatform.endpoints.predict`, so every agent can call models directly, whatever the landing zone grants. The binding is not removed when the agents are deleted.
>
> The landing zone does not remove this binding (Google manages it). Instead, every agent runtime project gets an IAM deny policy:
>
> - denied principal: the project agent principalSet;
> - denied permission: `aiplatform.googleapis.com/endpoints.predict`;
> - exception principals: the `principal://` identity of each agent approved to call models directly. In the Agent Gateway pattern (§6.3), the list is empty, and inference runs only under the gateway identity, which is not in the agent principalSet.
>
> The deny policy is part of the project factory for `prj-agent-runtime-*`, created before the first agent is deployed. Creating it needs `roles/iam.denyAdmin`, which Security Admin does not include; grant it to the platform pipeline identity only.

Evidence: tested for the explicit-exception form (C12, F10). The empty-exception, gateway-only form is **not tested**: T31 (run 6) was INCONCLUSIVE, because an agent behind the Agent Gateway got 401 UNAUTHENTICATED from Vertex AI after the gateway allowed the call (F16). The folder-level form with the organization-wide principalSet passed once (T37, C25).

**C-F1-2. Deploy procedure for an approved agent (§6.1.1 continued):**

> An agent's `principal://` identity exists only after deployment. Deploy the agent, add its identity to `exceptionPrincipals`, and wait for the deny policy change to take effect (allow 10 minutes) before the agent goes live. Until then the agent's model calls are refused with "denied ... due to an IAM deny policy".

Evidence: deploy-then-add order and the 10-minute wait were used in all three runs (T18), and in T37 (policy age 623 s at the check). Propagation time was not measured; 10 minutes is what we waited.

**C-F1-3. Replace §8 Test 3b** so that it checks the platform role and the deny policy:

```bash
echo "=== Test 3b: Fleet inference grant and deny-policy guardrail ==="
FLEET="principalSet://agents.global.org-${ORG_ID}.system.id.goog/attribute.platformContainer/aiplatform/projects/${PROJECT_NUMBER}"
# 3b-i: is the platform default grant present? (expected: yes once any agent was deployed)
gcloud projects get-iam-policy "$PROJECT" --flatten='bindings[].members' \
  --filter="bindings.members=\"$FLEET\"" --format='value(bindings.role)'
# 3b-ii: a deny policy must deny endpoints.predict to that principalSet
# `policies list` returns {"policies": [...]} with metadata only; read the rules with `policies get`.
AP="cloudresourcemanager.googleapis.com/projects/${PROJECT}"
DENY=0
for P in $(gcloud iam policies list --attachment-point="$AP" --kind=denypolicies --format=json \
            | jq -r '.policies[]?.name | split("/")[-1]'); do
  N=$(gcloud iam policies get "$P" --attachment-point="$AP" --kind=denypolicies --format=json \
      | jq --arg f "$FLEET" '[.rules[]?.denyRule
          | select((.deniedPrincipals // []) | index($f))
          | select((.deniedPermissions // []) | index("aiplatform.googleapis.com/endpoints.predict"))] | length')
  DENY=$((DENY + N))
done
if [[ "$DENY" -eq 0 ]]; then
  echo "FAIL: no deny policy blocks endpoints.predict for the agent fleet (platform grant F1 applies)"; exit 1
fi
echo "PASS: fleet inference denied by deny policy; review exceptionPrincipals against the approved-agent list."
```

Evidence: the deny-policy fields, the principalSet format and the list-then-get read come from T18 and T19 (`tests/T18.sh`, gcloud 590.0.1). The script above was **not run** as written; check it before adoption.

**C-F1-4. §8 Test 3c, add a behavioural check** next to the IAM check. A non-approved test agent calls a model and must be refused with `PERMISSION_DENIED` ("due to an IAM deny policy"); an approved agent's identical call must succeed. This is T18 as a standing test.

**C-F1-5. Phase 4 task and Gate 4:**
- Task: "Create the agent-inference deny policy in every agent runtime project (§6.1.1) before the first agent deployment."
- Gate 4 adds: "In every agent runtime project, a non-approved test agent's model call is refused by the deny policy; `exceptionPrincipals` matches the approved-agent register."

**C-F1-6. §9 assessment matrix and §11.1 cadence:** add a monthly check that compares `exceptionPrincipals` with the approved-agent register, and that the deny policy still exists in every runtime project.

### Open points (not tested)

- **Gateway-only form:** see C-F1-1 evidence; not shown (F16). Research into the 401: `notes/doc-verification-v2-B-401.md`.
- **Other permissions:** we denied one permission, `endpoints.predict`. The full permission list of `roles/aiplatform.agentDefaultAccess` was not reviewed for other model-access paths (for example, batch prediction or streaming methods with other permissions). v2 doc check E2.1.
- **Org-level form:** answered in part by T37 (run 6, one run): a folder deny policy accepts the organization-wide agent principalSet (`.../*`) and refused a non-approved agent (C25). Organization-level attachment was not tested; a second run is planned (run 7). Proposed wording: C-F1-1a below.

**C-F1-1a (proposed for v2.3.1, not applied). §6.1.1, add:** "Alternatively, attach one deny policy at the folder that holds the agent runtime projects, denying `aiplatform.googleapis.com/endpoints.predict` to the organization-wide agent principalSet `principalSet://agents.global.org-ORG_ID.system.id.goog/*`, with the approved agents as exceptions." Evidence: T37, one run (C25). Keep the per-project form as the standard until run 7 repeats it.

---

## F9: one quota project cannot serve a Terraform stack across the perimeter

### What we found

- With the perimeter enforced, and the quota project **outside** it (the seed project), Terraform and gcloud calls to resources inside were refused as egress (F5, v1).
- With the quota project **inside** the perimeter (the data project; DC2 step 1), calls to in-perimeter resources worked, but the lookup of the project outside the perimeter (its Cloud Storage service account) was refused: 403 "Request is prohibited by organization's policy", `vpcServiceControlsUniqueIdentifier` (F9). The same single plan error occurred in both runs (T22 INCONCLUSIVE in run 4, FAIL in run 5 after script fixes).
- Operational result, not a test: while the perimeter was enforced, plans **targeted** at in-perimeter resources (`-target=module.vpc_sc`, the deny policy, the SWP blocks) with the in-perimeter quota project worked in both runs (run logs). Full plans failed.

### Why the blueprint needs to change

- Phase 3 says "create perimeters in dry-run, monitor, enforce sequentially". It does not say how IaC keeps working after enforcement. A single Terraform root that manages projects on both sides of `perim-ai-prod` will fail its plans once the perimeter is enforced, whichever quota project it uses.
- §5.1 lists the perimeter members but not the pipeline and quota-project design.

### Proposed changes

**C-F9-1. New subsection §5.1.1 "IaC and quota projects at the perimeter boundary":**

> Terraform and gcloud send a quota (billing) project with each API call. VPC Service Controls evaluates that project like any other: a quota project outside a perimeter makes calls into it look like egress, and a quota project inside makes calls to projects outside look like egress. A Terraform root that reads or manages projects on both sides of an enforced perimeter therefore fails, whichever single quota project it uses.
>
> Split the IaC along the perimeter boundary:
>
> 1. **Inside stack:** manages only resources in perimeter member projects. It uses a quota project inside the same perimeter (for example a per-environment tooling project in `perim-ai-prod`), with the APIs Terraform calls enabled there.
> 2. **Outside stack:** manages the hierarchy, project factory, perimeter definitions (Access Context Manager), org policies and anything in non-member projects. It uses a quota project outside the perimeter.
> 3. Values cross between stacks as outputs (project numbers, identities), not as data-source lookups across the boundary.
>
> If a single stack cannot be split yet, a time-boxed fallback is a plan targeted at in-perimeter resources with the in-perimeter quota project (`-target=...`, `-var quota_project=...`, `GOOGLE_BILLING_PROJECT`, `USER_PROJECT_OVERRIDE=true`). Treat it as an exception: targeted plans hide drift elsewhere.

Evidence: the failure modes are tested (F5, F9). The targeted-plan fallback worked in operation (run-4 and run-5 logs). The split-stack design was tested once (T39, run 6): with the perimeter enforced, the inside and outside stacks both planned in full (exit 2), and no VPC-SC violation named either quota project (C26).

**C-F9-2. Alternative to the split (§5.1.1, short):** an egress rule that lets the pipeline identity use its outside quota project (`serviceusage.googleapis.com`) from inside the perimeter. This was DC2 option (b). Name it as an option to evaluate, not as the standard.

**C-F9-2a (correction, proposed for v2.3.1, not applied).** Run 6 tested this option once (T39b PASS): the full plan of a single stack with an outside quota project succeeded with an egress rule for the pipeline identity, and the same call by another identity was refused. The rule that worked was **not** `serviceusage.googleapis.com`: the dry-run violation named Cloud Storage, and the rule needed `storage.googleapis.com` with the methods `google.storage.buckets.list` and `google.storage.projects.serviceAccounts.getOrCreate` (F19). Replace the service name in C-F9-2, and say: build the egress rule from the stack's own dry-run violations, because the methods depend on which lookups the modules make (Google provider 8.8.0 here).

**C-F9-3. Phase 3 tasks and Gate 3:**
- Task, before enforcement: "Split IaC roots along each perimeter boundary and assign an in-perimeter quota project to each inside stack (§5.1.1). Run a full plan of every stack with the perimeter in dry-run and confirm that there are no violation entries for the stacks' quota projects."
- Gate 3 adds: "After enforcement, a full plan of every IaC stack succeeds; no VPC-SC violation names a quota project."

**C-F9-4. Phase 3 monitoring query:** keep the dry-run query, and add a note that enforced-mode VPC-SC entries have no `dryRun` field, so a filter `dryRun!=true` misses them; filter on the absence of the field or on `severity=ERROR` (F6).

### Open points (not tested)

- Whether the split-stack design covers every cross-boundary lookup the Fabric modules make (the failing lookup was a `google_storage_project_service_account` data source in the Fabric `project` module, for the outside project). T39 covered this repository's stacks in one run; other module sets were not tested.
- T22 (single stack, quota project inside) failed again in run 6, with the same error (F9; three runs).

---

## Related changes to consider at the same time (evidence already in the register)

These are outside F1 and F9. They're listed so they can go into the same blueprint version, if the owner wants:

- §5.2 / Phase 4, deploy order: agents deployed before enforcement keep working only with an ingress rule for their `principal://` identities (C16). Without one, they stop working after enforcement (F2).
- Phase 3, Cloud Build: the default staging bucket is created in `us`; use a pre-created regional CMEK staging bucket, and give the build service account `roles/storage.admin` on it (F4, C15, F11).
- §3 / Phase 1: the Compute Engine default service account held `roles/editor`; add `iam.automaticIamGrantsForDefaultServiceAccounts` to the baseline (F13, observation only).
- §7.1: Binary Authorization admission was tested (C18). With the Google provider, create attestors in a separate apply before the policy (F12).

Added after run 6 (2026-10-28; all one run, v2):

- §6.3 rules 1–2, Model Armor: a folder floor setting (C20) and an organization floor setting (C21) refused weaker project templates. With the Vertex AI floor integration in `INSPECT_AND_BLOCK`, a flagged prompt was blocked, but the message did not start "Blocked by Floor Setting" (F15); do not quote the message in runbooks. Floor settings have no delete call in the API; a Terraform destroy leaves them in GCP, so roll back by setting enforcement off first (F20).
- §6.3 / §8, Agent Gateway: not shown (F16). Setup details for the blueprint's build steps: register exact hostnames, including mTLS and regional variants; the IAP authorization extension needs `metadata.iapPolicyVersion`; the gateway accepts one operation at a time (F17). The default Cloud Build staging bucket for the gateway's agent build is again refused by the location policy (F4).
- §5.2 / §5.3, PSC interface: an agent reached the allowed host only through the Secure Web Proxy and the proxy refused a non-allowed host (C23). The case without the proxy left no firewall log entry (F18); do not claim that the egress firewall stops agents' direct traffic.
- §3 / §3.1, organization policies: the dryRunSpec staging, inheritance and one project exception worked for one custom constraint at organization scope (C24).

## Change-history line (proposed)

| 2.3.1 | 2026-10-XX | Run-6 corrections: C-F9-2 egress rule names Cloud Storage methods, not Service Usage (C-F9-2a); folder-level deny-policy option on the organization-wide agent principalSet (C-F1-1a). |

| 2.3.0 | 2026-10-XX | Validation findings: platform default inference grant to agents and the deny-policy guardrail (§6.1.1, §8 Test 3b/3c, Phase 4); IaC and quota projects at the perimeter boundary (§5.1.1, Phase 3); enforced-mode VPC-SC log filter note. |
