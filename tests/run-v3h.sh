#!/usr/bin/env bash
# v3h orchestrator (plans/v3h-automation.md, approved 2026-11-11). One command per run; the test scripts
# (tests/T4*.sh) are unchanged in how they judge; this script only sequences infra changes and test stages.
#
#   tests/run-v3h.sh run N        full run N (2 -> data project, 3 -> outside project)
#   tests/run-v3h.sh close N      T43 p24h + agent3 for run N (>= 24 h after its t0); for N=1 also T40b (mcp)
#   tests/run-v3h.sh teardown N   destroy paid resources of run N and return infra/ to the v3h baseline
#   tests/run-v3h.sh teardown-infra N  infra/ back to baseline only (used by the PSC-I release poll)
#   tests/run-v3h.sh status N     show finished steps
#   tests/run-v3h.sh subset N     runs 4-9 (plan 3b scheduling): block 2/3 only, with T49, T44 v2/T44b, T45d, T48b,
#                                 T50, T51, T52, T53, T55 (no per-run project, no T40-T43)
#   tests/run-v3h.sh t47r N       T47r: one attempt, block 2 only, run-6 setup (profiles/v3h-t47r.tfvars, agent G unpinned)
#   tests/run-v3h.sh t47r2 N      T47r2: as t47r with the run-6 package set; runs only if T49 shows G's token bound
#   options: --dry (print the step list, change nothing); --t47r / --t47r2 (teardown/status of such an attempt)
#
# Rules carried from CLAUDE.md: safety check before every cloud change (config lz-validation, account and
# org as PROGRESS.md); every infra change is a saved plan whose changes are checked against an allowlist
# before apply; no --quiet; no keys; tokens only in shell variables; never git push; evidence never
# overwritten (retries get a new RUN_ID suffix); paid resources destroyed by the end of the run (EXIT trap).
# Pre-registered decision rules (plans/v3h-automation.md section 3):
#   - transient platform error (HTTP 5xx / UNAVAILABLE) in T47 or T48: the test restarts once as run-N-r2;
#   - a failed control: the stage stays INCONCLUSIVE, the run continues;
#   - a guard abort, an unexpected plan change, CONSUMER_SUSPENDED or a failed safety check: stop + teardown.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT" || exit 1
CMD="${1:-}"; N="${2:-}"; shift 2 2>/dev/null || true
DRY=0; T47R=0; T47R_V=1; for a in "$@"; do [[ "$a" == --dry ]] && DRY=1; [[ "$a" == --t47r ]] && T47R=1; [[ "$a" == --t47r2 ]] && { T47R=1; T47R_V=2; }; done
[[ "$CMD" =~ ^(run|close|teardown|teardown-infra|status|subset|t47r|t47r2|t57|gw)$ && "$N" =~ ^[1-9]$ ]] || { echo "usage: $0 run|close|teardown|teardown-infra|status|subset|t47r|t47r2|t57 N [--dry] [--t47r|--t47r2]"; exit 2; }
[[ "$CMD" == t47r ]] && T47R=1
[[ "$CMD" == t47r2 ]] && { T47R=1; T47R_V=2; }
T47R_NAME=t47r; T47R_TEST=T47r; [[ "$T47R_V" == 2 ]] && { T47R_NAME=t47r2; T47R_TEST=T47r2; }

RUN_ID="run-$N"; LABEL="r$N"
case "$N" in 1) PKEY=mcp ;; 2) PKEY=data ;; 3) PKEY=outside ;; *) PKEY="" ;; esac
if [[ "$CMD" =~ ^(run|close)$ && -z "$PKEY" ]]; then echo "no project mapped for run $N (D6: r1 mcp, r2 data, r3 outside); runs 4+ use 'subset'"; exit 2; fi
if [[ "$CMD" == subset && "$N" -lt 4 ]]; then echo "subset runs are numbered 4-9 (runs 1-3 are full runs)"; exit 2; fi
PREFIX="$(sed -nE 's/^- Runtime project: *([a-z0-9]+)-prj-lzv-runtime2.*/\1/p' PROGRESS.md 2>/dev/null | head -1)"
QP="$(sed -nE 's/^- Seed\/admin project: *([^ ]+).*/\1/p' PROGRESS.md 2>/dev/null | head -1)"
[[ -n "$PREFIX" && -n "$QP" ]] || { echo "missing Runtime project prefix or Seed/admin project in PROGRESS.md"; exit 2; }
RT="$PREFIX-prj-lzv-runtime2"; PRJ="$PREFIX-prj-lzv-${PKEY:-none}"; REGION=europe-west1
WORK="$ROOT/scratch/run-v3h-$N"; STATE_F="$WORK/steps.done"; LOG="$ROOT/evidence/runs/run-v3h-$N.md"
if [[ "$T47R" == 1 ]]; then WORK="$ROOT/scratch/$T47R_NAME-$N"; STATE_F="$WORK/steps.done"; LOG="$ROOT/evidence/runs/$T47R_NAME-$N.md"; fi
if [[ "$CMD" == t57 ]]; then WORK="$ROOT/scratch/t57-$N"; STATE_F="$WORK/steps.done"; LOG="$ROOT/evidence/runs/t57-$N.md"; fi
if [[ "$CMD" == gw ]]; then RUN_ID="gw-$N"; WORK="$ROOT/scratch/gw-$N"; STATE_F="$WORK/steps.done"; LOG="$ROOT/evidence/runs/gw-$N.md"; fi
mkdir -p "$WORK"; touch "$STATE_F"
PAID=0; PAID_V3H=0; DONE=0; IN_TEARDOWN=0
# resume: block 2 infra already applied in an earlier attempt -> paid resources may be up (stop must tear down)
grep -qxE "b2-infra|v3h-s0" "$STATE_F" 2>/dev/null && PAID=1

# ---------------------------------------------------------------------------------------------- output
ts() { date -u +%H:%M:%S; }
log() { [[ "$DRY" == 1 ]] || printf -- '- %sZ %s\n' "$(date -u +%H:%M)" "$*" >>"$LOG"; printf '[run-v3h %s] %s\n' "$(ts)" "$*"; }
die() { log "STOP: $*"; exit 1; }

# ---------------------------------------------------------------------------------------------- safety
safety() {
  local cfg acct org want_acct want_org
  cfg="$(gcloud config configurations list --filter=is_active=true --format='value(name)' 2>/dev/null)"
  acct="$(gcloud config get-value account 2>/dev/null)"
  want_acct="$(sed -nE 's/^- Account: *([^ ]+).*/\1/p' PROGRESS.md | head -1)"
  want_org="$(sed -nE 's/.*ORG_ID: *([0-9]+).*/\1/p' PROGRESS.md | head -1)"
  [[ "$cfg" == lz-validation ]] || die "safety: active gcloud configuration is '$cfg', not lz-validation"
  [[ -n "$want_acct" && "$acct" == "$want_acct" ]] || die "safety: account '$acct' does not match PROGRESS.md"
  org="$(gcloud projects get-ancestors "$RT" --format=json 2>/dev/null | jq -r '.[] | select(.type=="organization") | .id')"
  [[ -n "$want_org" && "$org" == "$want_org" ]] || die "safety: organization of $RT is '$org', PROGRESS.md says '$want_org'"
  gcloud auth print-access-token >/dev/null 2>&1 || die "safety: gcloud login expired (human: ! gcloud auth login)"
  gcloud auth application-default print-access-token >/dev/null 2>&1 || die "safety: ADC expired (human: ! gcloud auth application-default login)"
}

# ---------------------------------------------------------------------------------------------- steps
step() {  # step NAME FUNCTION [ARGS...]: run once; recorded in $STATE_F
  local name="$1"; shift
  if grep -qx "$name" "$STATE_F"; then printf '[run-v3h] skip %s (done)\n' "$name"; return 0; fi
  if [[ "$DRY" == 1 ]]; then printf '[dry] %s: %s\n' "$name" "$*"; return 0; fi
  log "step $name"
  "$@" || die "step $name failed"
  echo "$name" >>"$STATE_F"
}

# ---------------------------------------------------------------------------------------------- terraform
VF_INFRA=(-var-file=terraform.tfvars -var-file=profiles/lz-5-reference.tfvars -var-file=profiles/v3h-baseline.tfvars)
VF_B2=(-var-file=profiles/v3h-block2.tfvars)
[[ "$T47R" == 1 ]] && VF_B2=(-var-file=profiles/v3h-t47r.tfvars)   # T47r: run-6 setup instead of block 2
GEN_INFRA="$WORK/infra.run.tfvars.json"; GEN_AGENTS="$WORK/agents.run.tfvars.json"
[[ -f "$GEN_INFRA" ]] || echo '{}' >"$GEN_INFRA"
[[ -f "$GEN_AGENTS" ]] || echo '{}' >"$GEN_AGENTS"
jset() { local f="$1" k="$2" v="$3"; jq --arg k "$k" --argjson v "$v" '.[$k] = $v' "$f" >"$f.tmp" && mv "$f.tmp" "$f"; }

# tf ROOT NAME ALLOW_ERE [terraform plan args...]: plan, check every change against ALLOW_ERE
# ("create|update|delete|replace ADDRESS" lines), apply. Up to two retries, 180 s apart, when the apply error matches
# RETRY_ERE (gateway config validation / ongoing gateway operation / IAM propagation; run 1 and run 2).
RETRY_ERE='Config validation failed|does not exist|PERMISSION_DENIED.*propagat|another ongoing operation'
tf() {
  local root="$1" name="$2" allow="$3"; shift 3
  local plan="$WORK/$name.tfplan" try extra=()
  [[ "$root" == infra/agents ]] && extra=(-parallelism=1)   # one agent deploy at a time
  for try in 1 2 3; do
    safety
    terraform -chdir="$root" plan -no-color -input=false "$@" -out="$plan" >"$WORK/$name.plan.txt" 2>&1 \
      || die "plan $name failed: $(grep -m1 -E '^Error' "$WORK/$name.plan.txt")"
    terraform -chdir="$root" show -json "$plan" >"$WORK/$name.plan.json" 2>/dev/null || die "show $name failed"
    jq -r '.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])
      | ((if .change.actions == ["delete","create"] or .change.actions == ["create","delete"] then "replace" else .change.actions[0] end) + " " + .address)' \
      "$WORK/$name.plan.json" >"$WORK/$name.changes.txt"
    local bad; bad="$(grep -vE "$allow" "$WORK/$name.changes.txt" || true)"
    [[ -z "$bad" ]] || die "plan $name has unexpected changes (not applied): $(head -5 <<<"$bad" | tr '\n' ';')"
    log "plan $name: $(wc -l <"$WORK/$name.changes.txt" | tr -d ' ') changes ($(cut -d' ' -f1 "$WORK/$name.changes.txt" | sort | uniq -c | awk '{printf "%s %s ", $1, $2}'))"
    [[ -s "$WORK/$name.changes.txt" ]] || return 0
    # infra-v3h keeps per-run state in state/rN.tfstate: apply must name it too
    local st=(); for a in "$@"; do [[ "$a" == -state=* ]] && st=("$a"); done
    if terraform -chdir="$root" apply -no-color -input=false "${extra[@]}" "${st[@]}" "$plan" >"$WORK/$name.apply.txt" 2>&1; then
      log "apply $name: $(grep -E 'Apply complete' "$WORK/$name.apply.txt" | tail -1)"; return 0
    fi
    grep -q 'CONSUMER_SUSPENDED' "$WORK/$name.apply.txt" && die "CONSUMER_SUSPENDED during $name"
    if (( try < 3 )) && grep -qE "$RETRY_ERE" "$WORK/$name.apply.txt"; then
      log "apply $name failed with a known propagation error; retry $try of 2 in 180 s ($(grep -m1 -E '^Error' "$WORK/$name.apply.txt" | cut -c1-160))"
      sleep 180; name="$name-retry"; plan="$WORK/$name.tfplan"; continue
    fi
    die "apply $name failed: $(grep -m1 -E '^Error' "$WORK/$name.apply.txt" | cut -c1-200)"
  done
}
tf_infra() { local name="$1" allow="$2"; shift 2; tf infra "$name" "$allow" "${VF_INFRA[@]}" "$@"; }
tf_infra_run() { local name="$1" allow="$2"; shift 2; tf infra "$name" "$allow" "${VF_INFRA[@]}" "${VF_B2[@]}" -var-file="$GEN_INFRA" "$@"; }
tf_agents() { local name="$1" allow="$2"; shift 2; tf infra/agents "$name" "$allow" -var-file=terraform.tfvars -var-file="$GEN_AGENTS" "$@"; }
tf_v3h() { local name="$1" allow="$2"; shift 2; tf infra-v3h "$name" "$allow" -var "run=$LABEL" -state="state/$LABEL.tfstate" "$@"; }
out_infra() { terraform -chdir=infra output -json "$1" 2>/dev/null; }
out_agents() { terraform -chdir=infra/agents output -json "$1" 2>/dev/null; }

v3h_tfvars() {  # set infra-v3h/terraform.tfvars keys (the test scripts plan with this file)
  python3 - "$@" <<'EOF'
import re, sys
p = "infra-v3h/terraform.tfvars"; s = open(p).read()
for kv in sys.argv[1:]:
    k, v = kv.split("=", 1)
    line = f"{k} = {v}"
    s, n = re.subn(rf"(?m)^{k}\s*=.*$", line, s)
    if n == 0: s = s.rstrip("\n") + "\n" + line + "\n"
open(p, "w").write(s)
EOF
}

# ---------------------------------------------------------------------------------------------- waits
wait_until() { local t="$1" why="$2" now; [[ "$DRY" == 1 ]] && { printf '[dry] wait: %s\n' "$why"; return 0; }; now="$(date +%s)"; (( t > now )) || return 0; log "waiting $(( (t-now+59)/60 )) min: $why"; while (( $(date +%s) < t )); do sleep 15; done; }

# readiness: ADK async_create_session on the engine (no model call, no network from the agent)
wait_ready() {
  local id="$1" label="$2" t0 code region; t0="$(date +%s)"; region="${id#*/locations/}"; region="${region%%/*}"
  while :; do
    code="$(printf 'Authorization: Bearer %s\n' "$(gcloud auth print-access-token)" | curl -sS -o "$WORK/ready.json" -w '%{http_code}' --max-time 60 -H @- \
      -H 'Content-Type: application/json' -X POST "https://${region}-aiplatform.googleapis.com/v1/${id}:query" \
      -d '{"class_method":"async_create_session","input":{"user_id":"lzv-ready"}}' 2>/dev/null)"
    [[ "$code" == 200 ]] && { log "ready: $label after $(( $(date +%s) - t0 )) s"; return 0; }
    # Under an enforced perimeter without an ingress rule the runtime refuses the session (finding F4). Either
    # answer shows the engine is serving; the probe accepts both, so it never waits for the outcome under test.
    if [[ "$code" == 403 ]] && grep -q vpcServiceControlsUniqueIdentifier "$WORK/ready.json"; then
      log "ready: $label after $(( $(date +%s) - t0 )) s (session refused by VPC-SC; counted as serving)"; return 0; fi
    (( $(date +%s) - t0 > 600 )) && die "agent $label not ready after 10 min (last HTTP $code)"
    sleep 20
  done
}

# canary (infra/v3h-canary.tf): impersonated, token kept in a variable only
canary_probe() {  # canary_probe bucket|aiplatform -> prints 200 | vpcsc | other:<code>
  local c email bucket tok code url
  c="$(out_infra v3h_canary)"; email="$(jq -r .email <<<"$c")"; bucket="$(jq -r .bucket <<<"$c")"
  tok="$(gcloud auth print-access-token --impersonate-service-account="$email" 2>/dev/null)" || { echo "other:token"; return; }
  if [[ "$1" == bucket ]]; then url="https://storage.googleapis.com/storage/v1/b/$bucket/o?maxResults=1"
  else url="https://$REGION-aiplatform.googleapis.com/v1/projects/$RT/locations/$REGION/reasoningEngines?pageSize=1"; fi
  code="$(curl -sS -o "$WORK/canary.json" -w '%{http_code}' --max-time 30 -H "Authorization: Bearer $tok" "$url" 2>/dev/null)"
  unset tok
  if [[ "$code" == 200 ]]; then echo 200
  elif [[ "$code" == 403 ]] && grep -q vpcServiceControlsUniqueIdentifier "$WORK/canary.json"; then echo vpcsc
  else echo "other:$code"; fi
}
canary_wait() {  # enforced | open | ingress
  local want="$1" t0 r; t0="$(date +%s)"
  while :; do
    case "$want" in
      enforced) r="$(canary_probe bucket)"; [[ "$r" == vpcsc ]] && break ;;
      open)     r="$(canary_probe bucket)"; [[ "$r" == 200 ]] && break ;;
      ingress)  r="$(canary_probe aiplatform)"; [[ "$r" == 200 ]] && break ;;
    esac
    (( $(date +%s) - t0 > 1800 )) && die "canary: perimeter state '$want' not seen after 30 min (last: $r)"
    sleep 30
  done
  log "canary: perimeter '$want' live after $(( $(date +%s) - t0 )) s"
}
DENY_WAIT=600   # IAM deny propagation: fixed (no neutral canary); notes: "allow 10 minutes"

# ---------------------------------------------------------------------------------------------- tests
LAST_V=""
t_stage() {  # t_stage TEST STAGE [RUN_ID] [ENV=VAL...]
  local t="$1" s="$2" rid="${3:-$RUN_ID}"; shift 3 2>/dev/null || shift $#
  local lf="$WORK/$t-${s:-all}-$rid.log"
  env RUN_ID="$rid" "$@" bash "tests/$t.sh" ${s:+"$s"} >"$lf" 2>&1
  grep -q '^ABORT' "$lf" && die "$t ${s} aborted: $(grep -m1 '^ABORT' "$lf" | cut -c1-200)"
  LAST_V="$(grep -oE '(stage [a-z0-9]+ -> |RESULT T[0-9]+[a-z]?[0-9]?: )[A-Z_]+' "$lf" | tail -1 | grep -oE '[A-Z_]+$')"
  log "$t ${s:-} ($rid): ${LAST_V:-no verdict line} $(grep -oE 'RESULT T[0-9]+[a-z]?[0-9]?: [A-Z_]+' "$lf" | tail -1)"
}
transient() { grep -qE '"code": ?5[0-9][0-9]|HTTP 5[0-9][0-9]|UNAVAILABLE' "$1"; }
t_seq_retry() {  # t_seq_retry TEST "STAGES": one restart as run-N-r2 on a transient error
  local t="$1" stages="$2" rid="$RUN_ID" s
  for s in $stages; do
    t_stage "$t" "$s" "$rid"
    if [[ "$LAST_V" == INCONCLUSIVE && "$rid" == "$RUN_ID" ]] && transient "$WORK/$t-$s-$rid.log"; then
      log "$t $s: transient platform error; restarting $t as $RUN_ID-r2 (pre-registered rule)"
      rid="$RUN_ID-r2"; local s2; for s2 in $stages; do t_stage "$t" "$s2" "$rid"; done; return 0
    fi
  done
}

# ---------------------------------------------------------------------------------------------- pieces
ALLOW_V3H_S0='^create (google_project_iam_member\.operator|google_project_service\.existing)\['
ALLOW_B2='^(create|update) |^delete google_project_service\.v3_net\["compute\.googleapis\.com"\]$'
ALLOW_PERIM='^update module\.vpc_sc\.'
ALLOW_PERIM_DENY='^update module\.vpc_sc\.|^create google_iam_deny_policy\.dc1_agents_predict'
ALLOW_PERIM_UNDENY='^update module\.vpc_sc\.|^delete google_iam_deny_policy\.dc1_agents_predict'
ALLOW_TEARDOWN='^update module\.vpc_sc\.|^create google_project_service\.v3_net\["compute\.googleapis\.com"\]$|^delete (google_agent_registry_service|google_artifact_registry_repository\.(v2_gw|v3h_replay)|google_artifact_registry_repository_iam_member\.v3h_mcp_pull|google_cloud_run_v2_service(_iam_member)?\.v3h_|google_compute_|module\.swp|google_dns_|google_iam_project_access_policy\.v2_|google_iam_projects_policy_binding\.v2_|google_iam_deny_policy\.dc1_|google_model_armor_template\.v2_|google_network_security_|google_network_services_|google_project_iam_member\.(v2_|v3h_t52_)|google_iap_agent_registry_iam_member\.v2_|google_project_service_identity\.v2_gw_dep|google_project_service\.(swp|v2_gw|v2_gw_vpc|v3h_run|v3h_replay_ar|v3h_troubleshooter)\[|google_storage_bucket\.v3h_out|google_storage_bucket_object\.v3h_probe|google_storage_bucket_iam_member\.v3h_(src_read|src_create|out_create))'
TD_TARGETS=(-target=module.vpc_sc -target=google_iam_deny_policy.dc1_agents_predict)

build_artifacts() {
  bash tests/fixtures/agent_v3/build.sh >"$WORK/build-v3.txt" 2>&1 || return 1
  bash tests/fixtures/gateway/agent_g/build.sh >"$WORK/build-g.txt" 2>&1 || return 1
  if [[ "$CMD" == subset ]]; then
    bash tests/fixtures/agent_v3/build.sh dep >"$WORK/build-v3d.txt" 2>&1 || return 1
    log "artifacts: agent_v3 dep (T45d) sha256 $(shasum -a 256 infra/agents/build/source-v3d.tar.gz | cut -c1-16)..."
  fi
  log "artifacts: agent_v3 sha256 $(shasum -a 256 infra/agents/build/source-v3.tar.gz | cut -c1-16)..., agent_g sha256 $(shasum -a 256 infra/agents/build/source-g.tar.gz | cut -c1-16)..."
}
# engine_count: reasoning engines in the runtime project (REST; this gcloud has no 'ai reasoning-engines' group, so the
# earlier preflight count was always 0 and never checked anything; found 2026-11-12 after T47r).
engine_count() {
  curl -sS --max-time 60 -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    "https://$REGION-aiplatform.googleapis.com/v1/projects/$RT/locations/$REGION/reasoningEngines?pageSize=100" | jq -r '(.reasoningEngines // []) | length' 2>/dev/null
}
preflight() {
  safety
  local n; n="$(engine_count)"; [[ "$n" =~ ^[0-9]+$ ]] || die "preflight: cannot list reasoning engines in $RT"
  [[ "$n" == 0 ]] || die "preflight: $n reasoning engines already in $RT (teardown first)"
  command -v conftest >/dev/null || die "preflight: conftest missing (T42)"
  local sa; sa="$(gcloud projects get-iam-policy "$PRJ" --format=json | jq -r '[.bindings[] | select(.role=="roles/aiplatform.serviceAgent" or .role=="roles/aiplatform.reasoningEngineServiceAgent")] | length')"
  [[ "$sa" == 2 ]] || die "preflight: step 0a: Vertex service-agent bindings in $PRJ: $sa of 2 (infra/ v3h_vertex_service_agent_projects)"
  out_infra v3h_canary | jq -e .email >/dev/null || die "preflight: canary missing (infra/ enable_v3h_canary)"
  [[ "$(canary_probe bucket)" == 200 ]] || die "preflight: canary cannot list the build bucket with the perimeter in dry-run"
  log "preflight OK: $RT empty, step 0a bindings present in $PRJ, canary OK"
}
v3h_step0() { v3h_tfvars "run=\"$LABEL\"" "existing_project_id=\"$PRJ\"" deploy_agent_1=false deploy_agent_2=false deploy_agent_3=false t40b_authoritative=false; tf_v3h v3h-s0 "$ALLOW_V3H_S0"; }
v3h_agent() {  # v3h_agent N true|false
  v3h_tfvars "deploy_agent_$1=$2"
  if [[ "$2" == true ]]; then
    PAID_V3H=1
    tf_v3h "v3h-agent$1" "^create module\\.agent\\[\"$1\"\\]\\."
    if [[ "$CMD" == close ]]; then
      local aid; aid="$(terraform -chdir=infra-v3h output -state="state/$LABEL.tfstate" -json agents 2>/dev/null | jq -r --arg k "$1" '.[$k].id // empty')"
      [[ -n "$aid" ]] && wait_ready "$aid" "v3h-agent$1"
    fi
  else
    tf_v3h "v3h-agent$1-off" "^delete module\\.agent\\[\"$1\"\\]\\."
  fi
}
v3h_agents12_off() { v3h_tfvars deploy_agent_1=false deploy_agent_2=false; tf_v3h v3h-agents12-off '^delete module\.agent\["(1|2)"\]\.'; }
mark() { [[ "$DRY" == 1 || -s "$WORK/mark-$1" ]] || date +%s >"$WORK/mark-$1"; }   # first time only (resume keeps the original time)
mark_get() { cat "$WORK/mark-$1" 2>/dev/null || echo 0; }

b2_infra() {
  PAID=1
  jset "$GEN_INFRA" swp_enabled true; jset "$GEN_INFRA" enable_v2_psci true; jset "$GEN_INFRA" swp_allowed_host_from_targets true
  jset "$GEN_INFRA" v3h_replay_image null   # replay service after the image build
  tf_infra_run b2-infra "$ALLOW_B2"
}
b2_fixtures() {
  # Gateway MCP fixture (plan 3b, T53 v2 / T56 v2): built in the quota project (Cloud Build in the runtime project is
  # refused by gcp.restrictNonCmekServices); a failed build, deploy or a service that is not Ready stops the run.
  local mtag="$REGION-docker.pkg.dev/$QP/lzv-v3h/mcp:$RUN_ID" mdig svc rdy
  gcloud builds submit tests/fixtures/gateway/mcp --tag="$mtag" --project="$QP" --region="$REGION" \
    --default-buckets-behavior=regional-user-owned-bucket >"$WORK/gw-build.txt" 2>&1 || { log "MCP fixture build failed: $(grep -m1 ERROR "$WORK/gw-build.txt" | cut -c1-200)"; return 1; }
  mdig="$(gcloud artifacts docker images describe "$mtag" --format='value(image_summary.digest)' 2>/dev/null)"
  [[ "$mdig" == sha256:* ]] || { log "MCP fixture image digest not found"; return 1; }
  MCP_IMAGE="$REGION-docker.pkg.dev/$QP/lzv-v3h/mcp@$mdig" bash tests/fixtures/gateway/setup.sh deploy >"$WORK/gw-deploy.txt" 2>&1 || { log "MCP fixture deploy failed: $(grep -m3 'rc=\|ABORT' "$WORK/gw-deploy.txt" | tr '\n' ' ')"; return 1; }
  for svc in lzv-mcp-reg lzv-mcp-unreg; do
    rdy="$(gcloud run services describe "$svc" --project="$RT" --region="$REGION" --format=json 2>/dev/null | jq -r '[.status.conditions[]? | select(.type == "Ready") | .status][0] // "none"')"
    [[ "$rdy" == True ]] || { log "MCP fixture $svc not Ready ($rdy)"; return 1; }
  done
  log "MCP fixture image $mdig; lzv-mcp-reg and lzv-mcp-unreg Ready"
  local tag="$REGION-docker.pkg.dev/$QP/lzv-v3h/replay:$RUN_ID" dig
  gcloud builds submit tests/fixtures/replay --tag="$tag" --project="$QP" --region="$REGION" \
    --default-buckets-behavior=regional-user-owned-bucket >"$WORK/replay-build.txt" 2>&1 || return 1
  dig="$(gcloud artifacts docker images describe "$tag" --format='value(image_summary.digest)' 2>/dev/null)"
  [[ "$dig" == sha256:* ]] || return 1
  jset "$GEN_INFRA" v3h_replay_image "\"$REGION-docker.pkg.dev/$QP/lzv-v3h/replay@$dig\""
  jset "$GEN_INFRA" v3h_replay_auth false
  log "replay image $dig; gateway MCP fixtures rebuilt and deployed"
  tf_infra_run b2-replay '^create (google_cloud_run_v2_service(_iam_member)?\.v3h_replay|google_agent_registry_service\.v3h_ep_replay)'
  mark replay-reg   # T49: registry entry for the replay host (about 4 min to take effect in run 9)
}
b2_agents() {
  local url; url="$(out_infra v3h_replay_url | jq -r '. // empty')"
  [[ "$url" == https://* ]] || return 1
  jset "$GEN_AGENTS" agent_v3_replay_url "\"$url\""
  jset "$GEN_AGENTS" agent_v3_set '["a","o"]'
  jset "$GEN_AGENTS" deploy_agent_g true; jset "$GEN_AGENTS" deploy_agent_g_optout true
  jset "$GEN_AGENTS" agent_g_caa_token_binding_opt_out false
  tf_agents b2-agents '^create (module\.agent_v3\["(a|o)"\]|module\.agent_g\["(g|g_optout)"\]|terraform_data\.agent_(g|v3)_inputs)'
  wait_ready "$(out_agents agent_v3 | jq -r .a.id)" v3a
  wait_ready "$(out_agents agent_v3 | jq -r .o.id)" v3o
  wait_ready "$(out_agents agent_g | jq -r .id)" g
  wait_ready "$(out_agents agent_g_optout | jq -r .id)" g-optout
}
b3_enforce() {
  jset "$GEN_INFRA" vpc_sc_enforced true; jset "$GEN_INFRA" vpc_sc_agent_ingress_identities '[]'
  tf_infra_run b3-enforce "$ALLOW_PERIM" -target=module.vpc_sc
  canary_wait enforced
}
b3_agents() {
  jset "$GEN_AGENTS" agent_v3_set '["a","o","b","a_psci","b_psci"]'
  tf_agents b3-agents '^create (module\.agent_v3\["(b|a_psci|b_psci)"\]|terraform_data\.agent_v3_inputs)'
  local k; for k in b a_psci b_psci; do wait_ready "$(out_agents agent_v3 | jq -r ".$k.id")" "v3-$k"; done
}
b3_ingress_deny() {
  local v3 ids exc canary
  v3="$(out_agents agent_v3)"; canary="$(out_infra v3h_canary | jq -r .identity)"
  ids="$(jq -c --arg c "$canary" '[.a.identity, .b.identity, .a_psci.identity, .b_psci.identity, $c]' <<<"$v3")"
  exc="$(jq -c '[.a.identity, .b.identity, .a_psci.identity]' <<<"$v3")"
  if [[ "$CMD" == subset ]] && jq -e '.a_dep_psci.identity and .b_dep_psci.identity' <<<"$v3" >/dev/null 2>&1; then   # T45d on: dep PSC-I engines need ingress; the approved one is a deny exception
    ids="$(jq -c --argjson i "$ids" '$i + [.a_dep_psci.identity, .b_dep_psci.identity]' <<<"$v3")"
    exc="$(jq -c --argjson e "$exc" '$e + [.a_dep_psci.identity]' <<<"$v3")"
  fi
  jset "$GEN_INFRA" vpc_sc_agent_ingress_identities "$ids"
  jset "$GEN_INFRA" enable_dc1_deny true; jset "$GEN_INFRA" dc1_approved_agent_principals "$exc"
  tf_infra_run b3-ingress-deny "$ALLOW_PERIM_DENY" "${TD_TARGETS[@]}"
  mark deny-on
  canary_wait ingress
}
b3_off() {
  jset "$GEN_INFRA" vpc_sc_enforced false; jset "$GEN_INFRA" enable_dc1_deny false
  tf_infra_run b3-off "$ALLOW_PERIM_UNDENY" "${TD_TARGETS[@]}"
  mark deny-off
  canary_wait open
}

teardown() {
  IN_TEARDOWN=1; safety
  log "teardown: agents"
  echo '{}' >"$GEN_AGENTS"
  tf_agents td-agents '^delete (module\.agent_|terraform_data\.agent_)'
  log "teardown: perimeter dry-run, ingress cleared, deny removed (targeted; full refresh fails while enforced)"
  jset "$GEN_INFRA" vpc_sc_enforced false; jset "$GEN_INFRA" enable_dc1_deny false; jset "$GEN_INFRA" vpc_sc_agent_ingress_identities '[]'
  tf_infra_run td-perim "$ALLOW_PERIM_UNDENY" "${TD_TARGETS[@]}"
  log "teardown: infra/ back to lz-5 + v3h-baseline"
  if [[ "$T47R" == 1 ]]; then ( tf_infra td-infra "$ALLOW_TEARDOWN" "${T47R_TARGETS[@]}" ) || true; else
  ( tf_infra td-infra "$ALLOW_TEARDOWN" ) || true; fi   # subshell: a 412 on the PSC-I attachment must not stop the run
  if grep -q 'connected endpoints cannot be deleted' "$WORK"/td-infra*.apply.txt 2>/dev/null; then
    log "teardown: PSC-I attachment still has endpoints from deleted agents; background poll will finish it (free resources)"
    # shellcheck disable=SC2016
    nohup bash -c 'for i in $(seq 1 36); do n=$(gcloud compute network-attachments describe lzv-psci --region='"$REGION"' --project='"$RT"' --format=json 2>/dev/null | jq "(.connectionEndpoints // []) | length"); [ "$n" = 0 ] && exec bash '"$ROOT"'/tests/run-v3h.sh teardown-infra '"$N"'; [ -z "$n" ] && exit 0; sleep 300; done' >"$WORK/psci-poll.txt" 2>&1 &
  fi
  PAID=0
}

teardown_v3h_close() {
  IN_TEARDOWN=1; safety
  log "teardown (close): destroying infra-v3h agents and restoring t40b_authoritative=false in $LABEL"
  v3h_tfvars "run=\"$LABEL\"" "existing_project_id=\"$PRJ\"" t40b_authoritative=false deploy_agent_1=false deploy_agent_2=false deploy_agent_3=false
  tf_v3h v3h-close-td '^delete (google_project_iam_binding\.t40b\[|module\.agent\["(1|2|3)"\]\.)'
  PAID_V3H=0
}

on_exit() {
  local rc=$?
  if [[ "$PAID" == 1 && "$DONE" == 0 && "$IN_TEARDOWN" == 0 && "$DRY" == 0 ]]; then
    log "run stopped (rc=$rc) with paid resources up: teardown"
    ( teardown ) || log "teardown after stop FAILED: human check needed (agents, gateway, SWP)"
  fi
  if [[ "${T57_UP:-0}" == 1 && "$DRY" == 0 ]]; then
    log "T57 stopped (rc=$rc) with the runtime project floor out of Terraform state: restore"
    ( t57_restore ) || log "T57 restore after stop FAILED: human check needed (google_model_armor_floorsetting.v2_project[0])"
  fi
  if [[ "$PAID_V3H" == 1 && "$DONE" == 0 && "$IN_TEARDOWN" == 0 && "$DRY" == 0 ]]; then
    log "close stopped (rc=$rc) with infra-v3h agents up: teardown"
    ( teardown_v3h_close ) || log "close teardown after stop FAILED: human check needed in infra-v3h ($LABEL)"
  fi
}

redact_commit_prep() {
  local paths=() t d sum chk
  for t in T40 T40b T41 T42 T44 T44b T45 T45d T46 T47 T47r T47r2 T48 T48b T49 T50 T51 T52 T53 T55 T56 T57; do for d in "evidence/$t/$RUN_ID" "evidence/$t/$RUN_ID"-r*; do [[ -d "$d" ]] && paths+=("$d"); done; done
  paths+=("$LOG")
  python3 tools/redact.py "${paths[@]}" >"$WORK/redact.txt" 2>&1 || return 1
  python3 tools/redact.py --check "${paths[@]}" >"$WORK/redact-check.txt" 2>&1 || { log "redaction check found items: $(tail -1 "$WORK/redact-check.txt")"; return 1; }
  sum="$(tail -1 "$WORK/redact.txt" | sed 's/; map: .*//')"
  chk="$(tail -1 "$WORK/redact-check.txt")"
  log "redaction: $sum; check: $chk (T43 $RUN_ID redacted at close)"
}

redact_close() {
  local paths=() t d sum chk
  for t in T43 T40b; do for d in "evidence/$t/$RUN_ID" "evidence/$t/$RUN_ID"-r*; do [[ -d "$d" ]] && paths+=("$d"); done; done
  [[ -f "$LOG" ]] && paths+=("$LOG")
  python3 tools/redact.py "${paths[@]}" >"$WORK/redact-close.txt" 2>&1 || return 1
  python3 tools/redact.py --check "${paths[@]}" >"$WORK/redact-close-check.txt" 2>&1 || { log "close redaction check found items: $(tail -1 "$WORK/redact-close-check.txt")"; return 1; }
  sum="$(tail -1 "$WORK/redact-close.txt" | sed 's/; map: .*//')"
  chk="$(tail -1 "$WORK/redact-close-check.txt")"
  log "close redaction: $sum; check: $chk"
}

# ---------------------------------------------------------------------------------------------- commands
do_run() {
  [[ -f "$LOG" || "$DRY" == 1 ]] || printf '# v3h run %s (%s), orchestrated (tests/run-v3h.sh)\n\nProject: %s (label %s). Plan: plans/v3h-automation.md. Expected results: script headers (pre-registered).\n\n## Log\n' "$N" "$(date -u +%F)" "$PKEY" "$LABEL" >"$LOG"
  [[ "$DRY" == 1 ]] || trap on_exit EXIT
  step preflight preflight
  step build build_artifacts
  # block 1: per-run project
  step v3h-s0 v3h_step0
  step t40-before t_stage T40 before
  step t42-before t_stage T42 before
  step agent1 v3h_agent 1 true
  mark agent1
  step b2-infra b2_infra                         # runs while the >= 5 min after agent 1 elapses
  wait_until $(( $(mark_get agent1) + 300 )) "5 min after agent 1 (T40 pre-registered wait)"
  step t40-after t_stage T40 after "$RUN_ID" V3H_WAITED_5MIN=yes
  step t42-after t_stage T42 after
  step t41-before t_stage T41 before
  step agent2 v3h_agent 2 true
  mark agent2
  step b2-fixtures b2_fixtures                   # runs while the >= 5 min after agent 2 elapses
  wait_until $(( $(mark_get agent2) + 300 )) "5 min after agent 2 (T41 pre-registered wait)"
  step t41-after t_stage T41 after "$RUN_ID" V3H_WAITED_5MIN=yes
  step agents12-off v3h_agents12_off
  step t43-t0 t_stage T43 t0
  mark t43
  # block 2: gateway, replay, binding
  step b2-agents b2_agents
  step t47 t_seq_retry T47 "s1 s2 s3 s4"
  step t48 t_seq_retry T48 "bound optout"
  wait_until $(( $(mark_get replay-reg) + 300 )) "5 min after the replay host was registered on the gateway (T49)"
  step t49 t_seq_retry T49 "bound optout"
  step t46 t_stage T46 ""
  step t44-pre t_stage T44 pre
  wait_until $(( $(mark_get t43) + 900 )) "15 min after T43 t0"
  step t43-p15 t_stage T43 p15
  # block 3: perimeter and platform
  step b3-enforce b3_enforce
  step b3-agents b3_agents
  step t44-noingress t_stage T44 noingress
  step t44b-noingress t_stage T44b noingress
  step b3-ingress-deny b3_ingress_deny
  step t44b-ingress1 t_stage T44b ingress1
  wait_until $(( $(mark_get deny-on) + 900 )) "T44 v2 / T44b: 15 min after the ingress apply (pre-registered)"
  step t44-ingress t_stage T44 ingress "$RUN_ID" V3H_WAITED_15MIN=yes
  step t44b-ingress15 t_stage T44b ingress15 "$RUN_ID" V3H_WAITED_15MIN=yes
  wait_until $(( $(mark_get deny-on) + DENY_WAIT )) "IAM deny propagation (fixed)"
  step t45-on t_stage T45 on
  step b3-off b3_off
  wait_until $(( $(mark_get deny-off) + DENY_WAIT )) "IAM deny removal propagation (fixed)"
  step t45-off t_stage T45 off
  step teardown teardown
  DONE=1
  log "run $N finished. Open: T43 p24h/agent3 via 'tests/run-v3h.sh close $N' at >= $(date -u -r $(( $(mark_get t43) + 86400 )) +%FT%H:%MZ 2>/dev/null)"
  step redact redact_commit_prep
}

v3h_close_init() {
  v3h_tfvars "run=\"$LABEL\"" "existing_project_id=\"$PRJ\"" deploy_agent_1=false deploy_agent_2=false deploy_agent_3=false t40b_authoritative=false
}
v3h_agent3_off() { v3h_agent 3 false; PAID_V3H=0; }
t40b_drift() { v3h_tfvars t40b_authoritative=true; t_stage T40b drift; }
t40b_apply() {
  local name=v3h-t40b allow='^create google_project_iam_binding\.t40b\[' plan try bad
  rm -f "$WORK/t40b-apply-400.txt"
  for try in 1 2 3; do
    safety
    plan="$WORK/$name.tfplan"
    terraform -chdir=infra-v3h plan -no-color -input=false -var "run=$LABEL" -state="state/$LABEL.tfstate" -out="$plan" >"$WORK/$name.plan.txt" 2>&1 \
      || die "plan $name failed: $(grep -m1 -E '^Error' "$WORK/$name.plan.txt")"
    terraform -chdir=infra-v3h show -json "$plan" >"$WORK/$name.plan.json" 2>/dev/null || die "show $name failed"
    jq -r '.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])
      | ((if .change.actions == ["delete","create"] or .change.actions == ["create","delete"] then "replace" else .change.actions[0] end) + " " + .address)' \
      "$WORK/$name.plan.json" >"$WORK/$name.changes.txt"
    bad="$(grep -vE "$allow" "$WORK/$name.changes.txt" || true)"
    [[ -z "$bad" ]] || die "plan $name has unexpected changes (not applied): $(head -5 <<<"$bad" | tr '\n' ';')"
    log "plan $name: $(wc -l <"$WORK/$name.changes.txt" | tr -d ' ') changes ($(cut -d' ' -f1 "$WORK/$name.changes.txt" | sort | uniq -c | awk '{printf "%s %s ", $1, $2}'))"
    [[ -s "$WORK/$name.changes.txt" ]] || return 0
    if terraform -chdir=infra-v3h apply -no-color -input=false -state="state/$LABEL.tfstate" "$plan" >"$WORK/$name.apply.txt" 2>&1; then
      log "apply $name: $(grep -E 'Apply complete' "$WORK/$name.apply.txt" | tail -1)"
      mark t40b
      return 0
    fi
    grep -q 'CONSUMER_SUSPENDED' "$WORK/$name.apply.txt" && die "CONSUMER_SUSPENDED during $name"
    if grep -qE 'Error 400|status.?code.?400|must contain at least one|empty.*member|INVALID_ARGUMENT' "$WORK/$name.apply.txt"; then
      grep -E 'Error|googleapi|message' "$WORK/$name.apply.txt" | head -5 >"$WORK/t40b-apply-400.txt"
      [[ -s "$WORK/t40b-apply-400.txt" ]] || echo "HTTP 400 rejecting empty IAM binding" >"$WORK/t40b-apply-400.txt"
      log "apply $name rejected with HTTP 400 (pre-registered T40b outcome ii)"
      return 0
    fi
    if (( try < 3 )) && grep -qE "$RETRY_ERE" "$WORK/$name.apply.txt"; then
      log "apply $name failed with a known propagation error; retry $try of 2 in 180 s ($(grep -m1 -E '^Error' "$WORK/$name.apply.txt" | cut -c1-160))"
      sleep 180; name="$name-retry"; continue
    fi
    die "apply $name failed: $(grep -m1 -E '^Error' "$WORK/$name.apply.txt" | cut -c1-200)"
  done
}
t40b_restore() {
  v3h_tfvars t40b_authoritative=false deploy_agent_1=false deploy_agent_2=false
  tf_v3h v3h-t40b-restore '^delete (google_project_iam_binding\.t40b\[|module\.agent\["(1|2)"\]\.)'
  PAID_V3H=0
}

do_close() {
  local t0
  t0="$(jq -r '.timestamp_utc' "evidence/T43/$RUN_ID/stages/t0.json" 2>/dev/null)"; [[ "$t0" == 20* ]] || die "no T43 t0 for $RUN_ID"
  t0="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$t0" +%s 2>/dev/null || date -u -d "$t0" +%s)"
  [[ "$DRY" == 1 ]] || trap on_exit EXIT
  step close-preflight safety
  step close-init v3h_close_init
  wait_until $(( t0 + 86400 + 60 )) "T43 p24h (24 h after t0)"
  step close-t43-p24h t_stage T43 p24h
  step close-agent3 v3h_agent 3 true
  mark agent3
  wait_until $(( $(mark_get agent3) + 300 )) "5 min after agent 3 (T43 pre-registered wait)"
  step close-t43-agent3 t_stage T43 agent3 "$RUN_ID" V3H_WAITED_5MIN=yes
  step close-agent3-off v3h_agent3_off
  if [[ "$N" == 1 ]]; then   # D7: T40b once, in mcp (state r1), after T43
    step t40b-agent1 v3h_agent 1 true
    step t40b-pre t_stage T40b pre
    step t40b-drift t40b_drift
    step t40b-apply t40b_apply
    if [[ -s "$WORK/t40b-apply-400.txt" ]]; then
      step t40b-call t_stage T40b call "$RUN_ID" "V3H_T40B_APPLY_400=$WORK/t40b-apply-400.txt"
    else
      wait_until $(( $(mark_get t40b) + 420 )) "7 min IAM propagation (T40b pre-registered wait)"
      step t40b-call t_stage T40b call
      step t40b-agent2 v3h_agent 2 true
      mark t40b2
      wait_until $(( $(mark_get t40b2) + 300 )) "5 min after agent 2 (T40b)"
      step t40b-agent2-test t_stage T40b agent2
    fi
    step t40b-restore t40b_restore
  fi
  DONE=1
  log "close $N finished"
  step close-redact redact_close
}

# ---------------------------------------------------------------------------------------------- subset runs (plan 3b)
preflight_subset() {
  safety
  local n; n="$(engine_count)"; [[ "$n" =~ ^[0-9]+$ ]] || die "preflight: cannot list reasoning engines in $RT"
  [[ "$n" == 0 ]] || die "preflight: $n reasoning engines already in $RT (teardown first)"
  out_infra v3h_canary | jq -e .email >/dev/null || die "preflight: canary missing (infra/ enable_v3h_canary)"
  [[ "$(canary_probe bucket)" == 200 ]] || die "preflight: canary cannot list the build bucket with the perimeter in dry-run"
  log "preflight OK (subset): $RT empty, canary OK"
}
s2_agents() {   # block 2 of a subset run: v3a, v3o, sibling x (T48b, T52), G + G opt-out (T49, T53)
  local url; url="$(out_infra v3h_replay_url | jq -r '. // empty')"
  [[ "$url" == https://* ]] || return 1
  jset "$GEN_AGENTS" agent_v3_replay_url "\"$url\""
  jset "$GEN_AGENTS" agent_v3_set '["a","o","x"]'
  jset "$GEN_AGENTS" deploy_agent_g true; jset "$GEN_AGENTS" deploy_agent_g_optout true
  jset "$GEN_AGENTS" agent_g_caa_token_binding_opt_out false
  tf_agents s2-agents '^create (module\.agent_v3\["(a|o|x)"\]|module\.agent_g\["(g|g_optout)"\]|terraform_data\.agent_(g|v3)_inputs)'
  local k; for k in a o x; do wait_ready "$(out_agents agent_v3 | jq -r ".$k.id")" "v3-$k"; done
  wait_ready "$(out_agents agent_g | jq -r .id)" g
  wait_ready "$(out_agents agent_g_optout | jq -r .id)" g-optout
}
t52_grant() {   # human-approved 2026-11-12: agentContextEditor on the runtime project for the agents principal set
  jset "$GEN_INFRA" v3h_t52_grant_context_editor "$1"
  if [[ "$1" == true ]]; then tf_infra_run t52-grant '^create google_project_iam_member\.v3h_t52_context_editor(\[0\])?$'; mark t52
  else tf_infra_run t52-revoke '^delete google_project_iam_member\.v3h_t52_context_editor(\[0\])?$'; fi
}
s3_agents() {   # block 3: b and PSC-I pair (T44, T50 deny, T51, T55)
  jset "$GEN_AGENTS" agent_v3_set '["a","o","x","b","a_psci","b_psci"]'
  tf_agents s3-agents '^create (module\.agent_v3\["(b|a_psci|b_psci)"\]|terraform_data\.agent_v3_inputs)'
  local k; for k in b a_psci b_psci; do wait_ready "$(out_agents agent_v3 | jq -r ".$k.id")" "v3-$k"; done
}
s3_dep_agents() {   # T45d engines (plan 3b: if pip install ./lzv_helper fails at deploy, T45d records NOT_TESTED and the run continues)
  jset "$GEN_AGENTS" agent_v3_set '["a","o","x","b","a_psci","b_psci","a_dep","b_dep","a_dep_psci","b_dep_psci"]'
  if ( tf_agents s3-dep-agents '^create (module\.agent_v3\["(a_dep|b_dep|a_dep_psci|b_dep_psci)"\]|terraform_data\.agent_v3_inputs)' ); then
    local k; for k in a_dep b_dep a_dep_psci b_dep_psci; do wait_ready "$(out_agents agent_v3 | jq -r ".$k.id")" "v3-$k"; done
  else
    log "s3-dep-agents deploy failed (see scratch/run-v3h-$N/s3-dep-agents*.apply.txt); cleaning up partial dep engines so T45d records NOT_TESTED"
    jset "$GEN_AGENTS" agent_v3_set '["a","o","x","b","a_psci","b_psci"]'
    ( tf_agents s3-dep-cleanup '^delete (module\.agent_v3\["(a_dep|b_dep|a_dep_psci|b_dep_psci)"\]|terraform_data\.agent_v3_inputs)' ) || true
  fi
}
do_subset() {
  [[ -f "$LOG" || "$DRY" == 1 ]] || printf '# v3h run %s (%s), subset (tests/run-v3h.sh subset)\n\nNo per-run project (block 2/3 only, plan 3b scheduling). Expected results: script headers (pre-registered).\n\n## Log\n' "$N" "$(date -u +%F)" >"$LOG"
  [[ "$DRY" == 1 ]] || trap on_exit EXIT
  step preflight preflight_subset
  step build build_artifacts
  # block 2 (perimeter dry-run)
  step b2-infra b2_infra
  step b2-fixtures b2_fixtures
  step s2-agents s2_agents
  step t48b t_stage T48b ""
  step t50-main t_stage T50 main
  step t52-default t_stage T52 default
  step t52-grant t52_grant true
  step t53 t_stage T53 ""
  step t56-calls t_stage T56 calls
  mark t56
  wait_until $(( $(mark_get replay-reg) + 300 )) "5 min after the replay host was registered on the gateway (T49)"
  step t49 t_seq_retry T49 "bound optout"
  wait_until $(( $(mark_get t52) + 420 )) "7 min after the agentContextEditor grant (T52 pre-registered wait)"
  step t52-granted t_stage T52 granted "$RUN_ID" V3H_WAITED_7MIN=yes
  step t52-revoke t52_grant false
  wait_until $(( $(mark_get t56) + 960 )) "T56: >= 15 min after its last call (pre-registered late read)"
  step t56-late t_stage T56 late
  step t44-pre t_stage T44 pre
  # block 3 (perimeter enforced, then ingress + deny, then off)
  step b3-enforce b3_enforce
  step s3-agents s3_agents
  step s3-dep-agents s3_dep_agents
  step t44-noingress t_stage T44 noingress
  step t44b-noingress t_stage T44b noingress
  step b3-ingress-deny b3_ingress_deny
  step t44b-ingress1 t_stage T44b ingress1
  wait_until $(( $(mark_get deny-on) + 900 )) "T44 v2 / T44b: 15 min after the ingress apply (pre-registered)"
  step t44-ingress t_stage T44 ingress "$RUN_ID" V3H_WAITED_15MIN=yes
  step t44b-ingress15 t_stage T44b ingress15 "$RUN_ID" V3H_WAITED_15MIN=yes
  step t45d-on t_stage T45d on
  step t51 t_stage T51 ""
  step t55 t_stage T55 ""
  step t50-deny t_stage T50 deny
  step b3-off b3_off
  wait_until $(( $(mark_get deny-off) + DENY_WAIT )) "IAM deny removal propagation (fixed)"
  step t45d-off t_stage T45d off
  step teardown teardown
  DONE=1
  log "subset run $N finished"
  step redact redact_commit_prep
}

# gw N (plan 3b, T53 v2 / T56 v2): block 2 only, the subset's own steps for T53 and T56; no perimeter change.
do_gw() {
  [[ -f "$LOG" || "$DRY" == 1 ]] || printf '# v3h gw %s (%s), gateway-only (tests/run-v3h.sh gw)\n\nBlock 2 only: T53 v2 and T56 v2 (plan 3b, 5c3808a). Expected results: script headers (pre-registered).\n\n## Log\n' "$N" "$(date -u +%F)" >"$LOG"
  [[ "$DRY" == 1 ]] || trap on_exit EXIT
  step preflight preflight_subset
  step build build_artifacts
  step b2-infra b2_infra
  step b2-fixtures b2_fixtures
  step s2-agents s2_agents
  step t53 t_stage T53 ""
  step t56-calls t_stage T56 calls
  mark t56
  wait_until $(( $(mark_get t56) + 960 )) "T56: >= 15 min after its last call (pre-registered late read)"
  step t56-late t_stage T56 late
  step teardown teardown
  DONE=1
  log "gw run $N finished"
  step redact redact_commit_prep
}

# ---------------------------------------------------------------------------------------------- T47r (plan 3b)
t47r_build() {
  local v=unpinned; [[ "$T47R_V" == 2 ]] && v=run6
  VARIANT=$v bash tests/fixtures/gateway/agent_g/build.sh >"$WORK/build-g-$v.txt" 2>&1 || return 1
  log "artifacts: agent G $v sha256 $(shasum -a 256 "infra/agents/build/source-g-$v.tar.gz" | cut -c1-16)...; requirements: $(tar -xzOf "infra/agents/build/source-g-$v.tar.gz" requirements.txt | tr '\n' ' ')"
}
t47r2_gate() {   # plan 3b T47r2 gate, checked before anything paid: latest T49 bound stage shows G's token bound
  # shellcheck disable=SC2012
  local j n; j="$(ls -t evidence/T49/run-*/stages/bound.json 2>/dev/null | head -1)"
  [[ -n "$j" ]] || die "T47r2 gate: no T49 bound stage yet (run T49 first)"
  n="$(jq -r '.note // ""' "$j" | tr '[:upper:]' '[:lower:]')"
  [[ "$n" == *"agent_cert=true"* && "$n" == *"should_request_bound=true"* && "$n" == *"replay=401"* ]] \
    || die "T47r2 gate not met ($j): G's token not shown bound; T47r2 stays NOT_TESTED (H2 explains the November 200s)"
  log "T47r2 gate met: $j"
}
# Targeted (added 2026-11-12 before the attempt): run 1 left the PSC-I attachment lzv-psci with 2 endpoints Google has
# not released (plus its VPC, subnets, SWP APIs; free). A full plan would delete them and fail with 412; T47r touches
# only the gateway resources and leaves those as they are (deviation recorded in the T47r log).
T47R_TARGETS=(-target=google_network_services_agent_gateway.v2 -target=google_agent_registry_service.v2_ep_aiplatform_mtls
  -target=google_agent_registry_service.v2_ep_aiplatform -target=google_agent_registry_service.v2_ep_essential
  -target=google_agent_registry_service.v2_ep_logging -target=google_agent_registry_service.v2_ep_sessions
  -target=google_agent_registry_service.v2_mcp_reg -target=google_artifact_registry_repository.v2_gw
  -target=google_iap_agent_registry_iam_member.v2_egress -target=google_model_armor_template.v2_gw
  -target=google_network_security_authz_policy.v2_iap -target=google_network_security_authz_policy.v2_ma
  -target=google_network_services_authz_extension.v2_iap -target=google_network_services_authz_extension.v2_ma
  -target=google_project_iam_member.v2_gw_dep -target=google_project_service_identity.v2_gw_dep
  -target=google_project_service.v2_gw)
t47r_infra() {
  PAID=1
  log "deviation: targeted infra plan (gateway resources only); run-1 PSC-I leftovers (attachment with 2 unreleased endpoints, VPC, subnets, SWP APIs) left untouched"
  tf_infra_run t47r-infra '^create ' "${T47R_TARGETS[@]}"
}
t47r_agent() {
  jset "$GEN_AGENTS" deploy_agent_g true; jset "$GEN_AGENTS" deploy_agent_g_optout false
  jset "$GEN_AGENTS" agent_g_caa_token_binding_opt_out false
  if [[ "$T47R_V" == 2 ]]; then jset "$GEN_AGENTS" agent_g_run6 true; else jset "$GEN_AGENTS" agent_g_unpinned true; fi
  tf_agents t47r-agent '^create (module\.agent_g\["g"\]|terraform_data\.agent_g_inputs)'
  mark t47r-agent
  wait_ready "$(out_agents agent_g | jq -r .id)" g
}
do_t47r() {
  [[ -f "$LOG" || "$DRY" == 1 ]] || printf '# %s attempt %s (%s), tests/run-v3h.sh %s\n\nProfile infra/profiles/v3h-t47r.tfvars (IAP V1, no gateway VPC). Expected: tests/%s.sh header.\n\n## Log\n' "$T47R_TEST" "$N" "$(date -u +%F)" "$T47R_NAME" "$T47R_TEST" >"$LOG"
  [[ "$T47R_V" == 2 ]] && step gate t47r2_gate
  [[ "$DRY" == 1 ]] || trap on_exit EXIT
  step preflight preflight_subset
  step build t47r_build
  step t47r-infra t47r_infra
  step t47r-agent t47r_agent
  wait_until $(( $(mark_get t47r-agent) + 240 )) "4 min after the agent G deploy (as T47)"
  step "$T47R_NAME" t_stage "$T47R_TEST" ""
  step teardown teardown
  DONE=1
  log "$T47R_TEST attempt $N finished"
  step redact redact_commit_prep
}

# ---------------------------------------------------------------------------------------------- T57 (Findings 24 re-check)
T57_ADDR='google_model_armor_floorsetting.v2_project[0]'
T57_UP=0; grep -qx t57-destroy "$STATE_F" && ! grep -qx t57-restore "$STATE_F" && T57_UP=1   # resume after a stop
t57_preflight() {
  safety
  local n; n="$(engine_count)"; [[ "$n" =~ ^[0-9]+$ ]] || die "preflight: cannot list reasoning engines in $RT"
  [[ "$n" == 0 ]] || die "preflight: $n reasoning engines in $RT (T57 runs only between rows)"
  log "preflight OK (T57): $RT has no agents; provider $(grep -A2 'registry.terraform.io/hashicorp/google"' infra/.terraform.lock.hcl | sed -nE 's/.*version *= *"([^"]+)".*/\1/p' | head -1)"
}
t57_before() { t_stage T57 before; [[ "$LAST_V" == PASS ]] || die "T57 before: $LAST_V (floor does not match the baseline; nothing changed)"; }
t57_destroy() { T57_UP=1; tf_infra t57-destroy '^delete google_model_armor_floorsetting\.v2_project\[0\]$' -destroy -target="$T57_ADDR"; }
t57_restore() { tf_infra t57-restore '^create google_model_armor_floorsetting\.v2_project\[0\]$' -target="$T57_ADDR" && T57_UP=0; }
t57_restored() {
  t_stage T57 restored
  [[ "$(cat "evidence/T57/$RUN_ID/restore-ok" 2>/dev/null)" == 1 ]] || die "T57 restore check failed: the runtime project floor does not match its before state (human check before the next row)"
}
do_t57() {
  [[ -f "$LOG" || "$DRY" == 1 ]] || printf '# T57 attempt %s (%s), tests/run-v3h.sh t57 %s\n\nFindings 24 / F20 re-check. Plan 3b T57. Expected: tests/T57.sh header.\n\n## Log\n' "$N" "$(date -u +%F)" "$N" >"$LOG"
  [[ "$DRY" == 1 ]] || trap on_exit EXIT
  step preflight t57_preflight
  step t57-before t57_before
  step t57-destroy t57_destroy
  mark t57-destroy
  wait_until $(( $(mark_get t57-destroy) + 60 )) "T57: 1 min after the destroy (pre-registered first read)"
  step t57-after t_stage T57 after
  step t57-restore t57_restore
  step t57-restored t57_restored
  DONE=1
  log "T57 attempt $N finished"
  step redact redact_commit_prep
}

case "$CMD" in
  t57)      do_t57 ;;
  gw)       do_gw ;;
  subset)   do_subset ;;
  t47r|t47r2) do_t47r ;;
  run)      do_run ;;
  close)    do_close ;;
  teardown) step "teardown-manual-$(date +%s)" teardown ;;
  teardown-infra) step "teardown-infra-$(date +%s)" tf_infra "td-infra-final-$(date +%s)" "$ALLOW_TEARDOWN" ;;   # PSC-I poll, after release
  status)   cat "$STATE_F" ;;
esac
