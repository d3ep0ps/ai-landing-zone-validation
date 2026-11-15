#!/usr/bin/env bash
# T56 (claims-register F24 = results.md Findings 29, re-check): is the gateway request log complete? Plan: plans/v3-harness-boundary-tests.md section 3b
# (pre-registered 2026-11-12, commit f33a611, before this script). Block 2 of a subset (agent G behind the gateway).
#   calls  agent G, call_mcp_tool (one POST to /mcp per call), sequential: 5x registered_echo (200), 5x unregistered_echo
#          (403, IAP DENIED), 3x inject_response (403, Model Armor DENIED); each call's window is recorded in calls.jsonl.
#          Early read of gateway_requests at last call + 3 min (observation).
#   late   >= 15 min after the last call: the same read over the same span; matches each call to its records. Writes the result.
# A call "has an entry": at least one gateway record to its host in [start - 2 s, end + 2 s]; for a 403 call the record
# must also carry DENIED. Expected: every usable call has an entry at the late read. Falsified (F24 reproduces): any
# usable call without an entry, or a 403 call's entry without DENIED. Fewer than 3 usable calls of a kind: INCONCLUSIVE.
# shellcheck disable=SC2016
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=lib-v3h.sh
source "$(dirname "$0")/lib-v3h.sh"
require_config

STAGE="${1:-}"
case "$STAGE" in calls|late) ;; *) lzv_die "usage: T56.sh calls|late" ;; esac
RT="$(project_id runtime)"
LZV_SCOPE="projects/$RT"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale/runtime/agent-gateway-runtime-deploy"
)
header T56 "Findings 29 / claims F24 re-check (Configured)" "Agent G makes 13 MCP tool calls through the gateway (5 allowed, 5 IAP-refused, 3 Model Armor-refused); each call is matched to gateway_requests records, read early (+3 min) and late (>= +15 min)" \
  "At the late read, every call with a tool result has at least one gateway_requests record to its host inside its time window, and every 403 call's record shows DENIED. Falsified (F24 reproduces) if: any such call has no record, or a 403 call's record lacks DENIED. INCONCLUSIVE if: fewer than 3 usable calls of any kind. Observation: records present late but not early = delivery lag. Tier: Configured. 2 runs (subsets 4, 5)." \
  "$STAGE"
note "results.md Findings 29 = claims-register F24 (run 8); no resources are created by this script; no cleanup_trap registered"
CALLS="$LZV_DIR/calls.jsonl"
REGION="$LZV_REGION"
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# gw_read FROM_ISO -> GW (compact JSON array of {ts epoch, host reg|unreg, status, denied})
gw_read() {
  run_capture gcloud logging read "timestamp>=\"$1\" AND logName=\"projects/$RT/logs/networkservices.googleapis.com%2Fgateway_requests\" AND httpRequest.requestMethod=\"POST\" AND httpRequest.requestUrl:\"/mcp\"" \
    --project="$RT" --limit=500 --format=json
  GW="$(v3h_json_last | jq -c '[.[] | (.httpRequest.requestUrl // "") as $u
    | select($u | test("lzv-mcp-(un)?reg-"))
    | {ts: (.timestamp | sub("\\.[0-9]+"; "") | fromdateiso8601),
       host: (if ($u | test("lzv-mcp-unreg-")) then "unreg" else "reg" end),
       status: (.httpRequest.status // null),
       denied: ((.jsonPayload // {}) | tostring | test("DENIED"))}]' 2>/dev/null || echo '[]')"
}
# match GW -> per-call rows: n records in window, any DENIED
match() {
  jq -c --argjson gw "$GW" '. as $c | ($gw | map(select(.host == $c.host and .ts >= ($c.start - 2) and .ts <= ($c.end + 2)))) as $m
    | $c + {n: ($m | length), denied: ($m | any(.denied))}' "$CALLS"
}

if [[ "$STAGE" == calls ]]; then
  AID_G="$(agents_tf '.agent_g.value.id' 2>/dev/null)" || AID_G=""
  [[ -n "$AID_G" && "$AID_G" != null ]] || guard_abort "deploy agent G first"
  : >"$CALLS"
  one() {  # one SERVER TOOL HOST EXPECTED
    local s e tr st
    export LZV_URL="https://${REGION}-aiplatform.googleapis.com/v1/${AID_G}:streamQuery?alt=sse"
    LZV_BODY="$(jq -cn --arg m "Call call_mcp_tool with server \"$1\" and tool \"$2\". Reply with the tool result." '{class_method:"async_stream_query", input:{user_id:"lzv-t56", message:$m}}')"
    export LZV_BODY
    s="$(date -u +%s)"
    run_capture_sh 'printf "Authorization: Bearer %s\n" "$(gcloud auth print-access-token)" | curl -sS -N --max-time 240 -H @- -H "Content-Type: application/json" -X POST "$LZV_URL" -d "$LZV_BODY" -w "\nHTTP %{http_code}\n" 2>&1'
    e="$(date -u +%s)"
    tr="$(sed 's/^data: *//' "$LZV_LAST_OUT" | jq -cR 'fromjson? | .. | objects | (.function_response // .functionResponse // empty)
      | select((.name // "") == "call_mcp_tool") | (.response // {}) | (if (.result|type) == "object" then .result else . end)
      | select(type == "object")' 2>/dev/null | head -1)"
    st="$(jq -r '(.status // "none") | tostring' <<<"${tr:-{\}}" 2>/dev/null || echo none)"
    jq -cn --arg tool "$2" --arg host "$3" --arg exp "$4" --arg st "$st" --argjson s "$s" --argjson e "$e" \
      '{tool:$tool, host:$host, expected:$exp, status:$st, start:$s, end:$e, usable:($st == "200" or $st == "403")}' >>"$CALLS"
  }
  for _ in 1 2 3 4 5; do one registered registered_echo reg 200; done
  for _ in 1 2 3 4 5; do one unregistered unregistered_echo unreg 403; done
  for _ in 1 2 3; do one registered inject_response reg 403; done
  note "calls (tool status): $(jq -rs 'group_by(.tool) | map("\(.[0].tool): \(map(.status) | join(","))") | join("; ")' "$CALLS")"
  sleep 180
  gw_read "$(iso "$(jq -s 'map(.start) | min - 5' "$CALLS")")"
  match >"$LZV_DIR/early.jsonl"
  note "early read (+3 min, observation): $(jq -rs '[.[] | select(.usable)] | "\(map(select(.n > 0)) | length)/\(length) usable calls have a record"' "$LZV_DIR/early.jsonl")"
  write_stage PASS "calls made: $(jq -s 'length' "$CALLS"); early read recorded (observation only)"
  exit 0
fi

# --- late
[[ -s "$CALLS" ]] || guard_abort "run stage calls first (same RUN_ID)"
LAST="$(jq -s 'map(.end) | max' "$CALLS")"
(( $(date -u +%s) >= LAST + 900 )) || guard_abort "stage late needs >= 15 min after the last call (pre-registered)"
gw_read "$(iso "$(jq -s 'map(.start) | min - 5' "$CALLS")")"
match >"$LZV_DIR/late.jsonl"
ROWS="$(jq -rs 'group_by(.tool) | map("\(.[0].tool): " + (map("\(.status)/n=\(.n)\(if .denied then "/D" else "" end)") | join(","))) | join("; ")' "$LZV_DIR/late.jsonl")"
MISS="$(jq -s '[.[] | select(.usable and .n == 0)] | length' "$LZV_DIR/late.jsonl")"
NODENY="$(jq -s '[.[] | select(.status == "403" and .n > 0 and (.denied | not))] | length' "$LZV_DIR/late.jsonl")"
LAG="$(jq -s --slurpfile e "$LZV_DIR/early.jsonl" '[range(0; length) as $i | select(.[$i].usable and .[$i].n > 0 and ($e[$i].n // 0) == 0)] | length' "$LZV_DIR/late.jsonl" 2>/dev/null || echo '?')"
DUP="$(jq -s '[.[] | select(.n > 1)] | length' "$LZV_DIR/late.jsonl")"
LOW="$(jq -rs 'group_by(.tool) | map(select((map(select(.usable)) | length) < 3) | .[0].tool) | join(",")' "$LZV_DIR/late.jsonl")"
UNUSABLE="$(jq -s '[.[] | select(.usable | not)] | length' "$LZV_DIR/late.jsonl")"
note "late read: $ROWS (n = records in window, D = DENIED)"
note "missing=$MISS, 403 without DENIED=$NODENY, late-only (lag)=$LAG, calls with >1 record=$DUP, excluded (no tool result)=$UNUSABLE"

V=PASS; W=""
if [[ "$MISS" -gt 0 || "$NODENY" -gt 0 ]]; then V=FAIL; W="F24 reproduces: $MISS usable calls without a gateway_requests record, $NODENY 403 calls without DENIED (late read, >= 15 min)"
elif [[ -n "$LOW" ]]; then V=INCONCLUSIVE; W="fewer than 3 usable calls for: $LOW"; fi
write_stage "$V" "late: missing=$MISS nodeny=$NODENY lag=$LAG"
write_result "$V" Configured "$ROWS; missing=$MISS; 403 without DENIED=$NODENY; late-only (lag)=$LAG; >1 record=$DUP; excluded=$UNUSABLE" "$W"
