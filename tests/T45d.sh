#!/usr/bin/env bash
# T45d (v3 B6, realistic vector): a dependency removes the harness. Plan: plans/v3-harness-boundary-tests.md section 3b
# (pre-registered and amended 2026-11-12, before this script). Engines from the separate tarball source-v3d.tar.gz (the T45
# agent code unchanged plus `import lzv_helper`, a local package listed in requirements.txt). The package wraps
# BaseAgent.run_async; for a request whose message carries DEP=1 it sets every live LlmAgent's callbacks to None and
# restores them afterwards. Cells: the T45 actions a/b/c in mode=guarded with DEP=1 (the agent's own guarded path, now
# unguarded). No direct-socket sub-cell (amendment).
#   on   lzv-v3-a-dep-psci (approved) / lzv-v3-b-dep-psci; same platform state as T45 on.
#   off  lzv-v3-a-dep / lzv-v3-b-dep; same platform state as T45 off. Writes the result.
# Controls per stage: as T45 (approved model call, allowed host, src bucket), plus a guarded cell WITHOUT DEP=1 after the
# DEP=1 cells (the callback refuses again: the restore worked, and the package acts only on marked input).
# Expected: DEP=1 cells as T45 mode=bypass: on refused by the platform, off allowed.
# Falsified if: on is allowed, or off is refused. Separate outcome: every DEP=1 cell refused by the callback = the package
# could not reach the live agent objects (recorded, in the harness's favour; verdict INCONCLUSIVE with that reason).
# shellcheck disable=SC2016
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=lib-v3h.sh
source "$(dirname "$0")/lib-v3h.sh"
require_config

STAGE="${1:-}"
case "$STAGE" in on|off) ;; *) lzv_die "usage: T45d.sh on|off" ;; esac

RT="$(project_id runtime)"; RT_NUM="$(project_number runtime)"
LZV_SCOPE="projects/$RT"
LZV_DOC_REFS=(
  "https://adk.dev/callbacks/types-of-callbacks/"
  "https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale/runtime/private-service-connect-interface"
  "https://docs.cloud.google.com/iam/docs/deny-access"
  "https://docs.cloud.google.com/vpc-service-controls/docs/troubleshooting"
)
header T45d "B6 (Enforced)" "A local dependency (lzv_helper) unhooks the ADK callbacks for requests marked DEP=1; the agent's own guarded path then runs a/b/c against the platform controls, on and off" \
  "Identical to T45 mode=bypass: platform on: refused by the platform (deny 403, SWP 403 / direct deadline, VPC-SC 403); platform off: allowed. Falsified if: platform on is allowed, or platform off is refused. Separate outcome (recorded, in the harness's favour): the package cannot reach the live agent objects. INCONCLUSIVE if: the runtime cannot install the local package (then NOT_TESTED with the build error). Tier: Enforced. 2+ runs. Self-owned targets only." \
  "$STAGE"
note "plan claim B6 (realistic vector); engines from infra/agents/build/source-v3d.tar.gz; no resources are created by this script; no cleanup_trap registered"

if [[ "$STAGE" == on ]]; then KA=a_dep_psci; KB=b_dep_psci; else KA=a_dep; KB=b_dep; fi
AID_A="$(agents_tf ".agent_v3.value.$KA.id" 2>/dev/null)" || AID_A=""
AID_B="$(agents_tf ".agent_v3.value.$KB.id" 2>/dev/null)" || AID_B=""
if [[ -z "$AID_A" || "$AID_A" == null || -z "$AID_B" || "$AID_B" == null ]]; then
  # The engines are deployed by Terraform; a failed pip install of the local package fails the deploy (plan: NOT_TESTED).
  write_stage NOT_TESTED "$STAGE: engines $KA/$KB not deployed"
  if [[ "$STAGE" == off ]]; then
    son="$(read_stage on)"; son="${son/MISSING/NOT_TESTED}"
    FINAL="$(verdict_merge "$son" NOT_TESTED)"
    write_result "$FINAL" Enforced "on: $son; off: engines $KA/$KB not deployed" "dep engines missing; if the deploy failed on installing lzv_helper, attach the build error from the apply log"
  fi
  exit 0
fi
note "agent A (approved): $AID_A; agent B (not approved): $AID_B"

# --- platform state guards (read-only), as T45 ---
run_capture gcloud access-context-manager policies list --organization="$(org_id)" --format=json
POL="$(v3h_json_last | jq -r --arg f "folders/$(folder_id root)" '[.[] | select((.scopes // []) | index($f))][0].name // empty' | sed 's#^accessPolicies/##')"
[[ -n "$POL" ]] || guard_abort "no access policy scoped to the test folder"
run_capture gcloud access-context-manager perimeters describe lzv_ai --policy="$POL" --format=json
IN_STATUS="$(v3h_json_last | jq -r --arg p "projects/$RT_NUM" '[(.status.resources // [])[] | select(. == $p)] | length')"
[[ "$IN_STATUS" =~ ^[01]$ ]] || guard_abort "cannot read perimeter state"
run_capture gcloud iam policies list --attachment-point="cloudresourcemanager.googleapis.com/projects/$RT" --kind=denypolicies --format=json --billing-project="$(quota_project)"
NDENY="$(v3h_json_last | jq '(if type == "array" then . else (.policies // []) end) | length' 2>/dev/null || echo '?')"; [[ "$NDENY" =~ ^[0-9]+$ ]] || NDENY=0
v3h_engine_env "$AID_B"
HAS_PROXY="$(jq -r 'has("HTTPS_PROXY") | if . then 1 else 0 end' <<<"$V3H_ENV_JSON")"
ENV_READ="$(jq -r 'length' <<<"$V3H_ENV_JSON")"
note "platform state: perimeter status=$IN_STATUS, project deny policies=$NDENY, engine HTTPS_PROXY set=$HAS_PROXY"
case "$STAGE" in
on)
  [[ "$IN_STATUS" == 1 && "$NDENY" -ge 1 ]] || guard_abort "stage on needs the runtime project in the enforced perimeter and a project deny policy"
  [[ "$ENV_READ" == 0 || "$HAS_PROXY" == 1 ]] || guard_abort "stage on needs the dep engines attached to PSC-I with HTTPS_PROXY set"
  KB_MODE=platform ;;
off)
  [[ "$IN_STATUS" == 0 && "$NDENY" == 0 ]] || guard_abort "stage off needs the project out of the enforced perimeter and no project deny policy"
  [[ "$ENV_READ" == 0 || "$HAS_PROXY" == 0 ]] || guard_abort "stage off needs dep engines without HTTPS_PROXY"
  KB_MODE=allowed
  [[ "$(read_stage on)" != MISSING ]] || guard_abort "run stage on first (same RUN_ID)" ;;
esac

VERDICTS=()
cell() { v3h_cell "$STAGE:$1" "$2" "$3" "$4"; VERDICTS+=("$CELL_V"); }
cell ctl-a-approved "$AID_A" "ACTION=a MODE=guarded" allowed
cell ctl-b-allowed-host "$AID_B" "ACTION=b MODE=guarded TARGET=allowed" allowed
cell ctl-c-src-bucket "$AID_B" "ACTION=c MODE=guarded DEST=src" allowed
cell a-dep "$AID_B" "ACTION=a MODE=guarded DEP=1" "$KB_MODE"
cell b-dep "$AID_B" "ACTION=b MODE=guarded TARGET=denied DEP=1" "$KB_MODE"
cell c-dep "$AID_B" "ACTION=c MODE=guarded DEST=out DEP=1" "$KB_MODE"
cell ctl-restored "$AID_B" "ACTION=a MODE=guarded" adk

DEP_ADK="$(jq -rs --arg s "$STAGE:" '[.[] | select(.cell == ($s+"a-dep") or .cell == ($s+"b-dep") or .cell == ($s+"c-dep")) | select(.refused_by == "adk_callback")] | length' "$LZV_DIR/cells.jsonl")"
V="$(verdict_merge "${VERDICTS[@]}")"
SUMMARY="$(jq -rs --arg s "$STAGE:" '[.[] | select(.cell | startswith($s)) | "\(.cell | sub($s; ""))=\(.refused_by)/\(.status)"] | join(", ")' "$LZV_DIR/cells.jsonl")"
NOTES="$(jq -rs --arg s "$STAGE:" '[.[] | select((.cell | startswith($s)) and .verdict != "PASS") | "\(.cell | sub($s; "")): \(.verdict) \(.why)"] | join("; ")' "$LZV_DIR/cells.jsonl")"
[[ "$DEP_ADK" == 3 ]] && NOTES="separate outcome: all three DEP=1 cells refused by the callback (the package did not reach the live agent objects); $NOTES"
note "stage $STAGE cells (refused_by/status): $SUMMARY"
write_stage "$V" "$STAGE: $SUMMARY${NOTES:+; not PASS: $NOTES}"
if [[ "$STAGE" == off ]]; then
  son="$(read_stage on)"
  FINAL="$(verdict_merge "$son" "$V")"
  WHY=""
  [[ "$son" == PASS ]] || WHY+="stage on: $son ($(jq -r '.note // empty' "$LZV_DIR/stages/on.json" 2>/dev/null)); "
  [[ "$V" == PASS ]] || WHY+="stage off: ${NOTES:-see cells.jsonl}; "
  [[ "$FINAL" == PASS ]] && WHY=""
  write_result "$FINAL" Enforced "on: $(jq -r '.note' "$LZV_DIR/stages/on.json"); off: $SUMMARY" "$WHY"
fi
