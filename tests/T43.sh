#!/usr/bin/env bash
# T43 (v3 B4): the platform grant survives deleting all agents. Plan: plans/v3-harness-boundary-tests.md T43.
# Same per-run project as T40/T41 (infra-v3h). Stages and human steps:
#   t0      right after the human deleted agents 1 and 2 (deploy_agent_1=false, deploy_agent_2=false, apply). Records the clock.
#   p15     at least 15 minutes after t0
#   p24h    at least 24 hours after t0 (closes the run next day; keep the project)
#   agent3  after the human set deploy_agent_3=true and applied (and V3H_WAITED_5MIN=yes after 5 minutes): IAM diff against p24h
# The result is written by agent3. Falsified if: the binding disappears.
# Destroy agents immediately; keep only the project for the +24 h check. The script deletes nothing.
# shellcheck disable=SC2016
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=lib-v3h.sh
source "$(dirname "$0")/lib-v3h.sh"
require_config

STAGE="${1:-}"
case "$STAGE" in t0|p15|p24h|agent3) ;; *) lzv_die "usage: T43.sh t0|p15|p24h|agent3" ;; esac

LZV_SCOPE="folders/$(folder_id root)"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale/runtime/agent-identity"
)
header T43 "B4 (Configured, read-back)" "Platform grant after deleting all agents, then after a new deploy; control: binding present before the delete (T40)" \
  "binding still present at both checks (+15 min and +24 h); agent 3's deploy adds nothing. Falsified if: the binding disappears." \
  "$STAGE"
note "plan claim B4; no resources are created or deleted by this script; no cleanup_trap registered"

v3h_init
LZV_SCOPE="projects/$V3H_PID"
ROLE="roles/aiplatform.agentDefaultAccess"
note "per-run project: $V3H_PID (label $V3H_LABEL)"

check_present() {  # check_present SNAPSHOT -> sets PRESENT 1/0
  PRESENT=0; v3h_has_binding "$1" "$ROLE" "$V3H_PSET" && PRESENT=1
  note "snapshot $1: platform binding present=$PRESENT"
}
need_age() {  # need_age STAGE SECONDS
  local ts age; ts="$(stage_ts t0)"
  [[ -n "$ts" ]] || guard_abort "run stage t0 first (same RUN_ID)"
  age="$(v3h_age_s "$ts")"
  (( age >= $2 )) || guard_abort "stage $1 needs $2 s since t0; only $age s have passed"
  note "stage $1: $age s since t0 (t0 at $ts)"
}

case "$STAGE" in
t0)
  [[ "$(v3h_agent_count)" == 0 ]] || guard_abort "stage t0 needs all agents deleted (agents output must be empty)"
  v3h_snapshot t0 || { write_stage INCONCLUSIVE "t0: snapshot failed"; exit 0; }
  check_present t0
  if [[ "$PRESENT" == 1 ]]; then write_stage PASS "t0: all agents deleted, binding present"
  else write_stage FAIL "t0: binding already gone right after deleting the agents"; fi
  ;;
p15)
  need_age p15 900
  [[ "$(v3h_agent_count)" == 0 ]] || guard_abort "agents are deployed again; not the T43 state"
  v3h_snapshot p15 || { write_stage INCONCLUSIVE "p15: snapshot failed"; exit 0; }
  check_present p15
  if [[ "$PRESENT" == 1 ]]; then write_stage PASS "p15: binding present at +15 min"
  else write_stage FAIL "p15: binding disappeared by +15 min"; fi
  ;;
p24h)
  need_age p24h 86400
  [[ "$(v3h_agent_count)" == 0 ]] || guard_abort "agents are deployed again; not the T43 state"
  v3h_snapshot p24h || { write_stage INCONCLUSIVE "p24h: snapshot failed"; exit 0; }
  check_present p24h
  if [[ "$PRESENT" == 1 ]]; then write_stage PASS "p24h: binding present at +24 h"
  else write_stage FAIL "p24h: binding disappeared by +24 h"; fi
  ;;
agent3)
  [[ "${V3H_WAITED_5MIN:-}" == yes ]] || guard_abort "wait 5 minutes after the deploy, then export V3H_WAITED_5MIN=yes"
  [[ -n "$(v3h_agent 3 id)" && -z "$(v3h_agent 1 id)" && -z "$(v3h_agent 2 id)" ]] || guard_abort "stage agent3 needs agent 3 deployed and agents 1, 2 absent"
  [[ -d "$LZV_DIR/iam-p24h" ]] || guard_abort "run stage p24h first"
  s0="$(read_stage t0)"; s15="$(read_stage p15)"; s24="$(read_stage p24h)"
  s0="${s0/MISSING/INCONCLUSIVE}"; s15="${s15/MISSING/INCONCLUSIVE}"; s24="${s24/MISSING/INCONCLUSIVE}"
  v3h_snapshot agent3 || { write_stage INCONCLUSIVE "agent3: snapshot failed"; write_result INCONCLUSIVE Configured "snapshot failed" "IAM read failed"; exit 0; }
  DIFF_LINES="$(iam_diff p24h agent3)"
  v3h_judge_diff "$DIFF_LINES"
  check_present agent3
  ADDED_ANY="$J_ADDED"; REMOVED_ANY="$J_REMOVED"
  if [[ "$ADDED_ANY" == 0 && -z "$REMOVED_ANY" && "$PRESENT" == 1 ]]; then V3=PASS; W3=""
  elif [[ "$PRESENT" == 0 ]]; then V3=FAIL; W3="binding absent after agent 3's deploy"
  else V3=FAIL; W3="agent 3's deploy changed IAM: added=$ADDED_ANY [${J_EXTRA:-}] removed=[${REMOVED_ANY:-none}]"; fi
  write_stage "$V3" "agent3: added=$ADDED_ANY removed=[${REMOVED_ANY:-none}] binding present=$PRESENT"
  FINAL="$(verdict_merge "$s0" "$s15" "$s24" "$V3")"
  WHY=""
  for p in t0 p15 p24h; do
    sv="$(read_stage "$p")"
    [[ "$sv" == PASS ]] || WHY+="stage $p: $sv ($(jq -r '.note // empty' "$LZV_DIR/stages/$p.json" 2>/dev/null)); "
  done
  [[ "$V3" == PASS ]] || WHY+="agent3: $W3; "
  [[ "$FINAL" == PASS ]] && WHY=""
  write_result "$FINAL" Configured "t0=$s0 p15=$s15 p24h=$s24; agent 3 deploy: added=$ADDED_ANY removed=[${REMOVED_ANY:-none}]" "$WHY"
  ;;
esac
