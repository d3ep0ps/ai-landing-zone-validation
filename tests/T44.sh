#!/usr/bin/env bash
# T44 (v3 B5): same artifact, different egress, decided by deploy order vs the perimeter. Plan:
# plans/v3-harness-boundary-tests.md T44. Agents v3a and v3b come from ONE tarball (infra/agents agent_v3,
# tests/fixtures/agent_v3/build.sh); the sha256 of the tarball is recorded. Order and human steps
# (see tests/RUN-ORDER-v3h.md):
#   pre        perimeter in DRY-RUN for the runtime project (spec yes, status no); agent A (lzv-v3-a) deployed, B not
#   (human: enforce the perimeter WITHOUT an agent ingress rule, wait 15 minutes, deploy B)
#   noingress  A and B calls with the perimeter enforced and no agent identity in an ingress rule
#   (human: set vpc_sc_agent_ingress_identities = [A, B] as in T23, apply, wait 15 minutes)
#   ingress    same calls with the ingress rule; writes the result
# "Fixed-argument tool" = ACTION=b MODE=bypass TARGET=denied (the harness callback would refuse the non-allowed host
# before the network is tried, which would hide the egress difference); the model call is ACTION=model MODE=bypass.
# Expected per the plan; the cells the plan does not state (A tool call, B model call without ingress rule) are
# recorded as observed. Falsified if: A and B behave the same.
# v2 from v3h run 3 (plan section 3b, pre-registered 2026-11-12; runs 1-2 are exploratory): A's session refusal moved to
# T44b and no longer decides T44; the ingress stage needs V3H_WAITED_15MIN=yes (>= 15 min after the ingress apply).
# Verdict on example.com (non-Google); the Google-hosted run.app host is reported as its own row.
# shellcheck disable=SC2016
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=lib-v3h.sh
source "$(dirname "$0")/lib-v3h.sh"
require_config

STAGE="${1:-}"
case "$STAGE" in pre|noingress|ingress) ;; *) lzv_die "usage: T44.sh pre|noingress|ingress" ;; esac

LZV_SCOPE="folders/$(folder_id root)"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/vpc-service-controls/docs/supported-identities"
  "https://docs.cloud.google.com/vpc-service-controls/docs/ingress-egress-rules"
  "https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale/runtime/agent-identity"
)
header T44 "B5 (Enforced)" "Identical artifact deployed before (A) and after (B) perimeter enforcement; control: baseline calls in dry-run, then same calls with the agent ingress rule" \
  "T44 v2 (from v3h run 3; runs 1-2 exploratory). pre (dry-run): A model 200, A example.com 200, A run.app 200. noingress: B example.com refused (no route / timeout / proxy refusal), B model 200. ingress (>= 15 min after the ingress apply): A example.com 200, B example.com refused. Google-hosted host, own row, not in the verdict: B run.app 200 in both stages. Falsified if: at ingress A and B behave the same on example.com. INCONCLUSIVE if: the pre baseline is not clean, or A cannot create a session at +15 min (T44b decides). Tier: Enforced. 3 runs unchanged." \
  "$STAGE"
note "plan claim B5; no resources are created by this script (agents, perimeter and ingress rule are Terraform-managed); no cleanup_trap registered"

RT="$(project_id runtime)"; RT_NUM="$(project_number runtime)"
LZV_SCOPE="projects/$RT"
AID_A="$(agents_tf '.agent_v3.value.a.id' 2>/dev/null)" || AID_A=""
AID_B="$(agents_tf '.agent_v3.value.b.id' 2>/dev/null)" || AID_B=""
PRIN_A="$(agents_tf '.agent_v3.value.a.identity' 2>/dev/null)" || PRIN_A=""
PRIN_B="$(agents_tf '.agent_v3.value.b.identity' 2>/dev/null)" || PRIN_B=""
[[ -n "$AID_A" ]] || guard_abort "deploy agent v3a first (infra/agents deploy_agent_v3a=true)"
TARBALL="$LZV_ROOT/infra/agents/build/source-v3.tar.gz"
[[ -f "$TARBALL" ]] || guard_abort "artifact $TARBALL not found (run tests/fixtures/agent_v3/build.sh)"
SHA="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
note "artifact sha256: $SHA (both agents are deployed from this file; compare with the build log)"
note "agent A: $AID_A; identity ${PRIN_A:-unknown}"
note "agent B: ${AID_B:-not deployed}; identity ${PRIN_B:-unknown}"

# perimeter state (read-only), as in T23
run_capture gcloud access-context-manager policies list --organization="$(org_id)" --format=json
POL="$(v3h_json_last | jq -r --arg f "folders/$(folder_id root)" '[.[] | select((.scopes // []) | index($f))][0].name // empty' | sed 's#^accessPolicies/##')"
[[ -n "$POL" ]] || guard_abort "no access policy scoped to the test folder"
run_capture gcloud access-context-manager perimeters describe lzv_ai --policy="$POL" --format=json
PERIM="$(v3h_json_last)"
IN_SPEC="$(jq -r --arg p "projects/$RT_NUM" '[(.spec.resources // [])[] | select(. == $p)] | length' <<<"$PERIM")"
IN_STATUS="$(jq -r --arg p "projects/$RT_NUM" '[(.status.resources // [])[] | select(. == $p)] | length' <<<"$PERIM")"
[[ "$IN_SPEC" =~ ^[01]$ && "$IN_STATUS" =~ ^[01]$ ]] || guard_abort "cannot read perimeter state"
ING_A=0; ING_B=0
[[ -n "$PRIN_A" ]] && jq -e --arg p "$PRIN_A" '[(.status.ingressPolicies // [])[] | (.ingressFrom.identities // [])[] | select(. == $p)] | length > 0' <<<"$PERIM" >/dev/null && ING_A=1
[[ -n "$PRIN_B" ]] && jq -e --arg p "$PRIN_B" '[(.status.ingressPolicies // [])[] | (.ingressFrom.identities // [])[] | select(. == $p)] | length > 0' <<<"$PERIM" >/dev/null && ING_B=1
note "perimeter lzv_ai: runtime in spec=$IN_SPEC status=$IN_STATUS; agent A in ingress=$ING_A, B in ingress=$ING_B"

violations() {  # latest VPC-SC audit entries (read-only), recorded as evidence
  run_capture gcloud logging read 'protoPayload.metadata."@type"="type.googleapis.com/google.cloud.audit.VpcServiceControlAuditMetadata"' \
    --project="$RT" --freshness=30m --limit=10 --format=json
  note "VPC-SC audit entries: $(v3h_json_last | jq -r '[.[] | "\(.protoPayload.metadata.violationReason // "?") caller=\(.protoPayload.authenticationInfo.principalSubject // .protoPayload.authenticationInfo.principalEmail // "?") method=\(.protoPayload.methodName // "?")"] | unique | join("; ")' 2>/dev/null | cut -c1-600)"
}
T_DENIED="ACTION=b MODE=bypass TARGET=denied"
T_NET="ACTION=b MODE=bypass TARGET=internet"  # added before run 2: egress verdict cell (example.com)
T_MODEL="ACTION=model MODE=bypass"

case "$STAGE" in
pre)
  [[ "$IN_SPEC" == 1 && "$IN_STATUS" == 0 ]] || guard_abort "stage pre needs the runtime project in the perimeter spec only (dry-run)"
  [[ -z "$AID_B" ]] || guard_abort "stage pre needs agent B not deployed (B is deployed after enforcement)"
  v3h_query "$AID_A" "$T_MODEL"; MA="$Q_STATUS"
  v3h_query "$AID_A" "$T_DENIED"; TA="$Q_STATUS"
  v3h_query "$AID_A" "$T_NET"; NA="$Q_STATUS"
  note "baseline in dry-run: A model status=$MA, A run.app status=$TA, A internet status=$NA (dry-run logs violations, does not block)"
  if [[ "$MA" == 200 && "$NA" == 200 ]]; then write_stage PASS "pre: A model 200, A internet 200 in dry-run (run.app $TA)"
  else write_stage INCONCLUSIVE "pre: baseline not clean (A model=$MA, A internet=$NA, A run.app=$TA)"; fi
  ;;
noingress)
  [[ "$IN_STATUS" == 1 ]] || guard_abort "stage noingress needs the runtime project in the enforced perimeter (status)"
  [[ -n "$AID_B" ]] || guard_abort "stage noingress needs agent B deployed after enforcement"
  [[ "$ING_A" == 0 && "$ING_B" == 0 ]] || guard_abort "stage noingress needs no agent identity in an ingress rule"
  v3h_query "$AID_A" "$T_MODEL"; MA="$Q_STATUS"; MAB="$Q_BY"
  v3h_query "$AID_A" "$T_DENIED"; TA="$Q_STATUS"; TAB="$Q_BY"
  v3h_query "$AID_B" "$T_DENIED"; RB="$Q_STATUS"; RBB="$Q_BY"
  v3h_query "$AID_B" "$T_NET"; TB="$Q_STATUS"; TBB="$Q_BY"
  v3h_query "$AID_B" "$T_MODEL"; MB="$Q_STATUS"; MBB="$Q_BY"
  violations
  note "no ingress rule: A model=$MA ($MAB) A run.app=$TA ($TAB) | B internet=$TB ($TBB) B run.app=$RB ($RBB, observed) B model=$MB ($MBB)"
  V=PASS; W=""
  # v2: A's session refusal is T44b's subject; recorded here only.
  if [[ "$TB" == 200 && "$TBB" == none ]]; then V=FAIL; W+="${W:+; }B reached the internet host (expected: no internet)"
  elif [[ "$TBB" == none ]]; then [[ "$V" == FAIL ]] || V=INCONCLUSIVE; W+="${W:+; }no clear result for B's tool call (status=$TB)"; fi
  write_stage "$V" "noingress: A model=$MA/$MAB, A run.app=$TA/$TAB; B internet=$TB/$TBB, B run.app=$RB/$RBB, B model=$MB/$MBB${W:+; $W}"
  ;;
ingress)
  [[ "$IN_STATUS" == 1 && "$ING_A" == 1 && "$ING_B" == 1 ]] || guard_abort "stage ingress needs the enforced perimeter with both agent identities in an ingress rule (wait 15 minutes)"
  [[ "${V3H_WAITED_15MIN:-}" == yes ]] || guard_abort "T44 v2: the ingress stage runs >= 15 min after the ingress apply (set V3H_WAITED_15MIN=yes)"
  [[ -n "$AID_B" ]] || guard_abort "agent B is not deployed"
  sn="$(read_stage noingress)"; [[ "$sn" == MISSING ]] && sn=INCONCLUSIVE
  sp="$(read_stage pre)"; [[ "$sp" == MISSING ]] && sp=INCONCLUSIVE
  v3h_query "$AID_A" "$T_DENIED"; RA="$Q_STATUS"; RAB="$Q_BY"
  v3h_query "$AID_A" "$T_NET"; TA="$Q_STATUS"; TAB="$Q_BY"
  v3h_query "$AID_A" "$T_MODEL"; MA="$Q_STATUS"; MAB="$Q_BY"
  v3h_query "$AID_B" "$T_DENIED"; RB="$Q_STATUS"; RBB="$Q_BY"
  v3h_query "$AID_B" "$T_NET"; TB="$Q_STATUS"; TBB="$Q_BY"
  v3h_query "$AID_B" "$T_MODEL"; MB="$Q_STATUS"; MBB="$Q_BY"
  violations
  note "with ingress rule: A internet=$TA ($TAB) A run.app=$RA ($RAB, observed) A model=$MA ($MAB) | B internet=$TB ($TBB) B run.app=$RB ($RBB, observed) B model=$MB ($MBB)"
  V=PASS; W=""
  A_RUNS=1; [[ "$TAB" == vpc_sc_runtime || "$TA" == none ]] && A_RUNS=0
  B_NET=refused; [[ "$TB" == 200 && "$TBB" == none ]] && B_NET=reached
  [[ "$TBB" == none && "$TB" != 200 ]] && B_NET=unclear
  if [[ "$B_NET" == reached ]]; then V=FAIL; W="B reached example.com with the perimeter enforced (expected: refused)"
  elif [[ "$B_NET" == unclear ]]; then V=INCONCLUSIVE; W="no clear result for B's example.com call (status=$TB)"
  elif [[ "$A_RUNS" == 0 ]]; then V=INCONCLUSIVE; W="A cannot create a session at +15 min with the ingress rule (T44b decides): by=$TAB status=$TA"
  elif [[ "$TA" == 200 && "$TAB" == none ]]; then :
  else V=FAIL; W="A and B both refused on example.com (A by=$TAB status=$TA): deploy order made no egress difference"; fi
  GH="as expected"; [[ "$RB" == 200 && "$RBB" == none ]] || GH="not as expected (B run.app=$RB/$RBB)"
  note "Google-hosted row (not in the verdict): B run.app with the perimeter enforced: $GH"
  [[ "$MB" == 200 ]] || note "B's own model call with the ingress rule: status=$MB by=$MBB (recorded; plan does not pre-register it)"
  write_stage "$V" "ingress: A internet=$TA/$TAB, A run.app=$RA/$RAB, A model=$MA/$MAB; B internet=$TB/$TBB, B run.app=$RB/$RBB, B model=$MB/$MBB${W:+; $W}"
  FINAL="$(verdict_merge "$sp" "$sn" "$V")"
  WHY=""
  [[ "$sp" == PASS ]] || WHY+="stage pre: $sp; "
  [[ "$sn" == PASS ]] || WHY+="stage noingress: $sn ($(jq -r '.note // empty' "$LZV_DIR/stages/noingress.json" 2>/dev/null)); "
  [[ "$V" == PASS ]] || WHY+="stage ingress: $W; "
  [[ "$FINAL" == PASS ]] && WHY=""
  write_result "$FINAL" Enforced "artifact sha256 ${SHA:0:12}...; noingress: $(jq -r '.note // empty' "$LZV_DIR/stages/noingress.json" 2>/dev/null); ingress: A internet=$TA, A run.app=$RA, A model=$MA; B internet=$TB, B run.app=$RB, B model=$MB" "$WHY"
  ;;
esac
