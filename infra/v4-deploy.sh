#!/usr/bin/env bash
# v4 deploy: outside CMEK key + outputs, then agents A, B, O (one deploy per 30 minutes, E4.3).
# Run from infra/:  ./v4-deploy.sh [all|base|a|b|o|output]
#   all    = base, a, wait, b, wait, o, output (default)
#   base|a|b|o = one step only (to resume after a stop); output = print tester_inputs
#   folderdeny-off | check | folderdeny-on = T18 window: lift the folder deny policy, query A and B,
#   restore it (exception = agent A)
#   kmsgrant = T13: data project storage agent on the outside key
#   enforce-noingress = T13 step 1 (enforced, no ingress); enforce-ingress = step 2 (operator + agents ingress)
#   dryrun | enforce = T13: perimeter lzv_ai to dry-run / back to enforced (perimeter only)
# Every apply shows the plan summary and asks y/N first.
set -euo pipefail

WAIT_SECONDS=1800
BASE_VARS=(-var-file=terraform.tfvars -var-file=profiles/lz-5-reference.tfvars)
STEP="${1:-all}"

cd "$(dirname "$0")"
SCRATCH="$(cd .. && pwd)/scratch"
[[ -f v4-outside-cmek.tf && -d agents ]] || { echo "run from infra/"; exit 1; }
mkdir -p "$SCRATCH"

check_env() {
  local cfg acct
  cfg="$(gcloud config configurations list --filter=is_active=true --format='value(name)')"
  acct="$(gcloud config get-value account 2>/dev/null)"
  [[ "$cfg" == "lz-validation" ]] || { echo "STOP: active gcloud config is '$cfg', not lz-validation"; exit 1; }
  [[ "$acct" == "USER_1@example.com" ]] || { echo "STOP: account is '$acct'"; exit 1; }
  gcloud auth application-default print-access-token >/dev/null 2>&1 \
    || { echo "STOP: ADC expired, run: gcloud auth application-default login"; exit 1; }
  echo "env ok: $cfg / $acct"
}

# plan_apply <dir> <plan-file> <args...>: plan, show summary, confirm, apply.
plan_apply() {
  local dir="$1" plan="$2"; shift 2
  local log="$SCRATCH/v4-${plan%.tfplan}"
  ( cd "$dir" && terraform plan -no-color "$@" -out="$plan" >"$log-plan.txt" 2>&1 ) \
    || { echo "plan failed, see $log-plan.txt"; tail -n 20 "$log-plan.txt"; exit 1; }
  grep -E '^  # |^Plan:|No changes' "$log-plan.txt" || true
  if grep -q 'No changes' "$log-plan.txt"; then echo "nothing to apply"; return 0; fi
  if grep -Eq 'will be destroyed|must be replaced' "$log-plan.txt"; then
    echo "WARNING: plan destroys or replaces resources, read $log-plan.txt"
  fi
  read -r -p "apply $dir/$plan? [y/N] " ok
  [[ "$ok" == y || "$ok" == Y ]] || { echo "skipped"; exit 1; }
  ( cd "$dir" && terraform apply -no-color "$plan" >"$log-apply.txt" 2>&1 ) \
    || { echo "apply failed, see $log-apply.txt"; tail -n 20 "$log-apply.txt"; exit 1; }
  grep -E 'Apply complete' "$log-apply.txt"
}

wait_pacing() {
  echo "waiting $((WAIT_SECONDS / 60)) min before the next agent deploy (Ctrl-C is safe; resume with the next step name)"
  local left=$WAIT_SECONDS
  while (( left > 0 )); do printf '\r  %2d min left ' $((left / 60)); sleep 60; left=$((left - 60)); done
  echo
}

# Agent toggles are cumulative: each plan keeps the agents already deployed.
step_base() { plan_apply . plan-v4-outside-cmek.tfplan "${BASE_VARS[@]}"; }
step_a() { plan_apply agents plan-v4-agent-a.tfplan -var deploy_agent_a=true; }
step_b() { plan_apply agents plan-v4-agent-b.tfplan -var deploy_agent_a=true -var deploy_agent_b=true; }
step_o() { plan_apply agents plan-v4-agent-o.tfplan -var deploy_agent_a=true -var deploy_agent_b=true -var deploy_agent_o=true; }
step_output() { ( cd agents && terraform output -json tester_inputs ); }

# T18 window: the folder deny policy (T37, lzv-v2-deny-agent-predict) blocks every org agent.
# off = plan with enable_v2_folder_deny=false (1 destroy); on = profile value (true, exception = agent A
# from dc1_approved_agent_principals). Deny changes take 2-7 minutes to apply.
step_folderdeny_off() { plan_apply . plan-v4-folderdeny-off.tfplan "${BASE_VARS[@]}" -var enable_v2_folder_deny=false; }
step_folderdeny_on() { plan_apply . plan-v4-folderdeny-on.tfplan "${BASE_VARS[@]}"; }

# T13: perimeter lzv_ai to dry-run (status removed, spec kept) or back to enforced. Targets the
# perimeter only, so the folder deny state is not touched. Wait ~15 min after each (propagation).
step_dryrun() { plan_apply . plan-v4-dryrun.tfplan "${BASE_VARS[@]}" -var vpc_sc_enforced=false -target=module.vpc_sc; }
# T13 pause 1: enforced with no ingress rules (operator + agent ingress off; pipeline egress kept so
# Terraform can still reach its seed quota project). Pause 2 (add ingress) = step_enforce.
step_enforce_noingress() { plan_apply . plan-v4-enforce-noingress.tfplan "${BASE_VARS[@]}" -var vpc_sc_operator_ingress=false -var 'vpc_sc_agent_ingress_identities=[]' -target=module.vpc_sc; }
# T13 pause 2: enforced with two ingress rules: operator + agents (A and B principals, Vertex AI on the
# runtime project), as in the reference run (C16).
AGENT_INGRESS='vpc_sc_agent_ingress_identities=["principal://agents.global.org-ORG_ID.system.id.goog/resources/aiplatform/projects/PROJECT_NUMBER_7/locations/europe-west1/reasoningEngines/AGENT_ID_79","principal://agents.global.org-ORG_ID.system.id.goog/resources/aiplatform/projects/PROJECT_NUMBER_7/locations/europe-west1/reasoningEngines/AGENT_ID_80"]'
step_enforce_ingress() { plan_apply . plan-v4-enforce-ingress.tfplan "${BASE_VARS[@]}" -var "$AGENT_INGRESS" -target=module.vpc_sc; }
step_enforce() { plan_apply . plan-v4-enforce.tfplan "${BASE_VARS[@]}" -target=module.vpc_sc; }

# T13: grant the data project's storage agent on the outside key (key only; perimeter untouched).
step_kmsgrant() { plan_apply . plan-v4-kmsgrant.tfplan "${BASE_VARS[@]}" -target=module.outside_kms; }

# check: one query to agents A and B (same call as tests/T18.sh); prints HTTP code and verdict.
step_check() {
  local name id out code
  for name in agent_a agent_b; do
    id="$(cd agents && terraform output -json "$name" | jq -r '.id // empty')"
    [[ -n "$id" ]] || { echo "$name: not deployed"; continue; }
    out="$SCRATCH/v4-check-$name.txt"
    printf 'Authorization: Bearer %s\n' "$(gcloud auth print-access-token)" \
      | curl -sS -N --max-time 180 -H @- -H 'Content-Type: application/json' -X POST \
          "https://europe-west1-aiplatform.googleapis.com/v1/${id}:streamQuery?alt=sse" \
          -d '{"class_method":"async_stream_query","input":{"user_id":"lzv-check","message":"Reply with one short sentence: hello."}}' \
          -w '\nHTTP %{http_code}\n' >"$out" 2>&1 || true
    code="$(tail -n 1 "$out")"
    if grep -q 'PERMISSION_DENIED' "$out"; then echo "$name: $code DENIED ($(grep -m1 -o 'due to an IAM deny policy' "$out" || echo 'see log'))"
    elif sed 's/^data: *//' "$out" | jq -R 'fromjson? | .. | objects | select(has("text")) | .text | select(type == "string" and length > 0)' 2>/dev/null | grep -q .; then echo "$name: $code ANSWERED"
    else echo "$name: $code no answer, see $out"; fi
  done
}

check_env
case "$STEP" in
  all) step_base; step_a; wait_pacing; check_env; step_b; wait_pacing; check_env; step_o; step_output ;;
  base) step_base ;;
  a) step_a ;;
  b) step_b ;;
  o) step_o ;;
  output) step_output ;;
  folderdeny-off) step_folderdeny_off ;;
  folderdeny-on) step_folderdeny_on ;;
  check) step_check ;;
  dryrun) step_dryrun ;;
  enforce) step_enforce ;;
  kmsgrant) step_kmsgrant ;;
  enforce-noingress) step_enforce_noingress ;;
  enforce-ingress) step_enforce_ingress ;;
  *) echo "usage: $0 [all|base|a|b|o|output|folderdeny-off|check|folderdeny-on|dryrun|enforce-noingress|enforce-ingress|enforce|kmsgrant]"; exit 1 ;;
esac
