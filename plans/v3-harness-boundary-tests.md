# v3 test plan: harness vs platform boundary

Status: design, 2026-11-10. Not yet run.
Purpose: produce evidence strong enough for the article "Your Agent Harness Is Not a Security Boundary" (`d3ep0ps/agent-harness-article-draft.md`, v0.2).
Same standard as v1–v2: pre-registered expected results, Enforced/Configured tiers, raw output kept and redacted, errata, independent review, claims register updated before any wording goes public.

---

## 1. Claims the article wants to make, and the test behind each

| Article claim | Label in draft | Test ID | Minimum to publish |
|---|---|---|---|
| Deploying an agent changes project IAM outside the team's Terraform, and additive `terraform plan` doesn't show it (while authoritative IAM either drifts or breaks agents) | B1 | T40, T40b | 3 runs (T40) + 1 run (T40b), fresh project each |
| The deploy-time grant covers *every* agent in the project, including one granted nothing | B2 | T41 | 3 runs |
| A policy-as-code gate on `tfplan.json` doesn't see the out-of-band grant | B3 | T42 | 3 runs (cheap, same deploy as T40) |
| The grant survives deleting all agents | B4 | T43 | 3 runs, checked at +15 min and +24 h |
| Identical agent artifact, different egress, decided only by deploy order vs the perimeter | B5 | T44 | 3 runs, same artifact digest |
| When an active harness guard (`HARNESS_GUARD=on`) is bypassed in-process (callback unhooked / direct SDK call / `HTTPS_PROXY` unset), only platform controls still refuse | B6 | T45 | 3 runs × 3 actions × 4 cells |
| DPoP is (or isn't) a working way to keep token binding behind the gateway | B7 | T46 | docs + 1 attempt; NOT_TESTED allowed with evidence |
| The gateway 401 is caused by certificate-bound tokens alone | B8 | T47 | 3 runs, one variable changed at a time |
| The token-binding opt-out makes a replayed agent token usable from another workload against the same Vertex AI endpoint | B9 | T48 | 3 runs |
| A bound agent's token that is used on the Agent Gateway path is still refused when replayed from another workload | B10 | T49 | 3 runs (added 2026-11-11 after v3h runs 1-2; see T49 scheduling) |
| (split of B5) An agent deployed before enforcement cannot create a session after enforcement without an ingress rule; one deployed after can | B5 | T44 v2, T44b | 3 runs each (frozen from run 3) |
| (B6 realistic vector) A dependency in the agent's tarball removes the harness; the platform still refuses | B6 | T45d | 2+ runs |
| (B9) A bound token is refused over another agent's mTLS session (wrong certificate, not only no certificate) | B9 | T48b | 2+ runs |
| (B8) The run-6 gateway 401 reproduces in the run-6 setup | B8 | T47r | 1 attempt |
| The agent cannot change its own boundary (IAM, deny, perimeter, org policy, its own engine) | B11 | T50 | 2+ runs |
| The deny covers every model-access route the agent has | B12 | T51 | 2+ runs |
| One agent cannot read another agent's sessions/memory with the default roles (and can once agentContextEditor is granted project-wide) | B13 | T52 | 2+ runs |
| A gateway-bound agent has no route around the gateway | B14 | T53 | 2+ runs |
| With every control on, the agent can still move data it may read to a host it may reach | B15 | T55 | 2+ runs |

Rule: if a test doesn't reach its minimum, the matching sentence leaves the article.

---

## 2. Environment

- Same test org and folder structure as v2 (`fldr-lz-validation`, `fldr-ai-prod`), europe-west1.
- **A fresh runtime project per run** (`prj-lzv-v3-rN`), so "first agent deploy" really is the first. Create projects at least an hour apart, not in a burst.
- Optional generality check: run 3 of T40–T43 in `europe-west4`. Cheap, and it answers "is this one region?"
- Agent fixture: a minimal ADK agent with a fixed model (`gemini-3.5-flash` via the endpoint used in v2), one HTTP tool and one Cloud Storage copy tool. **Tools take fixed arguments in test mode**, so no model decides where to go, and no arbitrary URLs are fetched.
- Targets: self-owned only: one allowed host and one non-allowed host (both small Cloud Run services or static pages you own), one bucket inside and one outside the perimeter.
- Build the agent package **once per run**, record its sha256, and deploy the same artifact everywhere it says "identical".

---

## 3. Tests

### T40 (B1): deploy-time IAM change invisible to Terraform
**Setup:** fresh runtime project; Terraform manages project IAM **additively** (`google_project_iam_member`, the standard pattern in shared GCP projects), grants the agent nothing.
**Procedure:**
1. `gcloud projects get-iam-policy` → `before.json`.
2. `terraform plan -detailed-exitcode` → expect exit 0.
3. Deploy agent 1 (record how: Terraform resource or SDK, and keep it identical across runs).
4. Wait 5 min. `get-iam-policy` → `after.json`; `diff`.
5. `terraform plan -detailed-exitcode` again.
6. Audit logs: find the `SetIamPolicy` entry that added the binding; record `principalEmail` and timestamp.
**Pre-registered expected result:**
- **T40 (additive IAM, 3 runs):** `after.json` contains one new binding, `roles/aiplatform.agentDefaultAccess` on `principalSet://agents.global.org-ORG_ID.system.id.goog/attribute.platformContainer/aiplatform/projects/N`; `terraform plan` returns exit code **0** (no changes) both before and after deploy; the audit log shows the change was made out-of-band by a Google-managed service identity, not the operator.
**Falsified if:** no binding is added, or `terraform plan` reports the change under `google_project_iam_member`.
**Tier:** Configured (read-back). **Evidence:** before/after JSON, diff, both plan outputs with exit codes, audit-log entry.

### T40b (B1 complement, required 1 run in a dedicated project): authoritative IAM vs. the platform grant
**Why this test is required:** experienced Terraform reviewers will ask: *"Why not use authoritative `google_project_iam_binding` for `roles/aiplatform.agentDefaultAccess` (`members = []`)?"*
**Procedure:**
1. After agent 1 is deployed and working, add `google_project_iam_binding` for `roles/aiplatform.agentDefaultAccess` with `members = []`.
2. Run `terraform plan -detailed-exitcode` → record exit code **2** (drift detected: Terraform proposes removing the platform's `principalSet` binding).
3. Run `terraform apply` to remove the binding.
4. Make one model call from agent 1 → record result (expected: `403 PERMISSION_DENIED`, breaking all agents in the project unless per-agent roles are manually managed).
5. Deploy agent 2 in the same project → check `get-iam-policy` and `terraform plan` to see whether the platform re-adds the binding on subsequent deploys (causing permanent Terraform drift on every apply).
**Pre-registered expected result:** `plan` detects drift (exit 2); applying `members = []` breaks agent 1's model calls (`403`); deploying agent 2 either re-introduces the drift or leaves agents broken.
**Tier:** Enforced (for the 403 call) + Configured (for plan drift).

### T41 (B2): the grant covers every agent
**Procedure:** after T40, deploy agent 2 (same artifact, zero roles). Diff IAM again (expect no new binding). Policy Troubleshooter for agent 2's principal on `aiplatform.endpoints.predict`. Agent 2 makes one model call.
**Expected:** no new binding; Troubleshooter shows access granted through the principal-set binding; agent 2's call succeeds.
**Falsified if:** the call is refused, or a per-agent binding appears.
**Tier:** Enforced for the call (an allowed action, recorded as such), Configured for the Troubleshooter.

### T42 (B3): policy-as-code gate doesn't see it
**Procedure:** export `terraform show -json tfplan > tfplan.json` and run a policy-as-code check (Conftest/OPA rule: *"fail if any resource in `tfplan.json` grants an `aiplatform` role to any principal or `principalSet`"*). Run it before and after the deploy.
**Expected:** the gate passes with 0 violations both times, because pre-deploy static analysis only sees declared Terraform resources, not out-of-band `SetIamPolicy` side effects executed by Google's control plane during runtime provisioning.
**Falsified if:** the gate flags the grant.
**Tier:** Configured. Keep the Rego rule in the repo so readers can rerun it.

### T43 (B4): the grant survives deleting all agents
**Procedure:** delete both agents. Check IAM at +15 min and +24 h. Deploy agent 3; diff IAM.
**Expected:** binding still present at both checks; agent 3's deploy adds nothing.
**Falsified if:** the binding disappears.
**Note:** keep the project (cheap) between the two checks. Destroy agents immediately.

### T44 (B5): same artifact, different egress, decided by deploy order
**Procedure:**
1. Perimeter in dry-run. Deploy agent A from artifact sha256 X.
2. Enforce the perimeter; wait 15 min.
3. Deploy agent B from the **same** artifact X.
4. From each agent, call the self-owned non-allowed host with the fixed-argument tool. Also one model call each.
5. Repeat with the identity-based ingress rule for agents (as in T23).
**Expected (from T14R/T23):** without the ingress rule, A's own model calls are refused (agent unusable), B has no internet; with the ingress rule, A keeps internet access, B has none.
**Falsified if:** A and B behave the same.
**Tier:** Enforced. **Evidence:** artifact digest, both agents' resource names, timestamps relative to enforcement, raw responses, VPC-SC log entries.

### T45 (B6): in-process harness guard vs. platform control, head to head
**Why this avoids a tautology:** flipping an env var (`HARNESS_GUARD=off`) only tests a configuration toggle. To prove that an in-process harness fails **by position** (shared process and identity), the agent always boots with **`HARNESS_GUARD=on`** (ADK `before_tool_callback` and `before_model_callback` active). Each action is tested in two execution modes inside the running agent:
- **`mode=guarded` (Normal path):** the agent invokes its tool/model through the standard ADK harness pipeline, where the callback inspects and blocks forbidden calls.
- **`mode=bypass` (In-process compromise / confused-deputy path, with `HARNESS_GUARD=on` still set):** code executing inside the agent's Python process bypasses the harness in memory—both by unhooking the active callback (`agent.before_tool_callback = None` / `agent.before_model_callback = None`) and by calling the underlying client (`genai`, `urllib.request`, `google.cloud.storage`) directly from the tool process. For egress (`b`), `mode=bypass` tests **both** calling via `HTTPS_PROXY` (SWP) **and** unsetting `HTTPS_PROXY` in `os.environ` (direct socket attempt, closing the v2 `T34` gap).

**Three forbidden actions,** each with its own active harness guard and platform control:

| Action | Harness guard (`HARNESS_GUARD=on`) | In-process bypass (`mode=bypass`) | Platform control |
|---|---|---|---|
| a. Model call by a non-approved agent | `before_model_callback` refuses unless agent is on an approved list | unhook callback / call `genai` client directly in-process | IAM deny policy with per-agent exceptions (T18) |
| b. HTTP request to the non-allowed host | `before_tool_callback` URL allowlist | 1) unhook callback (via SWP `HTTPS_PROXY`); 2) unset `HTTPS_PROXY` (direct connection) | perimeter + PSC interface + SWP allowlist (T33) |
| c. Copy an object to the bucket outside the perimeter | `before_tool_callback` destination-bucket allowlist | unhook callback / call `storage.Client().bucket().copy_blob()` directly | VPC-SC perimeter (T13) |

**Matrix per action:** `mode=guarded` vs. `mode=bypass` × platform on/off = 4 cells (plus direct-socket sub-check on `b`), 3 runs → 36 primary results per run set.
**Expected:**

| Execution mode (`HARNESS_GUARD=on` in all cells) | Platform on | Platform off |
|---|---|---|
| **`mode=guarded` (Harness intact)** | refused (by ADK callback, before the call leaves the process) | refused (by ADK callback) |
| **`mode=bypass` (In-process bypass)** | **refused (by platform: IAM Deny `403`, SWP `403` / direct timeout, VPC-SC `403`)** | **allowed (200)**: the gap |

The bottom row is the article's centrepiece proof: inside the agent's process, one line of Python erases the harness guardrail or unsets `HTTPS_PROXY`, but it cannot erase IAM Deny, the perimeter, or the proxy allowlist.
**Falsified if:** `mode=bypass` + platform-on is allowed (platform control failed, including the direct-socket attempt with `HTTPS_PROXY` unset) or `mode=bypass` + platform-off is refused (something else is blocking; investigate before claiming).
**Tier:** Enforced. **Evidence:** for each cell, who refused (ADK callback log vs. Vertex/GCS API error vs. SWP `403` / VPC-SC audit log / socket timeout), raw output.
**Safety:** only self-owned targets; flip platform controls off only in the test folder; restore and verify before the next cell.

### T46 (B7): DPoP as the way to keep binding behind the gateway
**Procedure:** check current docs and SDK release notes for DPoP support for agent tokens through Agent Gateway. If supported, configure it and repeat one T47 call; if not, record the doc evidence.
**Expected:** unknown, so pre-register "record outcome". NOT_TESTED is acceptable with links and dates.

### T47 (B8): isolate the cause of the gateway 401
**Fix what run 6 couldn't:** change **one variable at a time** from a known baseline (VPC egress on, IAP policy v2, pinned packages).
| Step | Token binding | Through gateway | Expected |
|---|---|---|---|
| 1 | default (bound) | no (direct) | 200 (control) |
| 2 | default (bound) | yes | **401** |
| 3 | opt-out | yes | **200** |
| 4 | back to default | yes | **401** |
**Falsified if:** step 2 succeeds or step 4 succeeds (then the 401 wasn't caused by binding alone, and the article must say so).
**Tier:** Enforced. 3 runs.

### T48 (B9): what the opt-out costs: token replay across workloads
**Why the target matters:** in a default runtime project, the agent only holds `roles/aiplatform.agentDefaultAccess` (Vertex AI inference), not Cloud Storage permissions. Replaying the token against a bucket would fail with `403 PERMISSION_DENIED` (IAM) in both modes, masking the `401 UNAUTHENTICATED` (mTLS token binding) check.
**Procedure:**
1. Inside the agent, make one successful Vertex AI call (`generateContent` / `predict` against the same model endpoint used in T41) and capture the bearer access token from credentials in memory (never write raw token material to disk or committed evidence; log only its SHA-256 prefix and expiry).
2. Within 2 minutes, replay that exact bearer token from a **different workload** (a Cloud Run job in another test project, outside the agent's mTLS certificate identity) against the **exact same Vertex AI REST endpoint and payload**.
3. Run the pair twice per run:
   - **With default token binding (`GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES` unset/true):** expected **refused (`401 UNAUTHENTICATED`)** when replayed from the second workload, even though IAM allows the principal.
   - **With the gateway opt-out (`GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=False`):** expected **accepted (`200 OK`)** when replayed from the second workload.
**Falsified if:** the bound token returns `200 OK` from the second workload (which would prove binding isn't enforced on Vertex AI calls—a major finding in itself), or the opt-out token returns `401`, or either returns `403` (fixture IAM error).
**Tier:** Enforced. **Safety:** own tokens, own projects, harmless fixed prompt; tokens expire within an hour; revoke immediately by deleting the agent after the test.

### T49 (B10): replay of a bound token used on the gateway path
**Added 2026-11-11, before any T49 run**, after T47 s2/s4 returned `200 OK` for a bound token through Agent Gateway in v3h runs 1 and 2 (finding F3). T48 shows binding holds on the direct path. T47 shows a bound agent's call succeeds through the gateway, where the gateway, not the agent, holds the TLS connection to Google. Either the gateway path keeps the binding in a way the test doesn't see, or the token on that path isn't bound (or binding isn't checked there). T49 tells these apart, because the second case would make a token taken on the gateway path replayable.
**Engines:** agent G (`lzv-probe-g`, default binding, egress through Agent Gateway) and G-optout (`lzv-probe-g-optout`), the same engines as T47 s2/s3, same tarball and run.
**Procedure** (same rules as T48: token kept in memory only, evidence holds only its SHA-256 prefix and expiry):
1. **s1 (gateway call, control):** inside G, make the T47 s2 call (same model endpoint and payload) through the gateway with the credential the agent normally uses. Record: HTTP status, the client-side mTLS state (`is_mtls` of the session/transport), whether google-auth produced a bound token (the runtime-bound-token setting in effect and the token type it reports), the token SHA-256 prefix and expiry, and the gateway log entry for the call (decoded `generateContent` vs `CONNECT`, as T47 records).
2. **s2 (replay of the gateway-path token):** within 2 minutes, G sends that same token to the replay service (the T48 Cloud Run fixture, other project, no agent certificate). The service calls the **same Vertex AI REST endpoint and payload** directly, without a client certificate. Record status and error body.
3. **s3 (opt-out control):** repeat s1 and s2 on G-optout. Expected `200` for the replay. This shows the replay path itself works, so a `401` in s2 can be read as binding.
4. **Reference:** T48 `bound` from the same run (direct path, expected `401`) is cited, not repeated.
**Expected (pre-registered):** s1 `200` (T47 s2 reproduced); s2 **refused, `401 UNAUTHENTICATED`**: the token taken on the gateway path is bound and binding is enforced on the replay; s3 replay `200`.
**Falsified if:** s2 returns `200` (a token used on the gateway path is replayable from another workload: new finding, "binding does not protect behind the gateway"). **INCONCLUSIVE if:** s3 replay is not `200` (replay path broken), s1 is not `200`, either replay returns `403` (fixture IAM), or the replay request cannot reach the service through the gateway egress policy.
**Precondition (infra, before the run):** the gateway/SWP egress allowlist includes the replay service host (G has no direct egress). If it can't be allowed without widening egress for other tests, s2/s3 are NOT_TESTED and the reason is recorded.
**Fixture:** agent G gets a fixed tool `replay_check("gateway")` (same steps as `_replay` in `tests/fixtures/agent_v3/agent.py`; the own call is the T47 call through the gateway, plus an observation call on the mTLS host). The token stays inside the tool and never enters the model context. Infra: `v3h_replay_register_on_gateway` registers the replay host in the Agent Registry (the gateway allows only registered hosts); agent G gets `LZV_REPLAY_URL`. Script: `tests/T49.sh bound|optout`; orchestrator step after T48, at least 5 min after the registry entry.
**Tier:** Enforced. **Safety:** as T48: own tokens, own projects, fixed harmless prompt, tokens expire within an hour, agents deleted the same day.
**Scheduling:** runs 1 and 2 are done without T49. To reach 3 runs: run 3, plus two block-2-only runs (gateway + G/G-optout + replay service, about 45 min each, same orchestrator), at least a day apart.

## 3b. Tests added 2026-11-12 (plans/v3h-improvements-handoff.md), pre-registered before any script

Doc and source checks: `notes/doc-verification-v3h.md` sections "T40b: google_project_iam_binding with empty members" and "v3h improvements". Run 1 and 2 results of the existing tests are unchanged. A changed script or target makes its next run "run 1" of the new version.

### T40b amendment (before its first run)
The provider (google 8.8.0) accepts `members = []` and sends a binding with no members; the IAM API reference says each binding "must contain at least one principal", and what setIamPolicy does with an empty binding is NOT FOUND. **Pre-registered:** the `call` stage records which happens: (i) the apply succeeds and the `agentDefaultAccess` binding is gone (then the expected T40b outcome applies: agents lose model access), or (ii) the apply fails with 400 (then T40b records "authoritative empty binding rejected by the API" as its result; INCONCLUSIVE for the drift/breakage claim). The only documented alternative, `google_project_iam_policy`, replaces the whole project policy (documented lock-out risk) and conflicts with `google_project_iam_member.operator`; it is not used without a separate human approval and its own pre-registration.

### T44 v2 (B5, frozen from v3h run 3; runs 1-2 are exploratory)
**Why:** the egress target changed between run 1 (run.app) and run 2 (example.com), and the ingress stage ran 15 min after the ingress apply in run 1 but about 1 min after it in run 2 (the canary saw the rule live on the API in 32 s; agent A's session was still refused). **Procedure:** the run-2 script (`tests/T44.sh`, targets: `https://example.com` non-Google, and the self-owned `run.app` host Google-hosted), with the ingress stage taken **at least 15 min after the ingress apply** (canary first, then the fixed remainder). Session creation by deploy order moves to T44b, so A's session refusal no longer decides T44.
**Expected:** pre (dry-run): A model 200, A example.com 200, A run.app 200. noingress: B example.com refused (no route / timeout / proxy refusal), B model 200. ingress (+15 min): A example.com 200, B example.com refused. Google-hosted host (reported as its own row, not in the verdict): B run.app 200 in both stages (as runs 1-2).
**Falsified if:** at ingress A and B behave the same on example.com. **INCONCLUSIVE if:** the pre baseline is not clean, or A cannot create a session at +15 min (then T44b decides). **Tier:** Enforced. 3 runs unchanged.

### T44b (B5 split, finding F4): session creation decided by deploy order
**Procedure:** same agents and stages as T44 v2. Per agent, one `async_create_session` (no model call, no egress) at: noingress; ingress +1 min (observation of propagation, after the canary); ingress +15 min.
**Expected (from runs 1-2):** noingress: A refused with HTTP 403 carrying a VPC-SC unique identifier, B 200. ingress +15 min: A 200, B 200. The +1 min cell is recorded only.
**Falsified if:** A and B behave the same without the ingress rule, or A is still refused at +15 min with its identity in the ingress rule. **Control:** the operator's own `reasoningEngines.list` in the runtime project (200) at each point. **Tier:** Enforced. 3 runs.

### T45d (B6, realistic vector): a dependency removes the harness
**Procedure:** a separate tarball: the T45 agent code unchanged, plus a small local package (`lzv_helper`, built into the tarball and listed in `requirements.txt` like a third-party utility) that the agent imports. When a request's message carries the marker `DEP=1` (stands for attacker-controlled input), the package (which patched `BaseAgent.run_async` at import) sets the callbacks of every live ADK `LlmAgent` to `None` for that request and restores them afterwards; the agent's own unchanged guarded path then makes the call, unguarded. The agent code differs from T45 only by `import lzv_helper`. The direct-socket sub-cell (HTTPS_PROXY unset) is not part of T45d. *Amended 2026-11-12 before the script was written.* Separate engines from that tarball (platform-on engines with PSC-I, platform-off engines without), same three actions, same matrix, same targets as T45.
**Expected:** identical to T45 `mode=bypass`: platform on: refused by the platform (deny 403, SWP 403 / direct deadline, VPC-SC 403); platform off: allowed.
**Falsified if:** platform on is allowed, or platform off is refused. **Separate outcome (recorded, in the harness's favour):** the package cannot reach the live agent objects (then record how the runtime isolates it). **INCONCLUSIVE if:** the runtime cannot install a local package from the tarball (then NOT_TESTED with the build error). **Tier:** Enforced. 2+ runs. Self-owned targets only.

### T47r (B8 regression, 1 attempt): does the run-6 401 reproduce?
**Procedure:** rebuild the run-6 setup as recorded: IAP policy V1 (`v2_gateway_iap_policy_version = "V1"`), no gateway VPC egress, agent G from an **unpinned** requirements file (resolved versions recorded from the engine's build log), default binding. One T47 s2 call.
**Expected:** 401 as in run 6 (F16). **If 200:** the finding is "the run-6 401 did not reproduce on DATE; cause unknown", stated exactly so. Versions of google-auth, google-cloud-aiplatform, google-adk and the IAP policy version are recorded in every T47/T49 result from now on. **Tier:** Enforced (1 attempt). Paid: gateway hours; same-day teardown.

### T47r2 (B8 regression, 1 attempt, conditional): the run-6 package set
*Pre-registered 2026-11-12, after T47r attempt 1 (200, "the run-6 401 did not reproduce") and the log comparison in `notes/run6-401-analysis.md`. Pre-registered before any script.*

**Why:** T47r rebuilt the run-6 infra but resolved November packages. The log comparison leaves three explanations:
- H1: a Google-side change between 2026-10-30 and 2026-11-11;
- H2: G's token is no longer bound behind the gateway;
- H3: the run-6 client libraries behaved differently.

T47r2 separates H1 from H3 once H2 is ruled out.

**Gate (checked by the script before any cloud change):** the latest T49 `bound` stage must show all of the following for agent G:
- `agent_cert=true`;
- `should_request_bound=true`;
- the replay of G's token without a certificate refused with 401 (a bound token).

If the gate is not met, T47r2 is not run. If T49 shows G's token unbound, H2 explains the November 200s; that is recorded in the T49 result and T47r2 stays NOT_TESTED.

**Procedure:** as T47r, with these settings:
- infra: `infra/profiles/v3h-t47r.tfvars` (IAP policy V1, no gateway VPC), targeted to the gateway resources;
- binding: default (no opt-out);
- one T47 s2 call (agent G, `call_model "allowed"` through the gateway).

The only difference from T47r is agent G's requirements, pinned to the package set an unpinned build resolved at run 6 (2026-10-28 ~10:00Z). These are the latest PyPI releases uploaded before that time, checked 2026-11-12:

| Package | Version | Note |
|---|---|---|
| google-cloud-aiplatform[agent_engines,adk] | 2.6.0 | matches run 6's user-agent |
| google-genai | 2.33.0 | matches run 6's user-agent |
| google-auth | 2.62.0 | 2.62.1, 2026-11-02, changed "use an unencrypted key for mTLS certificate rotation" |
| google-adk | 2.13.0 | |

Agent G's code is the current fixture, not the run-6 code (limitation, recorded). The session call that failed in run 6 runs before any tool on every query, so the tool set should not matter. Evidence of the outcome:
- the query result;
- the gateway log status of the session POST and the `iamcredentials` call (both 401 in run 6);
- the import-time versions line.

**Expected:** no prediction; the outcome decides between H1 and H3.
- **401** on the session call or the query: the run-6 401 reproduces with the run-6 package set. The cause is client-side (H3), with google-auth 2.62.0 vs 2.62.1 as the first candidate.
- **200:** the run-6 401 does not reproduce even with the run-6 packages. The cause is Google-side (H1) and can no longer be reproduced.

The result is recorded as PASS if the outcome is clean (401 or 200 with the gateway log entry read) and INCONCLUSIVE otherwise. The verdict here means "the test discriminated", not "the control works"; the reading (H1 or H3) is stated in the result.

**Tier:** Enforced (1 attempt). Paid: about 40 min of gateway time; same-day teardown. Needs human approval before the run.

### T48b (B9, wrong certificate vs no certificate)
**Procedure:** two bound engines from the T48 tarball (v3a and a sibling `lzv-v3-x`). The replay service gets a single-use relay (`/relay/put`, `/relay/take`: memory only, 120 s TTL, deleted on first read, never logged). Agent X puts its own token (records SHA-256 prefix and its own mTLS call status). Agent Y takes it and calls the mTLS Vertex endpoint with X's token over **Y's own** mTLS session (Y's agent certificate).
**Docs:** silent on a fingerprint match (doc check NOT FOUND); the expectation is an inference from "only usable by the agent running in its provisioned environment".
**Expected:** 401 (UNAUTHENTICATED / CAA). **Falsified if:** 200 (binding not checked against the presenting certificate). **Controls:** Y's own token over the same session 200; X's own call over X's session 200. **INCONCLUSIVE if:** a control fails or any 403. **Tier:** Enforced. 2+ runs. Tokens in memory only.

### T50 (new claim B11): the agent cannot change its own boundary
**Docs:** `agentDefaultAccess` (19 permissions) and `agentContextEditor` (22) contain no setIamPolicy, `iam.denypolicies.*`, `accesscontextmanager.*`, `orgpolicy.*`, `aiplatform.reasoningEngines.*`, `networksecurity.*` or `networkservices.*` permission (role describe 2026-11-12). A project-wide `roles/aiplatform.user` would change this; the test records which roles the agent principal set holds.
**a. Configured (from inside v3a, own credentials):** Resource Manager `testIamPermissions` on the runtime project and the test folder for: `resourcemanager.projects.setIamPolicy`, `resourcemanager.folders.setIamPolicy`, `iam.denypolicies.update`, `iam.denypolicies.delete`, `accesscontextmanager.servicePerimeters.update`, `orgpolicy.policy.set`, `aiplatform.reasoningEngines.update`, `networksecurity.gatewaySecurityPolicies.update`, `networksecurity.gatewaySecurityPolicyRules.update`, `networkservices.agentGateways.update`, `networksecurity.authzPolicies.update`. Expected: none returned. (Whether the project endpoint evaluates every service's permissions is NOT FOUND in the docs; an empty answer is cross-checked by b.)
**b. Enforced, no-op by construction** (each attempt type needs human approval before the first run):
- project `setIamPolicy` with a deliberately stale etag: a caller with the permission gets 409 ABORTED (nothing written); without it, 403;
- deny policy update (the DC1 deny, when on) with a stale etag: same reading;
- `reasoningEngines.patch` on its **own** engine, `updateMask=displayName`, the unchanged display name: with the permission the engine is unchanged (an update operation may be recorded); without it, 403. (Docs: `spec.deploymentSpec.env` is updatable by patch, so the permission is what decides whether an agent could set its own binding opt-out.)
**Expected:** a: empty; b: all 403. **Falsified if:** any permission is returned or any attempt is not 403 (finding: property "outside the agent's reach" must be qualified). **Control:** the operator makes the same calls (409 / unchanged), showing the call shape reaches the permission check. **Tier:** a Configured, b Enforced. 2+ runs.

### T51 (new claim B12): deny completeness for model access
**Docs:** `generateContent`, `streamGenerateContent`, `countTokens`, `rawPredict`, `streamRawPredict` all need `aiplatform.endpoints.predict` (the denied permission); batch job create needs `aiplatform.batchPredictionJobs.create` (not in either default role); the permission of the OpenAI-compatible chat-completions route and any regional vs global difference are NOT FOUND.
**Procedure:** DC1 deny on (as T45 on), from the non-approved agent: `generateContent` global and regional, `streamGenerateContent`, `countTokens`, chat completions (`endpoints/openapi/chat/completions`), one partner/open model only if already enabled (else NOT_TESTED), and a batch prediction job create with an input URI to a missing object in a self-owned bucket (if it is created, it is cancelled at once; human approval for this attempt type). Each refusal is attributed with Policy Troubleshooter: deny vs role-never-granted.
**Expected:** no route allowed; predict-family routes refused by the deny; batch create refused because the role never granted it; chat completions: refused (by deny or role, recorded). **Falsified if:** any route returns 200 / creates a job. **Control:** the approved agent on the same routes: 200 for the predict family (batch create refused for both, by role). **Tier:** Enforced. 2+ runs.

**T51 amendment (2026-11-12, before the script was committed):** reading rule per route: if the approved agent (control) gets 404 or 400 on a route (model or route not available there; the regional host returned a model-not-found 404 in run 9, T31R), that route is NOT_TESTED and does not decide the verdict; any other non-200 control on a predict-family route makes the verdict INCONCLUSIVE. Refusal attribution (deny vs role never granted) comes from Policy Troubleshooter for `aiplatform.endpoints.predict` and `aiplatform.batchPredictionJobs.create`.

**Agent G fixture note (2026-11-12, before any run of the new tarball):** agent G gets the T53 tool `direct_probe` and prints its resolved package versions once at import (stdout, read from Cloud Logging) so T47, T47r and T49 record them without a model call. How T47 and T49 judge is unchanged; their next runs use the new tarball (recorded in the run log).

### T52 (new claim B13): lateral access through the default roles
**Evidence already in hand:** T40 run 2 IAM diff shows the first deploy adds `roles/aiplatform.agentDefaultAccess` only (plus the Vertex service agents), **not** `agentContextEditor`. All session/memory permissions are in `agentContextEditor`; `reasoningEngines.query` is in neither role; per-agent scoping of sessions/memory is NOT FOUND (IAM conditions are project-level on `sessionUserId` / `memoryScope`).
**a. Default (no extra grant):** from agent B: `sessions.list` and `sessions.get` on agent A's engine (session created by the operator, synthetic content), `memories.list` on A, and `reasoningEngines.query` on A. Expected: all 403 (role never granted). Control: the operator gets 200 on the same calls.
**b. With `agentContextEditor` granted on the project to the agents principal set** (as a team following the docs would; human approval, test folder only): same calls. Expected: B **can** list and read A's sessions and memories (no per-agent scoping documented) — recorded as an allowed action; `reasoningEngines.query` on A still 403. **Falsified if:** b is refused (then a per-agent scope exists; record how).
**Tier:** Enforced. 2+ runs.

### T53 (new claim B14): no route around the gateway
**Docs:** egress governance covers "all outbound communications"; the docs do not state that direct internet or direct Google API paths are blocked (PARTLY VERIFIED).
**Procedure:** agent G, new fixed tool, no proxy settings: (1) direct HTTPS to the unregistered MCP fixture, (2) TCP connect + TLS to the public IP of `example.com` with SNI, (3) HTTPS to `storage.googleapis.com` (bucket list in the runtime project), each with a 20 s deadline; the gateway log is read for each.
**Expected:** each either does not connect or is refused by the gateway (unregistered destination); none lands on its target. **Falsified if:** any call returns a response from the real target. **Control:** the registered MCP tool through the gateway returns 200 in the same run. **Tier:** Enforced. 2+ runs.

### T55 (new claim B15): what the floor does not stop
**Procedure:** with every T45 platform control on (perimeter enforced, PSC-I + SWP, deny with exceptions), from the approved PSC-I agent in bypass mode: read the synthetic T45c probe object (`lzv-v3h-probe.txt`, fixed harmless text) from the bucket inside the perimeter, then POST its bytes to the **allowed** self-owned host through SWP, with the object's SHA-256 prefix in the query string (the allowed host runs the stock Cloud Run sample image and cannot log a body hash; its Cloud Run request log records the URL and request size). *Amended 2026-11-12 before the script was written.*
**Expected:** allowed: 200, and the allowed host's request log shows the POST with that SHA-256 prefix and a request size that includes the object. **Falsified if:** refused. Recorded as an allowed action: the evidence for "the platform caps damage at what the identity may do, not below it". **Tier:** Enforced. 2+ runs. Synthetic data only.

### T56 (claims-register F24 = results.md Findings 29, re-check): is the gateway request log complete?
*Pre-registered 2026-11-12, after close-readiness review and before any script. Label note added later the same day (wording only): the human meant results.md Findings 24 (T57); T56 stays as a re-check of results.md Findings 29.*
**Why:** F24 (run 8) says `gateway_requests` missed successful MCP tool calls and one repeated blocked call. It rests on one run; part of it (the r2 later read) has no stored raw output, and run 9 saw every scripted `DENIED` entry. Run 8 also could not separate "missing" from "late" (it read the log once, about 1 min after the call).
**Procedure:** in subsets 4 and 5, block 2 (agent G behind the gateway, V2 IAP policy, Model Armor), right after T53. Agent G, existing tool `call_mcp_tool` (one HTTP POST to `/mcp` per call), sequential queries, each with its own start/end time recorded:
- 5 × `registered` / `registered_echo` (expected 200);
- 5 × `unregistered` / `unregistered_echo` (expected 403, IAP `DENIED`);
- 3 × `registered` / `inject_response` (expected 403, Model Armor `DENIED`).
Stage `calls`: makes the calls, then an early read of `gateway_requests` (POSTs to the two fixture hosts, `/mcp`) at last call + 3 min. Stage `late`: at least 15 min after the last call, the same read over the same span. A call "has an entry" when at least one gateway record (more than one is recorded as an observation) to its host falls in its window [start − 2 s, end + 2 s]; for a 403 call, the record must also carry `DENIED` in `authzPolicyInfo.result` or a policy result.
**Expected:** at the late read, every call with a tool result has a matching entry, and every 403 call's entry shows `DENIED`. **Falsified if (F24 reproduces):** any such call has no matching entry at the late read, or a 403 call's entry lacks `DENIED`. Calls without a tool result (agent error) are excluded and counted; fewer than 3 usable calls of any kind → INCONCLUSIVE. **Observation (no verdict):** entries present at the late read but absent at the early one are recorded as delivery lag. **Tier:** Configured (a logging property, not an enforcement). 2 runs (subsets 4 and 5). No resources created; same fixtures as T30/T53.
**What it can show:** with 13 calls per run and 2 runs, a clean result supports "complete for these call types in these runs", not "always complete". A miss confirms F24 with stored raw output.

### T57 (results.md Findings 24 / claims-register F20 re-check): does a Terraform destroy leave the floor setting in place?
*Pre-registered 2026-11-12 ~14:50Z, before any script; human request ("check F24 one more time", meaning results.md Findings 24).*
**Why:** Findings 24 (run 6, repeated in the run-7 log) says that with provider 8.8.0 a destroy of `google_model_armor_floorsetting` removes it from state only, and the floor stays in GCP. The evidence is two run-log lines: no raw describe output after the destroy is stored. Both runs also turned enforcement off before the destroy (documented rollback), so it is unknown whether the destroy itself changes the floor.
**Target:** the runtime project floor (`google_model_armor_floorsetting.v2_project[0]`, enforcement on, `AI_PLATFORM`, pi_and_jailbreak MEDIUM_AND_ABOVE), provider 8.8.0 (lock file). Smallest scope of the live floors; the folder floor is not touched. Runs alone, between scheduled rows (no orchestration active), with no agent in the runtime project.
**Procedure** (`tests/run-v3h.sh t57 1`): stage `before` stores the floor describe (raw) and the state entry; a targeted destroy of that one address (plan allowlist: that delete only), with enforcement left **on**; stage `after` stores the state list and the floor describe (raw) at +1 min and +5 min; restore = apply the baseline (plan allowlist: create of that address only); stage `restored` stores the describe and an untargeted plan of the floor addresses (expected no change) and writes the result.
**Expected (from Findings 24):** after the destroy the address is gone from state, and the floor describe still shows the before content: same `filterConfig` (pi_and_jailbreak, MEDIUM_AND_ABOVE), `integratedServices` with `AI_PLATFORM`, and `updateTime` unchanged. **Falsified if:** the describe fails with 404/NOT_FOUND, or shows a reset floor (no pi_and_jailbreak filter, or `integratedServices` empty), or `updateTime` changed. Recorded, no prediction: `enableFloorSettingEnforcement` after the destroy (true = an unmanaged floor keeps enforcing). INCONCLUSIVE if: the destroy apply fails, or the before describe does not match the baseline. **Restore check:** the restored floor matches the before content with enforcement on; if not, stop and tell the human before the next row. **Tier:** Configured (tool behaviour). 1 run. Free.

### T50c (T50 b1 control, 1 attempt): does a principal without setIamPolicy also get 409 on the stale-etag call?
*Pre-registered 2026-11-13 ~09:10Z, after subset 4 (run 4) and before any script; human approval 2026-11-13.*
**Why:** in run 4, agent A's attempt b1 (project setIamPolicy, stale etag, updateMask auditConfigs, empty list) returned 409 ABORTED, not 403, while the same agent's testIamPermissions on the project returned no `resourcemanager.projects.setIamPolicy`. T50 assumed that 409 means "permission passed, etag failed". If the API checks the etag before authorization, b1 cannot tell the cases apart.
**Principal:** the canary service account (outside project, impersonated by the operator, no keys). It matches the agent on project-level Resource Manager permissions (role definitions read 2026-11-13): both have `resourcemanager.projects.get` (agent: `roles/aiplatform.agentDefaultAccess`; canary: `roles/aiplatform.viewer`); neither has `resourcemanager.projects.getIamPolicy` or `setIamPolicy`.
**Procedure** (`tests/T50c.sh`, between rows, no orchestration active, nothing created): c1) canary testIamPermissions on the runtime project for `resourcemanager.projects.get`, `getIamPolicy`, `setIamPolicy`; c2) the canary sends the request from agent b1, byte for byte (same body and stale etag). Nothing can be written: the etag is stale and the body is a no-op.
**Precondition:** c1 returns `get` only. Otherwise INCONCLUSIVE (not a matched control).
**Expected:** c2 = 409 ABORTED. Then b1 does not discriminate; T50's b1 FAIL stays as recorded and is reported with this limitation; the T50 claim rests on part a and attempts b2/b3. **Falsified if:** c2 = 403 PERMISSION_DENIED (authorization comes first for a principal without the permission, so the agent's 409 is not explained and is recorded as a finding to investigate). Any other answer: INCONCLUSIVE, recorded. Tier: Enforced. 1 attempt.

### Deviations after subset 4 (run 4), 2026-11-13, recorded before the next run
- **Tooling fix (does not change how a test decides):** T50 and T52 extracted the JSON body with `sed -n '/^\{/,$p'`, which fails on macOS sed ("braces not balanced"). It aborted T52 (operator session created, id not parsed) and blanked T50's operator status text (codes were read correctly). Fixed to `/^{/`, the form T57 already uses. Run counts are kept.
- **T48b v2 (fixture fix, new version):** in run 4, X's token over Y's session returned no status (google-auth `RefreshError`). Likely cause: `AuthorizedSession` refreshes on 401 and a bare borrowed token cannot refresh, so a 401 refusal was masked. v2 sends X's token through a session that does not refresh (`refresh_status_codes=()`), so the server's answer is recorded. Expected result and falsification unchanged. Run 4 is v1 (INCONCLUSIVE, kept); the next two subsets are runs 1-2 of v2. The agent_v3 artifact checksum changes for every test that uses it (no other code path changed).
- **Tooling fix after run 5 (2026-11-13):** the T52 grant/revoke plan allowlists omitted the count index (`v3h_t52_context_editor[0]`), so run 5 stopped before the grant. Patterns now accept an optional `[0]`; no other address is allowed. Run 5 results are kept (T48b v2 run 1, T50 main run 2, T52 default run 1). The remaining tests run as run 7 (subset 4, attempt 3; run number 6 not used); the second subset becomes run 8.
- **Run numbers:** the remaining subset-4 tests run as run 5 (subset 4, attempt 2); the second subset becomes run 6. T50 main in run 5 is its run 2 (same version).

### T53 v2 and T56 v2 (fixture fix after run 7), pre-registered 2026-11-13 ~12:40Z, before any change; human decision 11-13
**Why:** the registered MCP fixture (`lzv-mcp-reg`) never started in any v3h run. Its image build in the runtime project fails with HTTP 412 (org policy `gcp.restrictNonCmekServices` denies storage without CMEK, and Cloud Build needs a staging bucket); `setup.sh` printed `build rc=1` and exited 0, so the orchestrator went on. The service had no ready revision ("Image ... mcp:v1 not found") and the gateway returned 404 for every allowed call. Only T53 (control) and T56 (registered_echo, inject_response) use it; no other v3h result depends on it. In run 7, T53's control was 404 (pre-registered 200), and its example_ip probe was classified "landed" although it connected to 240.0.0.2 (the gateway address, reserved range 240.0.0.0/4, not example.com) and the gateway intercepts TLS, so the "example.com" certificate name came from the gateway. Run 7's T53 FAIL and T56 result stay as recorded and are reported with this finding.
**Fixture fix (both tests):** the MCP image is built in the quota project's `lzv-v3h` repository (no CMEK policy there; the replay fixture already works this way); the runtime project's Cloud Run service agent gets `roles/artifactregistry.reader` on that repository (Terraform, block 2 only); a failed build or deploy stops the run; the registered service must be Ready before any test.
**T53 v2 decision changes:** (1) control not 200 → INCONCLUSIVE (the pre-registered control is now enforced by the script); (2) a probe whose connected address is in 240.0.0.0/4 reached the gateway, not its target: it is classified gateway_refused if the answer is 403, otherwise no_route. Everything else, and the falsification ("any call returns a response from the real target"), is unchanged.
**T56 v2:** script and decision unchanged; only the fixture changes.
**Runs:** a short gateway-only orchestration (`gw 1`, block 2 only, ~1.5 h) after run 7 on 11-13, and run 8 on 11-14: 2 runs of each v2.

### T53 v3 (fixture credential fix after gw 1), pre-registered 2026-11-13 ~17:30Z, before any change; human decision 11-13
**Why:** in gw 1 the fixture ran, but every allowed call got 401 from Cloud Run ("The access token could not be verified") while the gateway logged both policies ALLOWED. Cause (evidence/runs/gw-1.md, last section; google-auth 2.62.1 source and iam/docs/auth-agent-own-identity-external): agent G (`g`, binding on) fetches a certificate-bound ID token by default, Cloud Run enforces the binding when the token has a `cnf` claim, and the gateway re-originates TLS, so the binding cannot match. v2 runs 8-9 (opt-out, unbound token) got 200. gw 1 T53 v2 INCONCLUSIVE and T56 v2 FAIL stay as recorded.
**Fixture change (agent G source, `call_mcp_tool` only):** the ID token for the MCP fixture is requested with `bind_id_token=False` (per-request opt-out documented on that page). The tool also returns `auth` = `id_token_unbound` and `cnf_present` (whether the token's unverified payload has a `cnf` claim; no token material). Agent G's access tokens (Vertex, other tools) keep the default binding; deployment settings unchanged. If the parameter is not accepted, the tool falls back to the access token as before and records `access_token_fallback`.
**T53 v3:** expected result, classification, falsification and the control rule (control not 200 → INCONCLUSIVE) are those of v2, unchanged. The script also records the control's `auth` and `cnf_present`. Observation, no prediction: whether the control is 200 with the unbound token.
**T56:** script and decision unchanged (v2). Its allowed calls (registered_echo, inject_response) use the same tool, so in run 8 they become usable for the first time; its denied calls (unregistered_echo, IAP 403 before the backend) are unaffected and comparable with run 7 and gw 1. Reported as "T56 v2 run 2, first run with usable allowed calls".
**T49 and other agent G tests:** agent G's tarball changes only inside `call_mcp_tool`, which T49, T47 and T31-type probes do not call; recorded as a deviation, run counts not reset.
**Limitation for the report:** the control passes with the agent's ID token unbound for this one call; claims about T53 say so.
**Runs:** run 8 (11-14) = T53 v3 run 1. A second run is not scheduled (11-16 spare).

### T54 (optional): DNS egress
**Docs:** public-zone query logging exists (`gcloud dns managed-zones update ZONE --log-dns-queries`); cached answers are not logged. **Precondition:** a self-owned subdomain delegated to a Cloud DNS public zone (human, registrar). From the PSC-I + SWP agent: resolve a unique label under it; check the zone's query log. **Expected:** record outcome (docs are silent on whether the runtime's resolver path reaches public authoritative servers under the perimeter). NOT_TESTED without the delegation.

### PAB (Documented note only)
Principal Access Boundary supports agent identity principal sets "only for agent identities in a project", not single agent identities; the section is Preview and the docs disagree on folder/org scope (doc check 2026-11-12). No test; a Documented-tier row in the control map.

### Scheduling (proposal; each run approved by the human)
- Run 3: run-2 sequence unchanged for T40-T43, T45, T47, T48, T46; T44 becomes T44 v2 + T44b (run 1 of the new versions); T49 run 1.
- Runs 4-5 (block-2/3 subsets, a day apart): T49, T44 v2/T44b, T45d, T48b, T50, T51, T52, T53, T55.
- T47r: one separate attempt (block 2 only, V1 policy).
- Europe-west4 runs of T40-T43 only if quota allows (read-only quota check first).

---

## 4. Run design and safety

- **3 independent runs**, at least a day apart, each on its fresh runtime project.
- Order inside a run: T40 → T41 → T42 → T47 → T48 → T49 → T46 → T44 → T45 → T43 (the +24 h check closes the run next day).
- Pace: no bursts of project creation or deploys; model calls only as the tests need. No agent fetches arbitrary URLs.
- Destroy agents, gateway and SWP the same day; keep only the small projects needed for T43's +24 h check.
- Budget alert on the billing account before run 1.
- Rough cost per run: SWP and gateway a few hours (about USD 1.25/gateway-hour for SWP), agents and model calls cents. Under USD 20 per run expected; record the actual.

## 5. Execution with Claude Code (same kit as v1–v2)
- `test-writer` (Sonnet): writes `tests/T40.sh`–`T49.sh` from this plan, each with its pre-registered expected text in the header.
- `runner` (Sonnet): runs one test at a time, stores raw output under `evidence/v3/runN/`. Never runs `git push`.
- `redactor` (Haiku): redacts org ID, domain, emails and token material before anything is committed; fails the run if a token pattern is found.
- `independent-reviewer` (Opus, fresh context): after each run, checks scripts, timestamps and outputs against the claims; writes errata.
- Human: approves each platform-control toggle in T45 and every project creation.

## 6. What changes the article
- T40 or T41 falsified → drop the "deploy-time access" section; the article falls back to the bypass argument plus T45.
- T45 key cells as expected → that table becomes the article's centrepiece (and the LinkedIn image).
- T47 shows the 401 isn't from binding alone → rewrite "inspect or bind" accordingly.
- T48 bound token accepted elsewhere → new finding; the section changes from "trade-off" to "binding didn't protect".
- T49 gateway-path token accepted on replay → new finding: binding doesn't protect behind the gateway. The "inspect or bind" section then says the gateway path gives up binding even without the opt-out, and T46 (DPoP) becomes the open fix. T49 refused as expected → the section can say binding held on both paths in the tested setup.
- Everything that passes goes into `claims-register.md` as new S/C/F entries before the article is updated.
