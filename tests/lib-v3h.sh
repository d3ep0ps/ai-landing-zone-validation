# shellcheck shell=bash disable=SC2034,SC2016
# Helpers for the v3 harness-boundary tests (T40-T48). Source AFTER lib.sh:
#   source "$(dirname "$0")/lib.sh"; source "$(dirname "$0")/lib-v3h.sh"
# Per-run project (T40-T43): infra-v3h/, state infra-v3h/state/<label>.tfstate. The label comes from
# RUN_ID (run-1 -> r1, run-1-r2 -> r1) or from V3H_RUN (required when RUN_ID=dry). Read-only:
# nothing here applies Terraform or deploys an agent.
# Terraform toggles (deploy_agent_N, t40b_authoritative) must be in infra-v3h/terraform.tfvars so a
# plan matches what is deployed; extra plan args can go in V3H_PLAN_ARGS.

V3H_LABEL=""; V3H_STATE=""; V3H_PID=""; V3H_PNUM=""; V3H_OUT_JSON=""
V3H_PLAN_RC=""; V3H_PLAN_JSON=""; V3H_PLAN_CHANGES=""
Q_RC=""; Q_HAVE=0; Q_LINE=""; Q_STATUS=""; Q_BY=""; Q_ERR=""

v3h_json_last() { sed -n '/^[[{]/,$p' "$LZV_LAST_OUT"; }

v3h_init() {
  if [[ -n "${V3H_RUN:-}" ]]; then V3H_LABEL="$V3H_RUN"
  elif [[ "$RUN_ID" =~ ^run-([0-9]+) ]]; then V3H_LABEL="r${BASH_REMATCH[1]}"
  else lzv_die "set V3H_RUN (terraform run label, e.g. r1) when RUN_ID=$RUN_ID"; fi
  [[ "$V3H_LABEL" =~ ^[a-z0-9]{1,6}$ ]] || lzv_die "bad V3H_RUN '$V3H_LABEL'"
  V3H_STATE="$LZV_ROOT/infra-v3h/state/$V3H_LABEL.tfstate"
  [[ -f "$V3H_STATE" ]] || lzv_die "no state $V3H_STATE (the human applies infra-v3h first)"
  V3H_OUT_JSON="$(terraform -chdir="$LZV_ROOT/infra-v3h" output -state="$V3H_STATE" -json 2>/dev/null)"
  [[ -n "$V3H_OUT_JSON" ]] || lzv_die "terraform output unavailable for $V3H_LABEL"
  V3H_PID="$(jq -er '.project_id.value' <<<"$V3H_OUT_JSON")" || lzv_die "no project_id output"
  V3H_PNUM="$(jq -er '.project_number.value' <<<"$V3H_OUT_JSON")" || lzv_die "no project_number output"
  V3H_PSET="$(jq -er '.expected_agent_principal_set.value' <<<"$V3H_OUT_JSON")" || lzv_die "no expected_agent_principal_set output"
}
# Terraform outputs change after each human apply: re-read.
v3h_refresh() { V3H_OUT_JSON="$(terraform -chdir="$LZV_ROOT/infra-v3h" output -state="$V3H_STATE" -json 2>/dev/null)"; }
v3h_agent() {  # v3h_agent N id|identity -> value or empty
  v3h_refresh
  jq -r --arg n "$1" --arg f "$2" '(.agents.value[$n][$f]) // empty' <<<"$V3H_OUT_JSON"
}
v3h_agent_count() { v3h_refresh; jq -r '(.agents.value // {}) | length' <<<"$V3H_OUT_JSON"; }

# v3h_plan NAME: terraform plan -detailed-exitcode on infra-v3h (read-only, no apply). Sets
# V3H_PLAN_RC (0 none, 1 error, 2 changes), V3H_PLAN_JSON (file, may be absent), V3H_PLAN_CHANGES
# (non-no-op resource changes, one "address actions" per line).
v3h_plan() {
  local name="$1" pf args=()
  pf="$LZV_ROOT/scratch/v3h/$V3H_LABEL-$LZV_ID-$RUN_ID-$name.tfplan"
  mkdir -p "$LZV_ROOT/scratch/v3h"
  read -r -a args <<<"${V3H_PLAN_ARGS:-}"
  run_capture terraform -chdir="$LZV_ROOT/infra-v3h" plan -detailed-exitcode -input=false -no-color -lock=false \
    -var "run=$V3H_LABEL" -state="$V3H_STATE" -out="$pf" "${args[@]+"${args[@]}"}"
  V3H_PLAN_RC="$LZV_LAST_RC"
  V3H_PLAN_JSON="$LZV_DIR/plan-$name.json"
  V3H_PLAN_CHANGES=""
  rm -f "$V3H_PLAN_JSON"
  if [[ -f "$pf" ]]; then
    run_capture_sh "terraform -chdir='$LZV_ROOT/infra-v3h' show -json -no-color '$pf' > '$V3H_PLAN_JSON'"
    if jq -e . "$V3H_PLAN_JSON" >/dev/null 2>&1; then
      V3H_PLAN_CHANGES="$(jq -r '.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"]) | "\(.address) \(.change.actions | join(","))"' "$V3H_PLAN_JSON")"
    else
      rm -f "$V3H_PLAN_JSON"
    fi
  fi
  note "plan $name: exit=$V3H_PLAN_RC changes=[${V3H_PLAN_CHANGES//$'\n'/; }]"
}

# v3h_snapshot NAME: project allow policy of the per-run project into iam-NAME/project-v3h.json
# (iam_diff compares project-*.json files).
v3h_snapshot() {
  local d="$LZV_DIR/iam-$1"
  mkdir -p "$d"
  run_capture gcloud projects get-iam-policy "$V3H_PID" --format=json --billing-project="$(quota_project)"
  v3h_json_last >"$d/project-v3h.json"
  jq -e . "$d/project-v3h.json" >/dev/null 2>&1 || { note "snapshot $1: read failed"; return 1; }
  note "snapshot $1 written to ${d#"$LZV_ROOT"/}"
}
v3h_has_binding() {  # v3h_has_binding SNAPSHOT ROLE MEMBER -> 0 if present
  jq -e --arg r "$2" --arg m "$3" '[(.bindings // [])[] | select(.role == $r) | (.members // [])[] | select(. == $m)] | length > 0' \
    "$LZV_DIR/iam-$1/project-v3h.json" >/dev/null 2>&1
}
# v3h_judge_diff DIFF_LINES: J_ADDED, J_REMOVED, J_EXPECTED (added expected binding), J_EXTRA (other added)
v3h_judge_diff() {
  local want_role="roles/aiplatform.agentDefaultAccess"
  J_ADDED="$(jq -s '[.[] | select(.change == "added")] | length' <<<"$1")"
  J_EXPECTED="$(jq -s --arg r "$want_role" --arg m "$V3H_PSET" '[.[] | select(.change == "added" and .role == $r and .member == $m)] | length' <<<"$1")"
  J_EXTRA="$(jq -sr --arg r "$want_role" --arg m "$V3H_PSET" '[.[] | select(.change == "added" and ((.role == $r and .member == $m) | not)) | "\(.role) \(.member)"] | join("; ")' <<<"$1")"
  J_REMOVED="$(jq -sr '[.[] | select(.change == "removed") | "\(.role) \(.member)"] | join("; ")' <<<"$1")"
}

# v3h_age_s ISO_TS -> seconds since
v3h_age_s() { jq -nr --arg t "$1" '(now - ($t | fromdateiso8601)) | floor'; }
stage_ts() { jq -r '.timestamp_utc // empty' "$LZV_DIR/stages/$1.json" 2>/dev/null; }

# v3h_query AGENT_ID "ACTION=... MODE=..." : one deterministic query to a v3 agent (grammar in
# tests/fixtures/agent_v3/README.md). The token is built inside the single-quoted command string,
# so it never reaches command.txt or output.txt. Sets Q_RC, Q_HAVE (JSON line seen), Q_LINE, Q_STATUS,
# Q_BY (refused_by or "none"), Q_ERR.
v3h_query() {
  local id="$1" text="$2" region
  region="${id#*/locations/}"; region="${region%%/*}"
  export LZV_URL="https://${region}-aiplatform.googleapis.com/v1/${id}:streamQuery?alt=sse"
  LZV_BODY="$(jq -cn --arg m "$text" '{class_method:"async_stream_query", input:{user_id:"lzv-v3h", message:$m}}')"
  export LZV_BODY
  run_capture_sh 'out="$(printf "Authorization: Bearer %s\n" "$(gcloud auth print-access-token)" | curl -sS -N --max-time 240 -H @- -H "Content-Type: application/json" -X POST "$LZV_URL" -d "$LZV_BODY" -w "\nHTTP %{http_code}\n" 2>&1)"; printf "%s\n" "$out"; case "$out" in *$'"'"'\n'"'"'HTTP\ 200) exit 0 ;; esac; exit 1'
  Q_RC="$LZV_LAST_RC"
  Q_LINE="$(sed 's/^data: *//' "$LZV_LAST_OUT" | jq -cR 'fromjson? | .. | objects | (.text? // empty) | fromjson? | select(type == "object" and has("harness_guard"))' 2>/dev/null | tail -1)"
  Q_HAVE=0; Q_STATUS=none; Q_BY=none; Q_ERR=""
  if [[ -n "$Q_LINE" ]]; then
    Q_HAVE=1
    Q_STATUS="$(jq -r '(.status // "none") | tostring' <<<"$Q_LINE")"
    Q_BY="$(jq -r '(.refused_by // "none") | tostring' <<<"$Q_LINE")"
    Q_ERR="$(jq -r '(.error // "") | tostring' <<<"$Q_LINE" | cut -c1-300)"
  elif grep -q 'vpcServiceControlsUniqueIdentifier' "$LZV_LAST_OUT"; then
    # Added before v3h run 2: the agent run itself was refused by VPC-SC before any result line
    # (run-1 T44 noingress, agent A: SessionService.CreateSession). Q_HAVE stays 0.
    Q_STATUS=403; Q_BY=vpc_sc_runtime; Q_ERR="agent run refused by VPC-SC before a result line"
  fi
  note "query [$text]: http_rc=$Q_RC line=$Q_HAVE status=$Q_STATUS refused_by=$Q_BY err=${Q_ERR:-none}"
}

# v3h_classify KIND -> V3H_V, V3H_WHY, from the last v3h_query.
#  adk       the harness guard must refuse (refused_by adk_callback)
#  platform  a platform control must refuse (not the callback, not 200)
#  allowed   must succeed (200, nothing refused)
#  observe   record only (always PASS)
v3h_classify() {
  V3H_V=INCONCLUSIVE; V3H_WHY=""
  if [[ "$1" == observe ]]; then V3H_V=PASS; return 0; fi
  if [[ "$Q_HAVE" != 1 ]]; then V3H_WHY="no result line from the agent (http_rc=$Q_RC)"; return 0; fi
  case "$1" in
    adk)
      if [[ "$Q_BY" == adk_callback ]]; then V3H_V=PASS
      elif [[ "$Q_STATUS" == 200 && "$Q_BY" == none ]]; then V3H_V=FAIL; V3H_WHY="harness guard did not refuse (status 200)"
      else V3H_WHY="refused by $Q_BY status $Q_STATUS, not by the callback"; fi ;;
    platform)
      if [[ "$Q_BY" == adk_callback ]]; then V3H_WHY="callback still refused after unhook: bypass not effective (open question in notes/doc-verification-v3h.md)"
      elif [[ "$Q_STATUS" == 200 && "$Q_BY" == none ]]; then V3H_V=FAIL; V3H_WHY="call allowed with the platform control on"
      elif [[ "$Q_BY" != none ]]; then V3H_V=PASS
      else V3H_WHY="no refusal and no 200 (status $Q_STATUS)"; fi ;;
    allowed)
      if [[ "$Q_STATUS" == 200 && "$Q_BY" == none ]]; then V3H_V=PASS
      else V3H_WHY="not allowed: refused_by=$Q_BY status=$Q_STATUS"; fi ;;
  esac
}
# v3h_cell CELL AGENT_ID "COMMAND" KIND: query, classify, append to cells.jsonl. Sets CELL_V.
v3h_cell() {
  v3h_query "$2" "$3"
  v3h_classify "$4"
  CELL_V="$V3H_V"
  jq -nc --arg c "$1" --arg cmd "$3" --arg k "$4" --arg v "$V3H_V" --arg w "$V3H_WHY" --arg by "$Q_BY" --arg st "$Q_STATUS" --arg e "$Q_ERR" \
    '{cell:$c, command:$cmd, expect:$k, verdict:$v, why:$w, refused_by:$by, status:$st, error:$e}' >>"$LZV_DIR/cells.jsonl"
  note "cell $1 [$4]: $V3H_V refused_by=$Q_BY status=$Q_STATUS${V3H_WHY:+ ($V3H_WHY)}"
}

# v3h_engine_env AGENT_ID -> V3H_ENV_JSON: GOOGLE_API_* and LZV_* env names/values of the deployed engine
# (REST GET; field path spec.deploymentSpec.env is INFERRED, empty if not found). No token is stored.
v3h_engine_env() {
  local id="$1" region
  region="${id#*/locations/}"; region="${region%%/*}"
  export LZV_URL="https://${region}-aiplatform.googleapis.com/v1/${id}"
  run_capture_sh 'curl -sS --max-time 60 -H "Authorization: Bearer $(gcloud auth print-access-token)" "$LZV_URL"'
  V3H_ENV_JSON="$(v3h_json_last | jq -c '[.spec.deploymentSpec.env[]? | select(.name | test("^(GOOGLE_API_|LZV_|HARNESS_|HTTPS_PROXY|NO_PROXY)")) | {(.name): .value}] | add // {}' 2>/dev/null)"
  [[ -n "$V3H_ENV_JSON" ]] || V3H_ENV_JSON='{}'
  note "engine env (selected names): $(jq -c 'keys' <<<"$V3H_ENV_JSON")"
}

# v3h_g_versions SINCE_ISO -> G_VERSIONS: package versions printed by agent G at import (plan 3b: recorded in every
# T47/T47r/T49 result). Read from Cloud Logging in the runtime project; "not found" if the line is not there yet.
v3h_g_versions() {
  local rt; rt="$(project_id runtime)"
  run_capture gcloud logging read "timestamp>=\"$1\" AND \"lzv_versions\"" --project="$rt" --limit=20 --format=json
  G_VERSIONS="$(v3h_json_last | jq -r '[.[] | (.jsonPayload.lzv_versions // ((.textPayload // "") | fromjson? | .lzv_versions) // empty)] | unique
    | map(to_entries | map("\(.key)=\(.value)") | join(" ")) | join(" | ")' 2>/dev/null)"
  [[ -n "$G_VERSIONS" ]] || G_VERSIONS="not found in logs since $1"
  note "agent G resolved versions (import-time log line): $G_VERSIONS"
}
