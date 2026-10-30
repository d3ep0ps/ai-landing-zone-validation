#!/usr/bin/env bash
# T27 (v2 A): Model Armor folder floor setting refuses a template weaker than the floor.
# Needs enable_v2_model_armor=true and enable_v2_ma_folder_floor=true (run-6 stage 1-2) and the
# floor to have propagated ("a few minutes"). Creates three templates in the runtime project
# (one at the floor, two weaker); all are deleted by exact name on exit.
# The verdict uses exit codes and a describe check only; the error text is recorded as observed.
# shellcheck disable=SC2016,SC2119
set -u
source "$(dirname "$0")/lib.sh"
require_config
# gcloud endpoints (added 2026-10-27, run-6, after T28 aborted in its precheck): without an override,
# gcloud model-armor sends every call to modelarmor.us-central1.rep.googleapis.com, whatever --location
# says, and the call is refused with PERMISSION_DENIED. Templates use the regional endpoint
# modelarmor.LOC.rep.googleapis.com; floor settings (locations/global) use modelarmor.googleapis.com.

FOLDER="$(folder_id root)"
LZV_SCOPE="folders/$FOLDER"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/model-armor/configure-floor-settings"
  "https://docs.cloud.google.com/model-armor/manage-templates"
)
P="$(project_id runtime)"
LOC="$LZV_REGION"
[[ "$LOC" == europe-west1 ]] || lzv_die "T27 expects LZV_REGION=europe-west1 (template region of the v2 infra)"

header T27 "A" "Folder floor setting on (prompt injection and jailbreak, MEDIUM_AND_ABOVE, enforcement on). Create a project template with the filter off or at HIGH only" \
  'Weak template create fails (non-zero exit, error from `modelarmor.googleapis.com`; text recorded as observed); the weak template does not exist afterwards'
note "paired control: a template at the floor (filter enabled, MEDIUM_AND_ABOVE) is created. Weak variants: filter disabled, and HIGH only"
note "limitation: the error text is undocumented; the verdict rests on exit codes and a describe NOT_FOUND check, not on a message. Client-side usage errors are excluded from a PASS"

json_last() { sed -n '/^[[{]/,$p' "$LZV_LAST_OUT"; }

# --- Guards: toggles on, floor present and enforced ---------------------------
TPL_ID_OUT="$(lzv_tf '.v2_ma_template_id.value // "off"')"
[[ "$TPL_ID_OUT" != off ]] || guard_abort "enable_v2_model_armor is off (output v2_ma_template_id is null)"
run_capture env CLOUDSDK_API_ENDPOINT_OVERRIDES_MODELARMOR=https://modelarmor.googleapis.com/ gcloud model-armor floorsettings describe --full-uri="folders/$FOLDER/locations/global/floorSetting" --format=json
[[ "$LZV_LAST_RC" == 0 ]] || guard_abort "folder floor setting cannot be read (enable_v2_ma_folder_floor off, or floorSettingsAdmin missing on the folder)"
FS_ENF="$(json_last | jq -r '(.enableFloorSettingEnforcement // .enable_floor_setting_enforcement // false) | tostring' 2>/dev/null)"
[[ "$FS_ENF" == true ]] || guard_abort "folder floor setting enforcement is '$FS_ENF', need true (v2_ma_floor_enforce)"
json_last | grep -qi 'jailbreak' || guard_abort "folder floor setting has no prompt injection / jailbreak filter"
json_last | grep -q 'MEDIUM_AND_ABOVE' || note "WARNING: MEDIUM_AND_ABOVE not found in the floor describe output (casing or field name differs?)"
note "folder floor setting present, enforcement=true"

tpl_create() {  # tpl_create NAME ok|off|high
  local lvl=MEDIUM_AND_ABOVE enf=enabled
  local -a args=()
  case "$2" in off) enf=disabled ;; high) lvl=HIGH ;; esac
  [[ "$2" == off ]] || args+=("--pi-and-jailbreak-filter-settings-confidence-level=$lvl")
  run_capture env CLOUDSDK_API_ENDPOINT_OVERRIDES_MODELARMOR="https://modelarmor.${LOC}.rep.googleapis.com/" gcloud model-armor templates create "$1" --project="$P" --location="$LOC" \
    --pi-and-jailbreak-filter-settings-enforcement="$enf" \
    --malicious-uri-filter-settings-enforcement=enabled "${args[@]}"
}
tpl_exists() {  # sets T_EX = yes | no | unknown
  run_capture env CLOUDSDK_API_ENDPOINT_OVERRIDES_MODELARMOR="https://modelarmor.${LOC}.rep.googleapis.com/" gcloud model-armor templates describe "$1" --project="$P" --location="$LOC" --format='value(name)'
  if [[ "$LZV_LAST_RC" == 0 ]]; then T_EX=yes
  elif last_output_matches 'NOT_FOUND|not found|Not Found|404'; then T_EX=no
  else T_EX=unknown; fi
}
# Delete by exact name through REST: `gcloud model-armor templates delete` asks for confirmation,
# and --quiet is not allowed on deletes (CLAUDE.md). The token goes to curl on stdin, never to a file.
ma_delete_cmd() {
  printf '%s' "printf 'Authorization: Bearer %s\\nx-goog-user-project: %s\\n' \"\$(gcloud auth print-access-token)\" '$P' | curl -sS --max-time 60 -H @- -X DELETE 'https://modelarmor.${LOC}.rep.googleapis.com/v1/projects/${P}/locations/${LOC}/templates/$1' -w '\\nHTTP %{http_code}\\n'"
}
reg_cleanup() {  # register BEFORE create
  cleanup_trap "$(ma_delete_cmd "$1") || echo 'template not present (expected when the create was refused)'"
}

OK_T="$(lzv_name t27ok)"; WOFF_T="$(lzv_name t27off)"; WHI_T="$(lzv_name t27hi)"
reg_cleanup "$OK_T"; reg_cleanup "$WOFF_T"; reg_cleanup "$WHI_T"

# --- Paired control: template at the floor -------------------------------------
tpl_create "$OK_T" ok
expect_success
V_CTRL="$LZV_VERDICT"; R_CTRL="$LZV_REASON"

# --- Attempts: weak templates ----------------------------------------------------
# weak_try NAME MODE -> W_CLASS = refused | created | clienterr | unknown
weak_try() {
  local try
  W_CLASS=unknown
  for try in 1; do  # single attempt (Opus review 2026-10-27: no retry)
    tpl_create "$1" "$2"
    if [[ "$LZV_LAST_RC" == 0 ]]; then
      W_CLASS=created
      note "weak template ($2) was created: recorded as observed (no retry; the stage runs at least 15 min after the floor apply)"
      break
    fi
    if last_output_matches 'unrecognized arguments|[Ii]nvalid choice|Invalid value for \[|^Usage:|expected one of'; then
      W_CLASS=clienterr
    else
      W_CLASS=refused
    fi
    note "weak template ($2) create exit=$LZV_LAST_RC class=$W_CLASS error (as observed): $(tr '\n' ' ' <"$LZV_LAST_OUT" | cut -c1-400)"
    break
  done
  tpl_exists "$1"
  note "weak template ($2) exists afterwards: $T_EX"
}

weak_try "$WOFF_T" off; C_OFF="$W_CLASS"; E_OFF="$T_EX"
weak_try "$WHI_T" high; C_HI="$W_CLASS"; E_HI="$T_EX"

# --- Verdict ----------------------------------------------------------------------
V_ATT=PASS; R_ATT=""
for v in "off:$C_OFF:$E_OFF" "high:$C_HI:$E_HI"; do
  IFS=: read -r m c e <<<"$v"
  if [[ "$c" == created || "$e" == yes ]]; then
    V_ATT=FAIL; R_ATT+="weak template ($m) was created or exists afterwards (floor not enforced at create); "
  elif [[ "$c" != refused || "$e" != no ]]; then
    [[ "$V_ATT" == FAIL ]] || V_ATT=INCONCLUSIVE
    R_ATT+="weak ($m): class=$c exists=$e, refusal not established; "
  fi
done

if [[ "$V_CTRL" != PASS ]]; then
  FINAL=INCONCLUSIVE; REASON="paired control failed (template at the floor not created): $R_CTRL; ${R_ATT}"
else
  FINAL="$V_ATT"; REASON="$R_ATT"
fi
TIER=Configured; [[ "$FINAL" == PASS ]] && TIER=Enforced
write_result "$FINAL" "$TIER" "at-floor template: $V_CTRL; weak (filter off): $C_OFF, exists=$E_OFF; weak (HIGH only): $C_HI, exists=$E_HI" "$REASON"
