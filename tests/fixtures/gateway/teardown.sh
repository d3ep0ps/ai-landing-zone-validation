#!/usr/bin/env bash
# v2 B teardown (stage 3-2). Order:
#   1. teardown.sh preflight        (only after setup.sh preflight; deletes lzv-gw-preflight)
#   2. teardown.sh run              (deletes the two Cloud Run services)
#   3. HUMAN: deploy_agent_g=false in infra/agents, apply (destroys agent G)
#   4. HUMAN: enable_v2_gateway=false (and the other toggles of the day) in infra/, apply
#      (destroys gateway, policies, extensions, registry entries, template, image repository)
#   5. HUMAN STEP (no prompt, needs no terminal): the Cloud Build staging bucket, if setup.sh build created it:
#        gcloud storage rm --recursive gs://<runtime project>_europe-west1_cloudbuild --project=<runtime project>  (regional user-owned bucket since run-6)
#      Check first that it holds only the fixture build (gcloud storage ls); it is not in Terraform state.
#   6. untargeted plan in infra/ shows no drift.
# Deletes are REST DELETE with the token on stdin (nothing prompts, no --quiet). They are long-running
# operations: the script prints the HTTP status, then the follow-up GET must return 404.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
out="$OUT_DIR/gateway-teardown.txt"

case "${1:-}" in
preflight)
  rest DELETE "https://networkservices.googleapis.com/v1alpha1/projects/$P/locations/$REGION/agentGateways/$GW_PREFLIGHT" >>"$out" 2>&1
  tail -n 3 "$out"
  echo "Wait about a minute, then: teardown.sh check-preflight (expect HTTP 404)"
  ;;
check-preflight)
  rest GET "https://networkservices.googleapis.com/v1alpha1/projects/$P/locations/$REGION/agentGateways/$GW_PREFLIGHT" | tail -n 1
  ;;
run)
  for svc in "$REG_SVC" "$UNREG_SVC"; do
    rest DELETE "https://run.googleapis.com/v2/projects/$P/locations/$REGION/services/$svc" >>"$out" 2>&1
    echo "delete $svc: $(tail -n 1 "$out")"
  done
  echo "Wait about a minute, then: teardown.sh check-run (expect HTTP 404 twice)"
  ;;
check-run)
  for svc in "$REG_SVC" "$UNREG_SVC"; do
    echo "$svc: $(rest GET "https://run.googleapis.com/v2/projects/$P/locations/$REGION/services/$svc" | tail -n 1)"
  done
  ;;
*) die "usage: teardown.sh preflight|check-preflight|run|check-run" ;;
esac
