#!/usr/bin/env bash
# T16 (v1.1): Secure Web Proxy (explicit proxy) plus egress firewall for a Cloud Run job with
# Direct VPC egress. Needs terraform swp_enabled=true (paid, about USD 1.25 per gateway-hour plus
# USD 0.018/GB; destroy the same day with swp_enabled=false, see tests/RUN-ORDER-v11-c.md).
# The v1 script was a NOT_TESTED placeholder ("deferred to v1.1"); it stays in git history.
# Three jobs in the runtime project, one per case: (1) allowed host via proxy, (2) non-allowed host
# via proxy, (3) allowed host with the proxy bypassed. Results are read from the execution logs.
# Job cleanup: `gcloud run jobs delete` is attempted without --quiet (the --quiet exception covers
# Cloud Run services only). If it needs a terminal, delete the three jobs by hand (names are printed
# by `note` and listed in output.txt).
# shellcheck disable=SC2016
set -u
source "$(dirname "$0")/lib.sh"
require_config

RT="$(project_id runtime)"
LZV_SCOPE="projects/$RT"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/secure-web-proxy/docs/quickstart"
  "https://docs.cloud.google.com/secure-web-proxy/docs/monitor-logs"
  "https://docs.cloud.google.com/run/docs/configuring/vpc-direct-vpc"
  "https://cloud.google.com/secure-web-proxy/pricing"
)
header T16 Reach "DC5: Secure Web Proxy plus egress firewall, Cloud Run job with Direct VPC egress" \
  'Allowed host via proxy: 200; non-allowed host: HTTP 403 on CONNECT, `gateway_requests` log with `DENIED`; proxy bypassed: timeout (firewall), not a DNS error. Agent Runtime via PSC interface out of scope'
note "cost: Secure Web Proxy about USD 1.25 per gateway-hour plus USD 0.018/GB; billed until the gateway is destroyed (swp_enabled=false)"

REGION="$LZV_REGION"
NET="$(lzv_tf '.swp_vpc_name.value')"
SUBNET="$(lzv_tf '.swp_job_subnet_name.value')"
GW="$(lzv_tf '.swp_gateway_name.value')"
PROXY="$(lzv_tf '.swp_proxy_url.value')"
IMAGE="${T16_IMAGE:-docker.io/curlimages/curl:8.10.1}"   # pinned tag; override if Cloud Run rejects docker.io
ALLOWED="${SWP_ALLOWED_HOST:-example.com}"                # must equal terraform swp_allowed_host
DENIED_HOST="www.google.com"
json_last() { sed -n '/^[[{]/,$p' "$LZV_LAST_OUT"; }

# --- Guard: the gateway exists ---
run_capture gcloud network-services gateways describe "$GW" --location="$REGION" --project="$RT"
[[ "$LZV_LAST_RC" == 0 ]] || guard_abort "Secure Web Proxy gateway $GW not found; apply with swp_enabled=true"
GW_CREATED="$(sed -n 's/^createTime: *//p' "$LZV_LAST_OUT" | head -1)"
note "gateway $GW exists (createTime ${GW_CREATED:-unknown}); proxy $PROXY; allowed host $ALLOWED"

J1="$(lzv_name t16a)"; J2="$(lzv_name t16b)"; J3="$(lzv_name t16c)"
note "job names (delete by hand if cleanup cannot confirm): $J1 $J2 $J3"
for j in "$J1" "$J2" "$J3"; do
  cleanup_trap "gcloud run jobs describe $j --region=$REGION --project=$RT --format='value(metadata.name)'"
  cleanup_trap "gcloud run jobs delete $j --region=$REGION --project=$RT"
done

# run_case JOB LABEL CURL_ARGS... -> creates the job, executes it, reads its logs into CASE_LOG (file)
run_case() {
  local job="$1" label="$2"; shift 2
  local args exec_name i
  args="^@^-sS@-o@/dev/null@-w@LZV_CODE=%{http_code}@$(printf '%s@' "$@")"
  args="${args%@}"
  run_capture gcloud run jobs create "$job" --image="$IMAGE" --region="$REGION" --project="$RT" \
    --network="$NET" --subnet="$SUBNET" --vpc-egress=all-traffic --binary-authorization=default \
    --max-retries=0 --task-timeout=240s --args="$args"
  [[ "$LZV_LAST_RC" == 0 ]] || { CASE_RC=create; return 1; }
  run_capture gcloud run jobs execute "$job" --region="$REGION" --project="$RT" --wait
  CASE_RC="$LZV_LAST_RC"
  run_capture gcloud run jobs executions list --job="$job" --region="$REGION" --project="$RT" --format='value(name)' --limit=1
  exec_name="$(head -1 "$LZV_LAST_OUT" | tr -d '[:space:]')"
  [[ -n "$exec_name" ]] || { CASE_RC=noexec; return 1; }
  note "case $label: job $job execution $exec_name exit $CASE_RC"
  CASE_LOG="$LZV_ROOT/scratch/t16-$label-$RUN_ID.log"
  mkdir -p "$LZV_ROOT/scratch"
  for i in 1 2 3 4; do   # logs can lag the execution
    run_capture gcloud logging read "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"$job\" AND labels.\"run.googleapis.com/execution_name\"=\"$exec_name\"" \
      --project="$RT" --freshness=1h --order=asc --format='value(textPayload)'
    if grep -Eq 'LZV_CODE=|curl: \(' "$LZV_LAST_OUT"; then break; fi
    sleep 20
  done
  cp "$LZV_LAST_OUT" "$CASE_LOG"
  cleanup_trap "rm -f $CASE_LOG"
  note "case $label log: $(tr '\n' ' ' <"$CASE_LOG" | cut -c1-300)"
  return 0
}

# --- Case 1: allowed host through the proxy (positive control) ---
V1=INCONCLUSIVE; R1=""
if run_case "$J1" allowed --proxy "$PROXY" "https://$ALLOWED"; then
  if grep -q 'LZV_CODE=200' "$CASE_LOG"; then V1=PASS; OBS1="allowed host via proxy: 200"
  else V1=FAIL; OBS1="allowed host via proxy: no 200 ($(tr '\n' ' ' <"$CASE_LOG" | cut -c1-120))"; R1="allowed host not reachable through the proxy"; fi
else
  OBS1="case 1 not completed ($CASE_RC)"; R1="job could not be created or read ($CASE_RC)"
fi

# --- Case 2: non-allowed host through the proxy ---
V2=INCONCLUSIVE; R2=""
if run_case "$J2" denied --proxy "$PROXY" "https://$DENIED_HOST"; then
  if grep -Eq 'CONNECT tunnel failed, response 403|LZV_CODE=403' "$CASE_LOG"; then
    run_capture gcloud logging read "logName=\"projects/$RT/logs/networkservices.googleapis.com%2Fgateway_requests\" AND jsonPayload.enforcedGatewaySecurityPolicy.matchedRules.action=\"DENIED\"" \
      --project="$RT" --freshness=1h --limit=5 --format=json
    if last_output_matches 'DENIED'; then V2=PASS; OBS2="non-allowed host: 403 on CONNECT; gateway_requests DENIED entry present"
    else V2=INCONCLUSIVE; OBS2="non-allowed host: 403 on CONNECT; no DENIED gateway_requests entry yet"; R2="403 seen but no gateway_requests DENIED entry found (log lag?)"; fi
  elif grep -q 'LZV_CODE=200' "$CASE_LOG"; then
    V2=FAIL; OBS2="non-allowed host reached through the proxy (200)"; R2="proxy allowed a host outside the allow rule"
  else
    OBS2="non-allowed host: no 403 ($(tr '\n' ' ' <"$CASE_LOG" | cut -c1-120))"; R2="no 403 on CONNECT and no 200"
  fi
else
  OBS2="case 2 not completed ($CASE_RC)"; R2="job could not be created or read ($CASE_RC)"
fi

# --- Case 3: allowed host, proxy bypassed ---
V3=INCONCLUSIVE; R3=""
if run_case "$J3" bypass --noproxy '*' --connect-timeout 10 "https://$ALLOWED"; then
  if grep -Eq 'Could not resolve host|curl: \(6\)' "$CASE_LOG"; then
    V3=FAIL; OBS3="bypass: DNS error, not a timeout"; R3="expected a firewall timeout, got a DNS resolution error"
  elif grep -Eiq 'timed out|curl: \(28\)' "$CASE_LOG"; then
    V3=PASS; OBS3="bypass: connection timed out (not DNS)"
  elif grep -q 'LZV_CODE=200' "$CASE_LOG"; then
    V3=FAIL; OBS3="bypass: direct connection succeeded (200)"; R3="egress firewall did not block the direct connection"
  else
    OBS3="bypass: unclassified ($(tr '\n' ' ' <"$CASE_LOG" | cut -c1-120))"; R3="neither timeout, DNS error nor 200 in the job log"
  fi
else
  OBS3="case 3 not completed ($CASE_RC)"; R3="job could not be created or read ($CASE_RC)"
fi

note "gateway createTime ${GW_CREATED:-unknown}; cost accrues until swp_enabled=false is applied (about USD 1.25/gateway-hour)"
ACTUAL="$OBS1; $OBS2; $OBS3"
if [[ "$V1" != PASS ]]; then
  FINAL=INCONCLUSIVE
  write_result "$FINAL" Enforced "$ACTUAL" "positive control (allowed host via proxy) did not succeed, so the denials prove nothing: ${R1:-n/a}"
else
  FINAL="$(verdict_merge "$V2" "$V3")"
  REASONS=""; [[ "$V2" == PASS ]] || REASONS+="denied host: $R2; "; [[ "$V3" == PASS ]] || REASONS+="bypass: $R3; "
  if [[ "$FINAL" == PASS ]]; then write_result PASS Enforced "$ACTUAL"; else write_result "$FINAL" Enforced "$ACTUAL" "$REASONS"; fi
fi
