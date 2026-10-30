#!/usr/bin/env bash
# T38 (v2 A/D, ORGANIZATION SCOPE): the organization-level Model Armor floor setting is inherited by
# a project with no project floor of its own. The human applies the org floor alone (E4.2).
# Needs enable_v2_ma_org_floor=true, enable_v2_ma_folder_floor off AND the folder floor not
# enforcing (a lower-level floor takes precedence), run-6 stage 1-3, floor propagated.
# Runs in the DATA project. Creates three templates there; all are deleted by exact name on exit.
# Read-only only: no project floor setting is created.
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
ORG="$(org_id)"
LZV_SCOPE="projects/$(project_id data)"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/model-armor/configure-floor-settings"
  "https://docs.cloud.google.com/model-armor/manage-templates"
)
P="$(project_id data)"
LOC="$LZV_REGION"
[[ "$LOC" == europe-west1 ]] || lzv_die "T38 expects LZV_REGION=europe-west1 (template region of the v2 infra)"

header T38 "A/D" "Org-level floor setting (human applies, E4.2); create a weak template in a test project with no project floor" \
  'Weak template refused, as T27'
note "paired control: a template at the org floor (filter enabled, MEDIUM_AND_ABOVE) is created. Weak variants: filter disabled, and HIGH only. Control cell of the plan also names a separate observation (a project-level floor that relaxes the org floor): NOT done here, it needs a project floor setting to be created; only the read-only state of the data project floor is recorded"
note "limitation: the error text is undocumented; the verdict rests on exit codes and a describe NOT_FOUND check, not on a message. Client-side usage errors are excluded from a PASS"

json_last() { sed -n '/^[[{]/,$p' "$LZV_LAST_OUT"; }

# --- Guards: org floor on and enforcing; folder floor off; no project floor in the data project ---
[[ "$(lzv_tf '.v2_ma_template_id.value // "off"')" != off ]] || note "enable_v2_model_armor is off (fine: T38 uses its own templates)"
floor_state() {  # floor_state PARENT -> FS_RC, FS_ENF (true|false|unknown), FS_JSON
  run_capture env CLOUDSDK_API_ENDPOINT_OVERRIDES_MODELARMOR=https://modelarmor.googleapis.com/ gcloud model-armor floorsettings describe --full-uri="$1/locations/global/floorSetting" --format=json
  FS_RC="$LZV_LAST_RC"; FS_JSON="$(json_last)"; FS_ENF=unknown
  if [[ "$FS_RC" == 0 ]]; then
    FS_ENF="$(jq -r '(.enableFloorSettingEnforcement // .enable_floor_setting_enforcement // false) | tostring' <<<"$FS_JSON" 2>/dev/null)" || FS_ENF=unknown
  fi
}
floor_state "organizations/$ORG"
[[ "$FS_RC" == 0 ]] || guard_abort "org floor setting cannot be read (enable_v2_ma_org_floor off, or floorSettingsAdmin missing on the organization)"
[[ "$FS_ENF" == true ]] || guard_abort "org floor setting enforcement is '$FS_ENF', need true"
grep -qi 'jailbreak' <<<"$FS_JSON" || guard_abort "org floor setting has no prompt injection / jailbreak filter"
grep -q 'MEDIUM_AND_ABOVE' <<<"$FS_JSON" || note "WARNING: MEDIUM_AND_ABOVE not found in the org floor describe output"
note "org floor setting present, enforcement=true"

floor_state "folders/$FOLDER"
if [[ "$FS_RC" == 0 ]]; then
  [[ "$FS_ENF" != true ]] || guard_abort "folder floor setting is still enforcing: it takes precedence over the org floor. Disable it first (enable_v2_ma_folder_floor=false removes it from state only; set enableFloorSettingEnforcement=false on the folder)"
  note "folder floor setting readable, enforcement=$FS_ENF"
elif last_output_matches 'NOT_FOUND|not found|Not Found|404'; then
  note "folder floor setting: none"
else
  guard_abort "folder floor setting state cannot be established (exit $FS_RC)"
fi

floor_state "projects/$P"
if [[ "$FS_RC" == 0 ]]; then
  [[ "$FS_ENF" != true ]] || guard_abort "the data project has an enforcing project floor setting; T38 needs a project with none"
  note "observation (read-only): data project floor setting readable, enforcement=$FS_ENF, integrated services/filters: $(jq -c '{integratedServices, filterConfig}' <<<"$FS_JSON" 2>/dev/null | cut -c1-300)"
elif last_output_matches 'NOT_FOUND|not found|Not Found|404'; then
  note "observation (read-only): data project has no floor setting"
else
  guard_abort "data project floor setting state cannot be established (exit $FS_RC)"
fi

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
  FINAL=INCONCLUSIVE; REASON="paired control failed (template at the org floor not created; modelarmor.googleapis.com enabled in the data project?): $R_CTRL; ${R_ATT}"
else
  FINAL="$V_ATT"; REASON="$R_ATT"
fi
TIER=Configured; [[ "$FINAL" == PASS ]] && TIER=Enforced
write_result "$FINAL" "$TIER" "at-floor template: $V_CTRL; weak (filter off): $C_OFF, exists=$E_OFF; weak (HIGH only): $C_HI, exists=$E_HI" "$REASON"
