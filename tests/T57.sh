#!/usr/bin/env bash
# T57 (results.md Findings 24 / claims-register F20 re-check): does a Terraform destroy of a Model Armor floor setting
# leave the floor in place? Plan: plans/v3-harness-boundary-tests.md section 3b (pre-registered 2026-11-12, commit 31baf11,
# before this script). Target: the runtime project floor, google_model_armor_floorsetting.v2_project[0], provider 8.8.0.
# Run 10 (2026-11-21): the floor is now module.prj_runtime.google_model_armor_floorsetting.default[0] (Fabric modules/project, provider 8.12.0);
# addresses below updated, expected text unchanged. Past results refer to the old address.
# The orchestrator (tests/run-v3h.sh t57 1) runs the Terraform steps; this script only reads.
#   before    raw describe + state entry; checks the floor matches the baseline
#   after     (orchestrator: targeted destroy, enforcement left on) state list; raw describe at +1 min and +5 min
#   restored  (orchestrator: baseline apply of that address) raw describe; plan of the floor addresses; writes the result
# Expected: after the destroy the address is gone from state and the describe shows the before content (filterConfig
# pi_and_jailbreak MEDIUM_AND_ABOVE, integratedServices AI_PLATFORM, updateTime unchanged). Falsified if: 404/NOT_FOUND,
# a reset floor, or updateTime changed. Enforcement after the destroy is recorded without prediction.
# shellcheck disable=SC2016
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_config

STAGE="${1:-}"
case "$STAGE" in before|after|restored) ;; *) lzv_die "usage: T57.sh before|after|restored" ;; esac
RT="$(project_id runtime)"
LZV_SCOPE="projects/$RT"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/model-armor/configure-floor-settings"
  "https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/model_armor_floorsetting"
)
header T57 "Findings 24 / F20 re-check (Configured)" "Targeted Terraform destroy (provider 8.8.0) of the runtime project Model Armor floor setting with enforcement on; raw floor describe before, +1 min and +5 min after, and after the restore" \
  "After the destroy the address is gone from Terraform state and the floor describe still shows the before content: same filterConfig (pi_and_jailbreak, MEDIUM_AND_ABOVE), integratedServices with AI_PLATFORM, updateTime unchanged. Falsified if: the describe fails with 404/NOT_FOUND, shows a reset floor (no pi_and_jailbreak filter or no integratedServices), or updateTime changed. Recorded without prediction: enableFloorSettingEnforcement after the destroy. INCONCLUSIVE if: the before describe does not match the baseline. Tier: Configured. 1 run." \
  "$STAGE"
note "Findings 24 (run 6, run-7 log); this script only reads; the orchestrator destroys and restores the floor"
ADDR='module.prj_runtime.google_model_armor_floorsetting.default[0]'
PROV="$(grep -A2 'registry.terraform.io/hashicorp/google"' "$LZV_ROOT/infra/.terraform.lock.hcl" | sed -nE 's/.*version *= *"([^"]+)".*/\1/p' | head -1)"

# fs_read TAG -> writes $LZV_DIR/fs-TAG.json {rc, notfound, enforce, pi, conf, integrated, update, create}
fs_read() {
  run_capture env CLOUDSDK_API_ENDPOINT_OVERRIDES_MODELARMOR=https://modelarmor.googleapis.com/ \
    gcloud model-armor floorsettings describe --full-uri="projects/$RT/locations/global/floorSetting" --format=json
  local nf=false; grep -qE 'NOT_FOUND|404' "$LZV_LAST_OUT" && [[ "$LZV_LAST_RC" != 0 ]] && nf=true
  if [[ "$LZV_LAST_RC" == 0 ]]; then
    v3h_json_last_fs | jq -c --argjson rc 0 --argjson nf false '{rc:$rc, notfound:$nf,
      enforce: (.enableFloorSettingEnforcement // false),
      pi: (.filterConfig.piAndJailbreakFilterSettings.filterEnforcement // ""),
      conf: (.filterConfig.piAndJailbreakFilterSettings.confidenceLevel // ""),
      integrated: ((.integratedServices // []) | join(",")),
      update: (.updateTime // ""), create: (.createTime // "")}' >"$LZV_DIR/fs-$1.json"
  else
    jq -cn --argjson rc "$LZV_LAST_RC" --argjson nf "$nf" '{rc:$rc, notfound:$nf}' >"$LZV_DIR/fs-$1.json"
  fi
  note "floor $1: $(cat "$LZV_DIR/fs-$1.json")"
}
v3h_json_last_fs() { sed -n '/^{/,$p' "$LZV_LAST_OUT"; }   # the JSON object in the captured output
in_state() {
  run_capture terraform -chdir="$LZV_ROOT/infra" state list
  IN_STATE="$(grep -cxF "$ADDR" "$LZV_LAST_OUT" || true)"
  note "terraform state: $ADDR present=$IN_STATE"
}
same_as_before() {  # same_as_before TAG -> 0 if content and updateTime equal stage before
  jq -e -s '.[0] as $b | .[1] as $a | $a.rc == 0 and $a.pi == $b.pi and $a.conf == $b.conf and $a.integrated == $b.integrated and $a.update == $b.update and $a.create == $b.create' \
    "$LZV_DIR/fs-before.json" "$LZV_DIR/fs-$1.json" >/dev/null
}

case "$STAGE" in
before)
  note "provider hashicorp/google $PROV (infra/.terraform.lock.hcl)"
  fs_read before; in_state
  if jq -e '.rc == 0 and .enforce == true and .pi == "ENABLED" and .conf == "MEDIUM_AND_ABOVE" and (.integrated | test("AI_PLATFORM"))' "$LZV_DIR/fs-before.json" >/dev/null && [[ "$IN_STATE" == 1 ]]; then
    write_stage PASS "baseline floor read: $(cat "$LZV_DIR/fs-before.json"); in state; provider $PROV"
  else
    write_stage INCONCLUSIVE "before does not match the baseline (enforce on, pi ENABLED MEDIUM_AND_ABOVE, AI_PLATFORM, in state): $(cat "$LZV_DIR/fs-before.json"); in state=$IN_STATE"
  fi ;;
after)
  [[ "$(read_stage before)" == PASS ]] || guard_abort "stage before did not pass"
  in_state; fs_read after1
  sleep 240
  fs_read after5
  ENF="$(jq -r '.enforce // "n/a"' "$LZV_DIR/fs-after5.json")"
  V=PASS; W=""
  if [[ "$IN_STATE" != 0 ]]; then V=INCONCLUSIVE; W="the address is still in state (destroy did not apply)"
  elif jq -e '.notfound' "$LZV_DIR/fs-after5.json" >/dev/null; then V=FAIL; W="the floor is gone (NOT_FOUND): the destroy deleted it"
  elif ! jq -e '.rc == 0' "$LZV_DIR/fs-after5.json" >/dev/null; then V=INCONCLUSIVE; W="describe failed (not NOT_FOUND)"
  elif ! same_as_before after5 || ! same_as_before after1; then V=FAIL; W="the floor changed after the destroy (reset or updated): $(cat "$LZV_DIR/fs-after5.json")"
  fi
  write_stage "$V" "not in state; floor +5 min: $(cat "$LZV_DIR/fs-after5.json"); enforcement after destroy=$ENF${W:+; $W}" ;;
restored)
  fs_read restored; in_state
  run_capture terraform -chdir="$LZV_ROOT/infra" plan -no-color -input=false -detailed-exitcode -var-file=terraform.tfvars -var-file=profiles/lz-5-reference.tfvars -var-file=profiles/v3h-baseline.tfvars \
    -target='module.prj_runtime.google_model_armor_floorsetting.default[0]' -target='module.folder_root.google_model_armor_floorsetting.default[0]'
  PLAN_RC="$LZV_LAST_RC"
  OK=0
  jq -e -s '.[0] as $b | .[1] as $a | $a.rc == 0 and $a.enforce == true and $a.pi == $b.pi and $a.conf == $b.conf and $a.integrated == $b.integrated' \
    "$LZV_DIR/fs-before.json" "$LZV_DIR/fs-restored.json" >/dev/null && [[ "$IN_STATE" == 1 && "$PLAN_RC" == 0 ]] && OK=1
  echo "$OK" >"$LZV_DIR/restore-ok"
  note "restore check: ok=$OK (in state=$IN_STATE, floor-address plan exit=$PLAN_RC: 0 = no change)"
  sa="$(read_stage after)"; [[ "$sa" == MISSING ]] && sa=INCONCLUSIVE
  write_stage "$([[ "$OK" == 1 ]] && echo PASS || echo INCONCLUSIVE)" "restore ok=$OK"
  AN="$(jq -r '.note // ""' "$LZV_DIR/stages/after.json" 2>/dev/null)"
  W=""; [[ "$sa" == PASS ]] || W="after: $AN"
  [[ "$OK" == 1 ]] || W+="${W:+; }restore did not match the before state (human check needed)"
  write_result "$sa" Configured "provider $PROV; before: $(cat "$LZV_DIR/fs-before.json"); after: $AN; restored: $(cat "$LZV_DIR/fs-restored.json"), restore ok=$OK" "$W" ;;
esac
