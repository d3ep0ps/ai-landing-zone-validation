# Evidence review: run 10 report additions (2026-11-21)

Fresh-context review of the uncommitted run-10 text in `results.md`, `limitations.md`, `environment.md`, `claims-register.md` and the new `plans/run10-fabric-pr-summary.md`, checked against `evidence/runs/run-10.md`, `tests/RUN-ORDER-run10.md`, and `result.json`/`output.txt` under `evidence/{T27,T28,T29,T30,T31,T31R,T32,T38}/run-10/` and `evidence/{T30,T31}/run-10-r2/`. No files were edited apart from this one.

Method limit: Bash was not available, so `git diff` was not run. The run-10 sections were read directly. Whether the uncommitted changes to evidence files are placeholder-only was inferred (see M8), not diffed.

## Verified (no issue)

- Verdicts and tiers in the results.md run-10 table match all 10 `result.json` files: T27, T28, T38, T32, T31R and T30 run-10-r2 are PASS; T29, T30 run-10, T31 run-10 and T31 run-10-r2 are INCONCLUSIVE. T29's tier is Configured; the others are Enforced.
- Counts are right: 8 tests, 10 results, 6 PASS, 4 INCONCLUSIVE, 0 FAIL, 0 NOT_TESTED. They are consistent across results.md:365, S12 and run-10.md.
- Quoted texts match output.txt: the T29 message `Blocked by Model Armor Floor Setting: The prompt violated Prompt Injection and Jailbreak filters.` with `MAX_TOKENS`; the T31 and T31R `Egress request is not authorized.`; T31R registry entry age 317 s, 1 DENIED entry and 5 IAP entries; T30 r2 has 1 DENIED entry and 0 origin requests; T31 has 0 DENIED entries in both attempts, with B `permission_denied=1 phrase=1`.
- Expected texts in result.json and output.txt headers are byte-identical to RUN-ORDER-run10.md "Expected results".
- T29 is not claimed as PASS anywhere. C40 limits the claim to the block.
- T30 reports both attempts everywhere: results.md, C41, limitations.md, S12 and the PR summary.
- T31R v2 is not described as a re-test of T31's endpoint (results.md:372, :376; limitations.md:153; C42; PR summary:10). T31R run 9 stays INCONCLUSIVE in all of them.
- #4397 makes no claim (X21, results.md:352, limitations.md:150, PR summary:12).
- Cost is "pending" with no number (environment.md:155, limitations.md:151).
- Banned words appear only in rule statements (claims-register.md:122, PR summary:14).
- No real org ID, project ID or number, or email appears in the five report files or in the working-tree run-10 evidence. Placeholders are in place, and `.last-output` contains only timestamps.
- Teardown is recorded: run-10.md:44-47 shows the reset verified and only the 8 known leftovers remaining.

## HIGH

None found.

## MEDIUM

**M1. "Scripts unchanged" is false for T31R.** In `results.md:352` the text "Scripts and expected texts are unchanged since their last runs" and in `evidence/runs/run-10.md:3` "Scripts unchanged since their last runs" are both wrong for T31R. `tests/T31R.sh` changed (blocked call, `BLOCKED_URL`, log filter), and so did `tests/fixtures/gateway/agent_g/agent.py` (new key `blocked_global`), in commit e367efc (RUN-ORDER-run10.md:73-77). Deviation 17 discloses the fixture change, but the integrity sentence contradicts it.
- Fix: "Expected texts are unchanged; scripts are unchanged except T31R v2 (script and agent G fixture changed and committed in e367efc before the run, Deviations 17)."

**M2. The T31 refusal body is called "the gateway's" as a fact.** This attribution is exactly what the pre-registered check could not make. Affected places:
- `limitations.md:149` "had the gateway's refusal body"
- `claims-register.md:113` (F38) "whose refusal body was the gateway's"
- `results.md:386` "the refusal body was the gateway's"
- `plans/run10-fabric-pr-summary.md:10` "refusal text from the gateway"
- `evidence/runs/run-10.md:52`

The T31 scripts note that "the 403 body text is not asserted". The link to the gateway is an inference: the same text appeared on T31R (b), which has a DENIED entry.
- Fix: "a 403 with the same body text as the gateway's logged refusals ('Egress request is not authorized.'); attribution by text only, not by the pre-registered log check."

**M3. Several claims rest on post-run log reads stored only in git-ignored `scratch/`.** The files are `scratch/run10-T30-gwlog.json`, `run10-T30-runapp.json`, `run10-T31-gwlog.json`, `run10-T31-e1host.json`, `t31r-global-check.txt` and `t31r-model-check.txt`. The linked evidence folders do not contain these reads:
- `results.md:371`: T32 "gateway log shows `lzv-gw-ma-policy=DENIED` while the origin answered 200". This is not in `evidence/T32/run-10/output.txt`.
- `results.md:372` and `plans/run10-fabric-pr-summary.md:10`: T31R "200 `ALLOWED`" / "(200, gateway ALLOWED)". The script's own supporting count was 0 (`evidence/T31R/run-10/output.txt:1431`).
- `results.md:386` and `claims-register.md:113` (F38): the T30 control's Cloud Run 200, no gateway entry for the T30 control, the IAP `GatekeeperAuthorizer` entry, and "did log … the T31R calls".
- `results.md:388` and `claims-register.md:115` (F40): the model and host checks.

I checked `scratch/run10-T31-gwlog.json` and it does support the ALLOWED entry. It contains unredacted project IDs.
- Fix: either redact these files and add them as `evidence/runs/run-10-supplement/`, then link them, or add the qualification used in F24/F21 ("post-run read; raw output not stored") to each of these statements.

**M4. `limitations.md:155` wrongly says only T30 had a second attempt.** "Only T30 has a second attempt, and it differs from the first." T31 also has `run-10-r2`, with the same verdict.
- Fix: "T30 and T31 have a second attempt (human decision); T30's differs from the first (INCONCLUSIVE then PASS), T31's matches (INCONCLUSIVE twice)."

**M5. Agent G's age is stated wrongly, and the age hypothesis is not tested against T31.** `limitations.md:156` says "agent G was 13 to 33 minutes old at the calls". G was applied at 16:38:06Z (run-10.md:23). Its age at each call was:
- T30: about 13 min
- T30 r2: about 20 min
- T31: 37 min
- T31R pre: 41 min
- T31R post: 47 min
- T31 r2: 51 min

The 33 minutes is B's apply time relative to G. `results.md:386` sets "13 minutes … run 9 about 42 minutes" against each other. But the T31 calls at 37 and 51 min were also unlogged, while T31R at 41 min was logged, so age does not explain the T31 gap.
- Fix: correct the range to "about 13 to 51 minutes", and add to Findings 46: "T31's calls at 37 and 51 minutes were also unlogged, so G's age alone does not explain the missing entries."

**M6. F40 / Findings 48 assert "not served" and a cause beyond the evidence.** Affected places: `results.md:388`, `claims-register.md:115` and `evidence/runs/run-10.md:53`. The 404 text names two causes: "not found or your project does not have access to it" (as F25 notes). "This is / was the cause of the run-9 T31R `post` 404" is an inference. The `results.md:388` heading also says "any regional host", but only europe-west1, -west3, -west4, -west9, `eu` and us-central1 were tried.
- Fix: "Every regional host tried returned 404 ('not found or no access') for every Gemini name tried; … This most likely explains the run-9 T31R `post` 404."

**M7. The run-10 limitations leave out the gateway test setup.** `limitations.md:142-157` does not mention it, although C41/C42 inherit it. The gateway tests (T30, T31, T32, T31R v2) ran with:
- agent G's token-binding opt-out (Deviation 20; the v3h limitation at limitations.md:129 says it "gives up a default protection");
- unbound ID tokens for the MCP calls (`auth=id_token_unbound` in T30/T32 output; compare limitations.md:130);
- IAP policy V2 and VPC egress.
- Fix: add a run-10 bullet: "Gateway tests ran with the token-binding opt-out, unbound ID tokens for MCP calls, IAP policy V2 and gateway VPC egress (setup of runs 8/9); no run-10 result is claimed for a bound-token agent."

**M8. Run-10 evidence was committed unredacted to the private history (inferred).** `git status` shows 33 modified files under `evidence/*/run-10*/`. That matches `scratch/run10-redact.txt` ("redacted 33/42 files"), so the versions committed in 7a1ca2c and bf8e2e4 held unredacted values. This contradicts `README.md:64` ("Evidence is redacted with `tools/redact.py` before it is committed").
- Fix: run `git diff --word-diff evidence/` to confirm the changes are placeholder-only (and that no `expected`/`verdict` field changed). Record the history exposure in PROGRESS.md as for earlier phases. Publish only through the export or fresh-history path, never these commits.

**M9. The PR summary overstates how the objects were migrated.** `plans/run10-fabric-pr-summary.md:3` says every object was moved in state "with `moved` blocks; no recreate". RUN-ORDER-run10.md:23 says only four objects were moved: the folder floor, project floor, `lzv-ma-pi` and the runtime API. The gateway template `lzv-ma-gw`, the 21 (+1) registry entries and the org floor were created new by the modules in run 10. This text is for external readers.
- Fix: "The folder floor, project floor and template `lzv-ma-pi` were moved into the modules with `moved` blocks (no recreate); the gateway template, the registry entries and the org floor were created by the modules in run 10."

## LOW

**L1.** `evidence/runs/run-10.md:3` says result.json `script_commit` is 76c94c5 for every test. That holds only for T27/T28/T29. T38, T30, T31, T31R and T32 record e367efc.
- Fix: state both commits.

**L2.** `results.md:368` "so the script did not give a verdict" is inaccurate: it returned INCONCLUSIVE.
- Fix: "the script returned INCONCLUSIVE". Optionally add that the prefix check also failed (`floor message=0`), so with a working control the verdict would most likely have been FAIL, as in runs 6/7 (the RUN-ORDER prediction).

**L3.** `results.md:359` "(org scope, no project floor)" and `claims-register.md:66` (C39) "in a project with no project floor" are not quite right. T38 output line 56 shows the data project has a floor setting that is non-enforcing with an empty filter config.
- Fix: "no enforcing project floor".

**L4.** `results.md:386` says that under "T31 (both attempts)" one IAP `data_access` entry exists. run-10.md:43 places that single entry at 17:29:03Z, which is the second attempt only.
- Fix: "one IAP data_access entry (second attempt, 17:29:03Z)".

**L5.** The T32 expected text is shortened in two places:
- `results.md:362`: "Expected (short)" drops the pre-registered "(connection terminated)". This matches the run 8/9 tables, but the column should not omit the clause that was not met.
- `plans/run10-fabric-pr-summary.md:9`: the T32 row omits that the block arrived as 403, not a terminated connection (Findings 30).
- Fix: keep the clause and add "(observed 403; Findings 30)".

**L6.** Two wording slips in the claims register:
- `claims-register.md:22` (S12) "repeated 8 tests": T31R v2 is a new version. Write "7 tests repeated and T31R v2 (new fixture)".
- `claims-register.md:142` (X22) "Five modules": there are four modules (folder, project, organization, geap-agent-registry) covering five PR inputs.

**L7.** In `claims-register.md:3` the update history is out of date order: run 10, dated 2026-11-21, is listed between run 7 and v3h.
- Fix: move it to the end.

**L8.** Several earlier claims are not cross-referenced to run 10:
- `claims-register.md:56` (C29) still says "T31R did not confirm the attribution". Add "T31R v2 (run 10, different host) did; C42".
- `claims-register.md:123` (X3), `:132` (X12) and `:134` (X14) describe T29 as FAIL and list Agent Gateway runs 8/9 only. Add the run-10 state: T29 INCONCLUSIVE, T31 INCONCLUSIVE twice, T31R v2 PASS.

**L9.** `limitations.md:150` labels #4397 with the verdict word **NOT_TESTED**, while results.md:365 counts 0 NOT_TESTED. Nothing ran for it.
- Fix: label it "Not in scope (not exercised)".

**L10.** The leftovers and paid-resource notes are incomplete:
- `limitations.md:152` leftovers omit the seed project's regional Cloud Build bucket, which still holds the run-10 build source (run-10.md:46).
- `limitations.md:139` (v3h) "The fixture services remain deployed" is now stale: they were deleted at 17:41Z (run-10.md:45).
- `limitations.md:151` lists the Cloud Run services as existing 15:51Z-17:58Z. They had existed since 2026-11-11 (min instances 0) and were deleted at 17:41Z.
- Fix: correct all three.

**L11.** `limitations.md:155` "One injection sample, one template, one project" is not accurate. T28 used `lzv-ma-pi` and T32 used `lzv-ma-gw`; T38 ran in a second project.
- Fix: say two templates and two projects.

**L12.** The `control` field in `evidence/T31R/run-10/result.json` reads "Re-test of T31 part 1". That is the unchanged pre-registered header, but a reader may take it as a same-endpoint re-test. Do not edit the evidence.
- Fix: add one sentence at results.md:372 saying the header text predates v2 and the host differs.

**L13.** Two run conditions in RUN-ORDER-run10.md were never amended for v2:
- `tests/RUN-ORDER-run10.md:50`: the T31R run condition says "a model call that can return 200 on the europe-west1 host".
- `tests/RUN-ORDER-run10.md:92`: 10-2r says "Only with fixture option (a) or (b)".

The v2 section (line 69) supersedes both but does not say so.
- Fix: add to Deviations 17 that v2 replaced these conditions (eu.rep host; a new option beyond (a) to (c)).

**L14.** `plans/run10-fabric-pr-summary.md:3` names the author's domain and GitHub handle (`d3ep0ps.com`, `github.com/d3ep0ps/...`). It is not a test-org identifier and already appears in other plans/notes.
- Fix: confirm this is intended for publication. Remove the internal wording note at line 14 before pasting into PRs.

**L15.** The tool table at `environment.md:146-148` still shows Google provider 8.8.0 and Terraform v1.17.0 with no run-10 entry; only the prose at line 155 has the run-10 values.
- Fix: add a run-10 row (8.12.0, 1.17.2).

**L16.** `README.md` has no run-10 mention (it is not in the change set).
- Fix: add a one-line pointer to results.md "Run 10".

**L17.** `claims-register.md:69` (C42) "The refusal of a model endpoint is the registry's" generalizes from one host and one run.
- Fix: "The refusal of G's call to `aiplatform.eu.rep.googleapis.com` was the registry's: …".

## Resolution (Opus, 2026-11-21)

- M1-M9: fixed in 481fb20 (M3: redacted log extract evidence/runs/run-10-logs.md; M8: word-diff confirmed placeholder-only changes, recorded in run-10.md "Closing").
- L1-L13, L15-L17: fixed (text only; no evidence file content, verdict or expected text changed; L12 handled in results.md, not in the evidence).
- L14: d3ep0ps.com / GitHub handle kept (the human's own article site and public repo); the internal wording note was removed from the PR summary.
