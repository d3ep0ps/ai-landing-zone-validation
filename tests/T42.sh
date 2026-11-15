#!/usr/bin/env bash
# T42 (v3 B3): a policy-as-code gate on tfplan.json does not see the out-of-band grant.
# Plan: plans/v3-harness-boundary-tests.md T42; rule in infra-v3h/policy/aiplatform-grant.rego (rerunnable by readers).
# Stages: before | after, run in the same sequence as T40 (before the agent 1 deploy, after it). No human step of its own.
# Needs conftest (brew install conftest); if it is not installed the result is NOT_TESTED with that reason.
# Positive control (both stages): tests/fixtures/t42/tfplan-grant.json, a synthetic plan with one google_project_iam_member
# granting roles/aiplatform.user, must FAIL the gate; otherwise the rule is not proven and the result is INCONCLUSIVE.
# Falsified if: the gate flags the grant in the real plan.
# shellcheck disable=SC2016
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=lib-v3h.sh
source "$(dirname "$0")/lib-v3h.sh"
require_config

STAGE="${1:-}"
case "$STAGE" in before|after) ;; *) lzv_die "usage: T42.sh before|after" ;; esac

LZV_SCOPE="folders/$(folder_id root)"
LZV_DOC_REFS=(
  "https://www.conftest.dev/install/"
  "https://developer.hashicorp.com/terraform/internals/json-format"
)
header T42 "B3 (Configured)" "Conftest/OPA gate on tfplan.json before and after the deploy; control: synthetic plan with a roles/aiplatform.user grant must fail the gate" \
  "the gate passes with 0 violations both times, because pre-deploy static analysis only sees declared Terraform resources, not out-of-band \`SetIamPolicy\` side effects executed by Google's control plane during runtime provisioning. Falsified if: the gate flags the grant. Tier: Configured. Keep the Rego rule in the repo so readers can rerun it." \
  "$STAGE"
note "plan claim B3; no cloud resources are created by this script; no cleanup_trap registered"
note "by construction: a plan only lists declared resources; a gate pass is expected and says nothing about the live policy (see T40 for the live read-back)"

command -v conftest >/dev/null 2>&1 || not_tested Configured "conftest is not installed (brew install conftest); the gate cannot be run"
run_capture conftest --version

v3h_init
LZV_SCOPE="projects/$V3H_PID"
POLICY="$LZV_ROOT/infra-v3h/policy"
CONTROL="$LZV_ROOT/tests/fixtures/t42/tfplan-grant.json"
[[ -f "$CONTROL" && -d "$POLICY" ]] || guard_abort "missing control fixture or policy directory"
note "rego rule sha256: $(shasum -a 256 "$POLICY/aiplatform-grant.rego" | cut -c1-16)...; conftest version output in output.txt"

case "$STAGE" in
before) [[ -z "$(v3h_agent 1 id)" ]] || guard_abort "stage before needs agent 1 not deployed" ;;
after)  [[ -n "$(v3h_agent 1 id)" ]] || guard_abort "stage after needs agent 1 deployed"
        [[ "$(read_stage before)" != MISSING ]] || guard_abort "run stage before first (same RUN_ID)" ;;
esac

# 1. positive control: the gate must FAIL the synthetic grant
run_capture conftest test "$CONTROL" --policy "$POLICY" --no-color
if expect_denied 'grants roles/aiplatform\.user'; then CV=PASS; CW=""
else CV=INCONCLUSIVE; CW="positive control did not fail the gate with the expected message ($LZV_REASON); the rule is not proven"; fi
[[ "$LZV_VERDICT" == FAIL ]] && CW="positive control PASSED the gate: the rule does not catch a plain aiplatform grant"

# 2. the real plan
v3h_plan "$STAGE"
if [[ ! -f "$V3H_PLAN_JSON" ]]; then
  RV=INCONCLUSIVE; RW="no plan JSON (terraform plan exit $V3H_PLAN_RC)"
else
  run_capture conftest test "$V3H_PLAN_JSON" --policy "$POLICY" --no-color
  case "$LZV_LAST_RC" in
    0) RV=PASS; RW="" ;;
    1) RV=FAIL; RW="the gate flagged the real plan: $(grep -E 'FAIL' "$LZV_LAST_OUT" | head -3 | tr '\n' ' ' | cut -c1-300)" ;;
    *) RV=INCONCLUSIVE; RW="conftest error (exit $LZV_LAST_RC)" ;;
  esac
  note "real plan ($STAGE): terraform plan exit $V3H_PLAN_RC; conftest exit $LZV_LAST_RC"
fi

V="$(verdict_merge "$CV" "$RV")"
write_stage "$V" "$STAGE: control=$CV, real plan gate=$RV (plan exit $V3H_PLAN_RC)"
if [[ "$STAGE" == after ]]; then
  sbv="$(read_stage before)"
  FINAL="$(verdict_merge "$sbv" "$V")"
  WHY=""
  [[ "$sbv" == PASS ]] || WHY+="stage before: $sbv ($(jq -r '.note // empty' "$LZV_DIR/stages/before.json" 2>/dev/null)); "
  [[ "$CV" == PASS ]] || WHY+="control: $CW; "
  [[ "$RV" == PASS ]] || WHY+="real plan: $RW; "
  [[ "$FINAL" == PASS ]] && WHY=""
  write_result "$FINAL" Configured "before: $(jq -r '.note' "$LZV_DIR/stages/before.json"); after: control=$CV, real plan gate=$RV (plan exit $V3H_PLAN_RC)" "$WHY"
fi
