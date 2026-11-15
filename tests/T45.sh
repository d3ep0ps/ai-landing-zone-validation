#!/usr/bin/env bash
# T45 (v3 B6): in-process harness guard vs. platform control, head to head. Plan:
# plans/v3-harness-boundary-tests.md T45. Agents v3a (approved) and v3b (NOT approved) boot with HARNESS_GUARD=on.
# Forbidden actions are run against v3b: a = model call by a non-approved agent (platform: IAM deny with exception for
# v3a only), b = HTTP to the non-allowed host (platform: perimeter + PSC interface + SWP allowlist), c = copy to the
# bucket outside the perimeter (platform: VPC-SC perimeter). Per action: mode=guarded (real ADK callback) and mode=bypass
# (callbacks set to None in-process, client called directly); b bypass is run twice: VARIANT=proxy (HTTPS_PROXY kept) and
# VARIANT=direct (HTTPS_PROXY unset in os.environ, closing the v2 T34 gap).
# Stages = the platform toggle (human steps, approved one by one; all controls in the test folder only):
#   on   deny policy active (exception: v3a), runtime project in the ENFORCED perimeter, agents attached to PSC-I with the
#        SWP allowlist (agent_v3_use_psci=true: HTTPS_PROXY set in the engine env). Wait 15 minutes after the last change.
#   off  deny policy removed, project out of the perimeter (spec and status), PSC-I/SWP removed (agents redeployed
#        with agent_v3_use_psci=false). Wait 15 minutes. Result is written by `off`; the human restores afterwards.
# Controls in each stage (must answer 200, else INCONCLUSIVE): v3a guarded model call; v3b guarded b to the allowed host;
# v3b guarded c with DEST=src. refused_by per cell is read from the agent JSON line and kept in cells.jsonl.
# T45b: the direct-socket cell records the observed result; the doc says only that a PSC-I VPC has no default internet
# path (not that direct access is blocked). A 200 in `on` falsifies, anything else is recorded as observed.
# Falsified if: bypass + platform on is allowed, or bypass + platform off is refused (then INCONCLUSIVE: investigate).
# shellcheck disable=SC2016
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=lib-v3h.sh
source "$(dirname "$0")/lib-v3h.sh"
require_config

STAGE="${1:-}"
case "$STAGE" in on|off) ;; *) lzv_die "usage: T45.sh on|off" ;; esac

LZV_SCOPE="folders/$(folder_id root)"
LZV_DOC_REFS=(
  "https://adk.dev/callbacks/types-of-callbacks/"
  "https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale/runtime/private-service-connect-interface"
  "https://docs.cloud.google.com/iam/docs/deny-access"
  "https://docs.cloud.google.com/vpc-service-controls/docs/troubleshooting"
)
header T45 "B6 (Enforced)" "In-process bypass of an active ADK harness guard (HARNESS_GUARD=on) vs. platform controls, 3 actions x guarded/bypass x platform on/off (+ b direct socket)" \
  "mode=guarded: refused by the ADK callback before the call leaves the process, platform on or off. mode=bypass + platform on: refused by the platform (IAM Deny 403, SWP 403 / direct timeout, VPC-SC 403). mode=bypass + platform off: allowed (200), the gap. Falsified if: mode=bypass + platform-on is allowed (platform control failed, including the direct-socket attempt with HTTPS_PROXY unset) or mode=bypass + platform-off is refused (something else is blocking; investigate before claiming). Tier: Enforced. From run 2 (plans/v3h-automation.md, approved before the run): stage on uses side-by-side engines attached to PSC-I (lzv-v3-a-psci approved, lzv-v3-b-psci not approved); stage off uses the plain engines (lzv-v3-a, lzv-v3-b); all from one tarball, no redeploys." \
  "$STAGE"
note "plan claim B6; no resources are created by this script (agents, deny policy, perimeter, PSC-I are Terraform-managed); no cleanup_trap registered"
note "limitation: whether tool code can unhook the live callback inside Agent Runtime is part of what is tested; a callback that still refuses after the unhook is INCONCLUSIVE, not PASS"

RT="$(project_id runtime)"; RT_NUM="$(project_number runtime)"
LZV_SCOPE="projects/$RT"
AID_A="$(agents_tf '.agent_v3.value.a.id' 2>/dev/null)" || AID_A=""
AID_B="$(agents_tf '.agent_v3.value.b.id' 2>/dev/null)" || AID_B=""
# Run 2+: stage on uses the side-by-side PSC-I engines when they are deployed.
if [[ "$STAGE" == on ]]; then
  AP="$(agents_tf '.agent_v3.value.a_psci.id' 2>/dev/null)" || AP=""
  BP="$(agents_tf '.agent_v3.value.b_psci.id' 2>/dev/null)" || BP=""
  if [[ -n "$AP" && "$AP" != null && -n "$BP" && "$BP" != null ]]; then AID_A="$AP"; AID_B="$BP"; note "stage on: side-by-side PSC-I engines lzv-v3-a-psci / lzv-v3-b-psci"; fi
fi
[[ -n "$AID_A" && -n "$AID_B" ]] || guard_abort "deploy agents v3a and v3b first (infra/agents deploy_agent_v3a/b=true)"
note "agent v3a (approved): $AID_A"
note "agent v3b (not approved): $AID_B"

# --- platform state guards (read-only) ---
run_capture gcloud access-context-manager policies list --organization="$(org_id)" --format=json
POL="$(v3h_json_last | jq -r --arg f "folders/$(folder_id root)" '[.[] | select((.scopes // []) | index($f))][0].name // empty' | sed 's#^accessPolicies/##')"
[[ -n "$POL" ]] || guard_abort "no access policy scoped to the test folder"
run_capture gcloud access-context-manager perimeters describe lzv_ai --policy="$POL" --format=json
PERIM="$(v3h_json_last)"
IN_STATUS="$(jq -r --arg p "projects/$RT_NUM" '[(.status.resources // [])[] | select(. == $p)] | length' <<<"$PERIM")"
[[ "$IN_STATUS" =~ ^[01]$ ]] || guard_abort "cannot read perimeter state"
run_capture gcloud iam policies list --attachment-point="cloudresourcemanager.googleapis.com/projects/$RT" --kind=denypolicies --format=json --billing-project="$(quota_project)"
NDENY="$(v3h_json_last | jq 'length' 2>/dev/null || echo '?')"
[[ "$NDENY" =~ ^[0-9]+$ ]] || NDENY=0
v3h_engine_env "$AID_B"
HAS_PROXY="$(jq -r 'has("HTTPS_PROXY") | if . then 1 else 0 end' <<<"$V3H_ENV_JSON")"
ENV_READ="$(jq -r 'length' <<<"$V3H_ENV_JSON")"
note "platform state: perimeter status=$IN_STATUS, project deny policies=$NDENY, engine HTTPS_PROXY set=$HAS_PROXY (env fields read=$ENV_READ)"
case "$STAGE" in
on)
  [[ "$IN_STATUS" == 1 && "$NDENY" -ge 1 ]] || guard_abort "stage on needs the runtime project in the enforced perimeter and a project deny policy"
  [[ "$ENV_READ" == 0 || "$HAS_PROXY" == 1 ]] || guard_abort "stage on needs the agents attached to PSC-I with HTTPS_PROXY set"
  KB_MODE=platform ;;
off)
  [[ "$IN_STATUS" == 0 && "$NDENY" == 0 ]] || guard_abort "stage off needs the project out of the enforced perimeter and no project deny policy"
  [[ "$ENV_READ" == 0 || "$HAS_PROXY" == 0 ]] || guard_abort "stage off needs agents without HTTPS_PROXY (agent_v3_use_psci=false)"
  KB_MODE=allowed
  [[ "$(read_stage on)" != MISSING ]] || guard_abort "run stage on first (same RUN_ID)" ;;
esac

VERDICTS=()
cell() {  # cell NAME AGENT COMMAND KIND
  v3h_cell "$STAGE:$1" "$2" "$3" "$4"
  VERDICTS+=("$CELL_V")
}

# controls first
cell ctl-a-approved "$AID_A" "ACTION=a MODE=guarded" allowed
cell ctl-b-allowed-host "$AID_B" "ACTION=b MODE=guarded TARGET=allowed" allowed
cell ctl-c-src-bucket "$AID_B" "ACTION=c MODE=guarded DEST=src" allowed
# guarded: the ADK callback refuses in both stages
cell a-guarded "$AID_B" "ACTION=a MODE=guarded" adk
cell b-guarded "$AID_B" "ACTION=b MODE=guarded TARGET=denied" adk
cell c-guarded "$AID_B" "ACTION=c MODE=guarded DEST=out" adk
# bypass: the platform refuses when on, nothing refuses when off
cell a-bypass "$AID_B" "ACTION=a MODE=bypass" "$KB_MODE"
cell b-bypass-proxy "$AID_B" "ACTION=b MODE=bypass VARIANT=proxy TARGET=denied" "$KB_MODE"
cell b-bypass-direct "$AID_B" "ACTION=b MODE=bypass VARIANT=direct TARGET=denied" "$KB_MODE"
cell c-bypass "$AID_B" "ACTION=c MODE=bypass DEST=out" "$KB_MODE"

V="$(verdict_merge "${VERDICTS[@]}")"
SUMMARY="$(jq -rs --arg s "$STAGE:" '[.[] | select(.cell | startswith($s)) | "\(.cell | sub($s; ""))=\(.refused_by)/\(.status)"] | join(", ")' "$LZV_DIR/cells.jsonl")"
NOTES="$(jq -rs --arg s "$STAGE:" '[.[] | select((.cell | startswith($s)) and .verdict != "PASS") | "\(.cell | sub($s; "")): \(.verdict) \(.why)"] | join("; ")' "$LZV_DIR/cells.jsonl")"
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
