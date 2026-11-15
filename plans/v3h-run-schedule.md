# v3h run schedule (2026-11-12 to 2026-11-16)

What to run, when, and the rules that keep the results valid. Commands are `tests/run-v3h.sh ...`. Step details are in `tests/RUN-ORDER-v3h.md`; pre-registrations are in `plans/v3-harness-boundary-tests.md` sections 3 and 3b.

**Code freeze:**
- Scripts, fixtures and orchestrator are frozen at **e82ed7d** (human pre-close fixes, 2026-11-12). It came after the commit that added this file (9b0a334), and no expected result changed: parsing robustness, T40b outcome (ii) handling, close init/teardown/redaction. Every run log records that commit before its first step.
- Additions after the freeze (2026-11-12): T57 (results.md Findings 24 / claims F20 re-check, pre-registered in 31baf11; own command `t57 1`, between rows) and T56 (results.md Findings 29 / claims F24 re-check, pre-registered in f33a611) and its two steps in the subset orchestration. No existing script or expected result changed; the subset gains about 16 min (the late read waits 15 min after T56's last call, mostly overlapping the T52 wait).
- Any change to a test script or its target after this point makes that test's next run "run 1" of a new version. It is recorded as a deviation and the schedule is re-planned.
- Tooling fixes that do not change how a test decides (for example the preflight engine count) are recorded in the run log and do not reset the count.

## Calendar

All times are UTC. "≥" means not before. Each row starts only after the previous row has finished, including its teardown and redaction.

| # | When | Command | What it covers | Paid | About |
|---|---|---|---|---|---|
| ✓ | 11-12 05:45 | `t47r 1` | T47r (done: 200, "the run-6 401 did not reproduce") | gateway | 40 min |
| 1 | 11-12 ≥16:46 | `close 1` | T43 p24h + agent3 for run 1; T40b in mcp (once; amendment: a 400 on the empty binding is recorded as the result) | agents | 1.5 h |
| 1a | 11-12, before close 1 (start by 16:25) or between close 1 and close 2 | `t57 1` | T57: targeted destroy of the runtime project floor, raw describe before/after, restore (Findings 24) | none | 12 min |
| 2 | 11-12 ≥21:16 | `close 2` | T43 p24h + agent3 for run 2 | agent | 30 min |
| 3 | 11-13 04:00 (human decision 11-12; starts automatically only if close 2 finished cleanly) | `run 3` | Run 3 of T40-T42, T45, T47, T48, T43 t0/p15; T46 (NOT_TESTED); run 1 of T44 v2, T44b and T49 | all blocks | 6-7 h |
| 4 | 11-13, right after a clean run 3 (human approval 11-12, automatic) | `t47r2 1` | T47r2. Only if run 3's T49 `bound` shows G's token bound; the orchestrator stops before anything paid otherwise | gateway | 40 min |
| 5 | 11-14 ≥04:34 (run-3 T43 t0 04:32:36Z + 24 h; queued automatically) | `close 3` | T43 p24h + agent3 for run 3 | agent | 30 min |
| 6 | 11-13 07:28 (re-ordered, human 11-13; see note below) | `subset 4` (run 4) | **Stopped at 07:59Z** (T52 harness defect, macOS sed). Recorded: T48b v1 INCONCLUSIVE, T50 main FAIL (b1 409). No paid resources left. Commit 4bc06c7 | all blocks | 1.3 h |
| 6a | 11-13 09:35 | `T50c.sh` | T50c: canary control for T50 b1 (pre-registered 820b9b4). PASS: 409 for a principal without setIamPolicy | none | 2 min |
| 6b | 11-13, after a fresh login (human decision 11-13: fix, then re-run today) | `subset 5` (run 5 = subset 4, attempt 2) | Run 1 of T45d, T48b v2, T51, T52, T53, T55, T56; run 2 of T50; run 2 of T44 v2, T44b, T49 | all blocks | 6 h |
| 6c | 11-13 09:53 | `subset 5` (run 5) | **Stopped at 10:29Z** (T52 grant allowlist omitted `[0]`). Recorded: T48b v2 PASS, T50 main FAIL, T52 default PASS. No paid resources left | all blocks | 1.4 h |
| 6d | 11-13 ~11:25 (human go 11-13) | `subset 7` (run 7 = subset 4, attempt 3) | Same scope as row 6b | all blocks | 6 h |
| 6e | 11-13 14:01-15:58 (human decision 11-13) | `gw 1` | Done (resumed 3 times: login expiry, tooling). T53 v2 INCONCLUSIVE (fixture 401), T56 v2 FAIL (1 of 5 denied calls without a record). No paid resources left | gateway, agents | 2 h |
| 7 | 11-14 ≥04:34 (in practice when the laptop is open), after run 7 has finished and a valid login (queued automatically) | `close 3` | T43 p24h + agent3 for run 3 | agent | 30 min |
| 7a | 11-14 15:04-17:47 (done; human decision 11-14) | `subset 8` (run 8) | Run 2 of T45d, T48b v2, T51, T52, T55, T56 v2 (first with usable allowed calls); run 1 of T53 v3 (pre-registered f4beb25); run 3 of T50; run 3 of T44 v2, T44b, T49 | all blocks | 6 h |
| 8 | 11-15 (11-16 spare for a pre-registered repeat if needed; article 11-17) | reports | results, limitations, claims register, article checks; evidence-reviewer and redaction-checker | none | |

**If a day slips:** shift the later rows by the same amount. The only fixed anchors are the closes: each needs at least 24 h after its run's T43 t0, and it may run later. `subset 5` needs at least 24 h after `subset 4`.


**After run 4 (2026-11-13):** deviations are recorded in plan section 3b (sed tooling fix, T48b v2, run numbering), before run 5. Close 3 no longer waits for a clean subset, only for it to finish, because it does not depend on the subset; run 6 still needs run 5 rc=0.

**Re-order 2026-11-13 (human decision, recorded before subset 4 started):** subset 4 runs before close 3, inside the run-3 T43 window. Why it does not weaken T43: subset 4 does not use the per-run projects (`outside` holds the run-3 T43 state), and its Terraform steps are the same blocks 2-3 that run 3 itself applied inside that window right after T43 t0. Each T43 window had other activity too (run 1: run 2; run 2: T47r, T57, close 1; run 3: T47r2, subset 4); close 3's p24h check compares the per-run project's IAM against t0 as before. Subset 5 keeps its 24 h spacing after subset 4.

## Run counts after the schedule

| Test | Runs | Target |
|---|---|---|
| T40, T41, T42, T45, T47, T48 | 3 (runs 1, 2, 3) | 3 |
| T43 | 3 (closes 1, 2, 3) | 3 |
| T44 v2, T44b, T49 | 3 (runs 3, 7, 8; partial run 5) | 3 |
| T45d, T51, T52, T55 | 2 (runs 7, 8) | 2+ |
| T48b | v1: 1 (run 4, INCONCLUSIVE, fixture); v2: 3 (runs 5, 7, 8) | 2 |
| T50 | 4 (runs 4, 5, 7, 8; deny stage in runs 7, 8) | 2+ |
| T50c (T50 b1 control) | 1 | 1 |
| T56 (Findings 29 re-check) | v1: run 7 (fixture down for allowed calls); v2: 2 (gw 1 with allowed calls 401, run 8) | 2 |
| T53 | v1: run 7 (misclassified, control 404); v2: 1 (gw 1, fixture 401: bound ID token); v3: 1 (run 8, unbound ID token for the fixture) | 2 |
| T57 (Findings 24 re-check) | 1 (row 1a) | 1 |
| T40b, T47r, T47r2 | 1 each | 1 |
| T46 | NOT_TESTED (doc evidence) | |
| T54 | not scheduled (needs a delegated DNS zone) | optional |

## Rules that keep the sequence valid

1. **One orchestration at a time.** Never overlap a close with a run or subset (T57 included: it changes the runtime project floor until its restore). Block 3 enforces the perimeter, and an agent3 deploy in a per-run project could be refused while it is enforced (the F4 pattern), which would spoil T43.
2. **Logins before each row.** Run `! gcloud auth login` and `! gcloud auth application-default login` right before starting, and stay reachable. Since 2026-11-12 ~16:00Z admin logins last about 24 h (human reconfigured the reauth window; was about 1 h), so one login can cover several rows; the orchestrator's safety check still runs before every plan. On an expired login the orchestrator stops and tears down; the row is then resumed with the same command, and finished steps are skipped.
3. **A human "go" for every row.** Rows 4, 6 and 7 create paid resources and tear them down the same day. Row 4 also needs explicit approval of T47r2.
4. **Do not change expected results, scripts or targets between runs** (code freeze above). Unexpected behaviour is a finding in the run log, never an edit.
5. **Start each row with a clean state:** 0 reasoning engines and 0 agent gateways in the runtime project (the preflight checks engines through REST). Run 1's PSC-I attachment with 2 unreleased endpoints is a known leftover: free, kept by the proxy-on runs, and every teardown reports it.
6. **Redaction before commit:** the orchestrator redacts and checks each row's evidence. Commit after each row; never push.
7. **Stop conditions:** a guard abort, an unexpected plan change, a failed safety check, or CONSUMER_SUSPENDED stops the row and tears down. Read the log before resuming, and record why.

## Decision points

- **After row 3 (T49 bound):**
  - G's token bound (agent_cert, should_request_bound, replay 401): run row 4 (T47r2).
  - Not bound: H2 explains the November 200s; T47r2 stays NOT_TESTED and row 4 is skipped.
- **After row 3 (T44 v2 / T44b):** if A cannot create a session even at +15 min, T44 is INCONCLUSIVE and T44b decides. Keep the subsets unchanged either way.
- **After row 6:** if a new test is INCONCLUSIVE because of its fixture (not the control), the fix creates a new version. Run `subset 5` anyway for the other tests, and re-plan the fixed test separately.
