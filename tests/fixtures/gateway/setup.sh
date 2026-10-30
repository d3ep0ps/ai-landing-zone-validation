#!/usr/bin/env bash
# v2 B setup (T30, T31b, T32). Run order on day 3 (tests/RUN-ORDER-run6.md, stage 3-0):
#   1. HUMAN: setup.sh preflight          creates a throwaway gateway in europe-west1 (GA, billed per hour)
#   2. HUMAN: teardown.sh preflight       deletes it (REST DELETE, no terminal needed)
#      If step 1 was refused for the location: area B is NOT_TESTED; stop here.
#   3. HUMAN: terraform apply in infra/ with enable_v2_gateway=true (+ enable_v2_model_armor=true)
#   4.        setup.sh build              Cloud Build -> Artifact Registry repo lzv-gw (created by step 3)
#   5.        setup.sh deploy             two Cloud Run services (internal ingress, IAM invoker, Binary Auth default)
#      wait about 4 minutes for registry propagation (third-party quickstart figure, UNVERIFIED)
#   6. HUMAN: build agent G (agent_g/build.sh), deploy_agent_g=true in infra/agents
# Everything else (registry, gateway, authz extensions/policies, IAM) is Terraform: infra/v2-gateway.tf.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

cmd="${1:-}"
case "$cmd" in
preflight)
  # Location check (the list call returns 200 for any valid region and proves nothing).
  # YAML keys per notes/doc-verification-v2-B.md section 2; the form of `name` is UNVERIFIED (full path used).
  y="$(mktemp)"; trap 'rm -f "$y"' EXIT
  cat >"$y" <<YAML
name: projects/$P/locations/$REGION/agentGateways/$GW_PREFLIGHT
protocols:
- MCP
googleManaged:
  governedAccessPath: AGENT_TO_ANYWHERE
registries:
- //agentregistry.googleapis.com/projects/$P/locations/$REGION
YAML
  out="$OUT_DIR/gateway-preflight.txt"
  echo "gcloud alpha network-services agent-gateways import $GW_PREFLIGHT --source=<tmp yaml> --location=$REGION --project=<runtime>" >"$out"
  gcloud alpha network-services agent-gateways import "$GW_PREFLIGHT" --source="$y" --location="$REGION" --project="$P" >>"$out" 2>&1
  rc=$?
  echo "rc=$rc" >>"$out"
  if [[ $rc -eq 0 ]]; then
    gcloud alpha network-services agent-gateways describe "$GW_PREFLIGHT" --location="$REGION" --project="$P" --format='value(name)' >>"$out" 2>&1
    echo "PREFLIGHT: create ACCEPTED in $REGION. Now run: teardown.sh preflight (deletes it). Proceed to terraform apply."
  else
    echo "PREFLIGHT: create REFUSED in $REGION (rc=$rc). Read the reason; if it names the location, area B is NOT_TESTED."
    echo "A refusal for another reason (API not enabled on the quota project, permission) is NOT a location answer: fix and retry."
  fi
  tail -n 8 "$out"
  ;;
build)
  # Regional user-owned staging bucket (<project>_<region>_cloudbuild): the default bucket is created in 'us',
  # which gcp.resourceLocations refuses (412; run-6 day 3, as T10 run-1). See teardown.sh.
  gcloud builds submit "$HERE/mcp" --tag="$IMAGE" --project="$P" --region="$REGION" \
    --default-buckets-behavior=regional-user-owned-bucket >"$OUT_DIR/gateway-build.txt" 2>&1
  echo "build rc=$?"; tail -n 5 "$OUT_DIR/gateway-build.txt"
  ;;
deploy)
  member="$(jq -er '.v2_gateway_agent_member.value' <<<"$TFJ")" || die "infra/ output v2_gateway_agent_member missing (enable_v2_gateway applied?)"
  for pair in "$REG_SVC:registered" "$UNREG_SVC:unregistered"; do
    svc="${pair%%:*}"; prof="${pair##*:}"
    # Same flags as tests/T02.sh and T17.sh: folder policies run.allowedIngress=internal,
    # run.managed.requireInvokerIam, Binary Authorization default.
    gcloud run deploy "$svc" --image="$IMAGE" --region="$REGION" --project="$P" \
      --ingress=internal --no-allow-unauthenticated --binary-authorization=default \
      --set-env-vars="MCP_PROFILE=$prof" >>"$OUT_DIR/gateway-deploy.txt" 2>&1
    echo "deploy $svc rc=$?"
    # Invoker for the agent principalSet (UNVERIFIED that Cloud Run IAM accepts an agent principalSet).
    gcloud run services add-iam-policy-binding "$svc" --region="$REGION" --project="$P" \
      --member="$member" --role=roles/run.invoker >>"$OUT_DIR/gateway-deploy.txt" 2>&1
    echo "invoker $svc rc=$?"
  done
  tail -n 4 "$OUT_DIR/gateway-deploy.txt"
  ;;
*) die "usage: setup.sh preflight|build|deploy" ;;
esac
