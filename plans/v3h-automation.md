# v3h runs 2 and 3: end-to-end automation and shorter runs (approved 2026-11-11)

Date: 2026-11-11, after run 1 (evidence/runs/run-v3h-1.md). Scope: the v3h tests T40-T48 and T40b. Same evidence standard; expected results stay pre-registered in the script headers and never change after a run.

## 1. Where run 1's time went (09:33Z-17:15Z, about 7 h 45 min)

| Item | Count | Time | Dictated by |
|---|---|---|---|
| Agent deploys / in-place updates (actual work) | 15 | about 45 min | platform (2.5-3 min each) |
| Spacing between deploys (30 min, then 15 min from 14:42Z) | 14 gaps | about 4 h 30 min | **us** (old suspension pacing; project now allowlisted) |
| Fixed "4 min after deploy" waits | 12 | about 50 min | **us** (no readiness check) |
| Fixed 15-min propagation waits (perimeter, ingress, T45 stages) | 5 | about 75 min | partly platform (VPC-SC propagation), mostly our margin |
| Redeploys only to flip one variable (binding opt-out, PSC-I on/off) | 8 of 15 | (inside the rows above) | **test design** |
| Fixture-fix detours (T48 x2, T45 x1) | 3 | about 1 h 30 min | bugs (fixed) |
| Teardown (gateway, PSC-I release) | 1 | 40 min + PSC-I release (Google-side) | platform |

## 2. Changes that cut the time (target: one run in about 2-2.5 h, unattended)

1. **No deploy spacing.** Deploys run as soon as the previous one finishes (human 2026-11-11: runtime project allowlisted). Still one deploy at a time and no rapid retries; stop on `CONSUMER_SUSPENDED`.
2. **Deploy variants side by side instead of redeploying.** Each variable under test gets its own engine, all created in one early phase:
   - T47/T48: `G-bound` and `G-optout`; `v3a` (bound) and `v3o` (opt-out, same tarball). No opt-out round trips.
   - T45: `v3a-psci`/`v3b-psci` (platform on) and `v3a`/`v3b` (platform off, also used by T44). No PSC-I round trips.
   - T44 keeps its order by design: A before enforcement, B after (B is the only deploy that must wait for a platform state).
3. **Readiness probe instead of the 4-min wait.** New fixture action `ACTION=ping` (no network, returns the result line). Poll every 20 s until it answers, max 10 min.
4. **Neutral canaries instead of fixed propagation waits.** Poll a signal that does not depend on the outcome under test:
   - VPC-SC enforced / dry-run: a canary call (`storage.buckets.get` on the runtime build bucket) by a canary service account the operator impersonates (no keys) that is NOT in any ingress rule: 403 VPC-SC = enforced; anything else = not yet. Same for the ingress rule: the canary's identity is added beside the agent identities, so its first 200 shows the rule is live.
   - IAM deny: no neutral canary exists (the deny targets agent principals only). Keep a fixed wait at the documented propagation time (recorded in notes); this is the only fixed wait left.
   - Never poll the tested call itself until it gives the expected answer.
5. **Overlap the 24 h.** T43 t0 and p15 run at the start of run N (after T40/T41/T42); p24h and agent3 run at the start of run N+1 (or alone the next day for run 3), then T40b.
6. **Fixture fixes from run 1 are already in** (mTLS control, replay invoker, direct-socket deadline, source bucket IAM, unique copy name, `example.com` target for T44, VPC-SC runtime refusal parsing).

Estimated run (no failures): block 1 (step 0, agents 1-2, T40-T42, T43 t0/p15) 30 min; block 2 (gateway infra + 5 engines + T47/T48) 45 min; block 3 (enforce, B deploy, T44 stages, SWP/PSC-I/deny, T45 on/off) 60 min; teardown 20 min plus PSC-I release in the background.

## 3. One command per run

`tests/run-v3h.sh run N` (orchestrator, built 2026-11-11; also `close N`, `teardown N`, `--dry`; scripts T40-T48 unchanged except as listed in section 5):

- Preflight: gcloud config `lz-validation`, account and org as PROGRESS.md, token valid for the expected duration, no engines left from earlier runs, budget alert present. Stops if any check fails.
- Steps as a list with checkpoints in `scratch/run-N.state`: a failed step can be resumed; a finished step is never repeated (evidence is never overwritten; retries get `-rN`).
- Every infra change is a saved plan applied with `terraform -chdir=<root> apply <plan>`; the plan summary (add/change/destroy counts and addresses) is checked against an expected list per step before applying; unexpected destroys stop the run.
- Pre-registered decision rules (written before run 2, applied without asking):
  - transient platform error (HTTP 5xx, `UNAVAILABLE`) on a test query: one retry of that stage as `-r2`, recorded;
  - a control fails: stage INCONCLUSIVE, the run continues with the next block (no in-run fixture fixes);
  - unexpected destroy in a plan, `CONSUMER_SUSPENDED`, a safety check fails: stop, teardown paid resources, notify.
- Always-on teardown (trap): agents, gateway, SWP, replay, targets, buckets; PSC-I attachment deleted by a background poll when Google releases it.
- Writes `evidence/runs/run-v3h-N.md` (timeline, decisions, deviations) and a 20-line summary; redaction (`tools/redact.py` + check) runs at the end; commit stays with Opus after review.

## 4. Human touchpoints (target: 2)

1. Before the run: `gcloud auth login` and `gcloud auth application-default login` (via `!`), then "go".
2. After the run: read the summary, approve the commit.

Needed once: approve this plan, the test-design changes in section 5, and a permission rule for `bash tests/run-v3h.sh *` (the orchestrator does the applies; per-apply checks move into the script).

## 5. Test-by-test revisit (pre-registered before run 2)

| Test | Change for run 2 | Why |
|---|---|---|
| T40 | Step 0a: Vertex service agents created up front (done, data and outside) | F1: isolate the platform grant |
| T40b | Scheduled after T43 agent3 in mcp (once) | Not run yet |
| T41 | Troubleshooter API enabled in step 0 | Run 1 INCONCLUSIVE for that reason |
| T42 | None | PASS |
| T43 | t0/p15 at run start; p24h/agent3 at next run start | Overlap the 24 h |
| T44 | Egress verdict on `https://example.com` (as T23); run.app recorded (done in script) | Run-1 target was Google-hosted |
| T45 | Stages use separate engines (`-psci` for on, plain for off) instead of redeploys; fixes from run 1 | Time; same artifact sha256 |
| T46 | None (Documented) | — |
| T47 | s3 = `G-optout` engine, s4 = repeat on the same `G-bound` engine (no new deploy; amended 2026-11-11 before run 2) instead of a round trip; gateway log check (decoded POST vs CONNECT) recorded by the script | Time; F3 evidence is collected automatically |
| T48 | `v3o` engine for the opt-out stage | Time |
| T49 (new, plan 2026-11-11) | Gateway-path token replay on G / G-optout after T48; needs the replay host in the gateway egress allowlist and `ACTION=replay` in agent G | F3: is a token used through the gateway still bound? |

Decision for the human: section 2 item 2 changes how T45/T47/T48 isolate the variable (two engines with one setting different, instead of one engine changed and changed back). The claim tested is the same; the expected texts get one added sentence naming the engines. Run 1 results stay as they are.

## 6. Out of scope

- The v1/v2 suite (T01-T39): could use the same orchestrator later; not part of this plan.
- Any change to verdict logic after a run.
