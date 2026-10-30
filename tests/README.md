# tests

`lib.sh` (shared helpers, EXECUTION-PLAN.md Appendix C) and `T01.sh` .. `T17.sh`, one script per test. Run order and the human applies between stages are in `RUN-ORDER.md`.

## Running

```bash
RUN_ID=run-1 tests/T01.sh            # single-stage test
RUN_ID=run-1 tests/T13.sh setup      # multi-stage test: stage name as $1
```

- `RUN_ID`: `run-1`, `run-2`, or a retry such as `run-1-r2`. `dry` writes to `scratch/dry/` (still calls the cloud: only for debugging with human approval).
- Evidence: `evidence/TNN/RUN_ID/command.txt`, `output.txt`, `result.json`; multi-stage tests also write `stages/STAGE.json`. Existing evidence is never overwritten; a re-run needs a new `RUN_ID`.
- Exit codes: 0 = a result (any verdict) was written; 2 = guard abort (wrong config, missing input, evidence exists).

## Script conventions (all scripts)

1. `#!/usr/bin/env bash`, `set -u` (not `set -e`: failures are data), `source "$(dirname "$0")/lib.sh"`, `require_config`.
2. `header` with the expected result copied exactly from Appendix A. Set `LZV_SCOPE` and `LZV_DOC_REFS=(...)` (URLs from `notes/doc-verification.md`).
3. IDs come from lib lookups only: `project_id runtime|mcp|data|outside`, `project_number ...`, `folder_id root|ai_prod`, `org_id`, `agents_tf '<jq>'`. Never hard-code a project ID, number, org ID or email.
4. Register `cleanup_trap '...'` before creating anything. After each delete, run a describe/list check so `output.txt` shows the resource is gone.
5. Attempts use `run_capture` (argv) or `run_capture_sh '...'` (pipes, tokens). Tokens only inside single-quoted `run_capture_sh` strings as `$(gcloud auth print-access-token)`, piped to `curl -H @-`, so they never reach a file.
6. Verdicts: `expect_denied REGEX...` / `expect_success REGEX...` (all regexes must match). Combine attempts with `verdict_merge`. Signatures = constraint ID plus error code where the text is undocumented (doc-verification notes).
7. Precondition not met -> `not_tested TIER "reason"` (or INCONCLUSIVE with a reason, if the spec says so). Never weaken an expected result in code.
8. Cloud Run deploys (T02, T03, T17) run in `prj-lzv-mcp`, region `europe-west1`, image `us-docker.pkg.dev/cloudrun/container/hello`, and must comply with every folder policy except the one under test: `--ingress=internal`, `--binary-authorization=default`, no `--no-invoker-iam-check`. Denials are attributed by the constraint name in the error.
9. Buckets: EU location (`europe-west1`) unless the test is about location; names from `lzv_name tNN`.
10. No `--quiet`/`-q` (lib aborts). No writes at the organization root. No service account keys kept. No raw output to the console.
11. Static checks: `bash -n tests/TNN.sh && shellcheck -x -P SCRIPTDIR tests/TNN.sh`.
