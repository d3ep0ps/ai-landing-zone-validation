# shellcheck shell=bash disable=SC2034
# Shared helpers for tests/TNN.sh (EXECUTION-PLAN.md Appendix C).
#
# Usage in a test script:
#   set -u
#   source "$(dirname "$0")/lib.sh"
#   require_config
#   header T01 I2 "iam.managed.disableServiceAccountKeyCreation" "Denied with ..."   [STAGE]
#   cleanup_trap "gcloud iam service-accounts delete ..."      # register BEFORE creating
#   run_capture gcloud ...                                       # or run_capture_sh '...'
#   expect_denied 'FAILED_PRECONDITION' 'iam\.managed\.disableServiceAccountKeyCreation'
#   write_result "$LZV_VERDICT" Enforced "one-line actual" "$LZV_REASON"
#
# Environment:
#   RUN_ID   required: run-1, run-2, or a retry such as run-1-r2. "dry" writes under scratch/.
#
# Evidence: evidence/TNN/RUN_ID/{command.txt,output.txt,result.json}. Existing evidence is
# never overwritten: a second run needs a new RUN_ID. Raw output stays on disk; the console
# gets one short line per command.

set -u
export LC_ALL=C

LZV_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LZV_CONFIG_NAME="lz-validation"
LZV_REGION="${LZV_REGION:-europe-west1}"
LZV_SCOPE="${LZV_SCOPE:-}"          # set by the script, e.g. "folders/$(folder_id root)"
LZV_DOC_REFS=()                     # set by the script
LZV_CLEANUP=()
LZV_LAST_RC=""
LZV_LAST_OUT=""
LZV_VERDICT=""
LZV_REASON=""
LZV_TF_JSON=""

lzv_die() {
  echo "ABORT: $*" >&2
  # After header: keep the partial evidence, out of the way of a re-run (never deleted).
  if [[ -n "${LZV_OUT_FILE:-}" && -f "$LZV_OUT_FILE" && -z "${LZV_ABORTING:-}" ]]; then
    LZV_ABORTING=1
    echo "## ABORT $(lzv_ts): $*" | tee -a "$LZV_CMD_FILE" >>"$LZV_OUT_FILE"
    if [[ -z "${LZV_STAGE:-}" ]]; then
      local d; d="$LZV_DIR/aborted-$(date -u +%Y%m%dT%H%M%SZ)"
      mkdir -p "$d" && mv "$LZV_CMD_FILE" "$LZV_OUT_FILE" "$d/"
      LZV_OUT_FILE="$d/output.txt"; LZV_CMD_FILE="$d/command.txt"
    fi
  fi
  exit 2
}
lzv_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- Guards ------------------------------------------------------------------

lzv_check_run_id() {
  [[ -n "${RUN_ID:-}" ]] || lzv_die "RUN_ID is not set (run-1, run-2, run-1-r2, or dry)"
  [[ "$RUN_ID" =~ ^(run-[0-9]+(-r[0-9]+)?|dry)$ ]] || lzv_die "bad RUN_ID '$RUN_ID'"
}

# Values from PROGRESS.md (private file, git-ignored). Never written to evidence.
lzv_progress_value() {
  # $1 = label as written in PROGRESS.md, e.g. "Account" or "ORG_ID"
  case "$1" in
    Account) sed -n 's/^- Account: *//p' "$LZV_ROOT/PROGRESS.md" | head -1 ;;
    ORG_ID)  sed -n 's/.*ORG_ID: *\([0-9][0-9]*\).*/\1/p' "$LZV_ROOT/PROGRESS.md" | head -1 ;;
    SEED) sed -n 's/^- Seed\/admin project: *//p' "$LZV_ROOT/PROGRESS.md" | head -1 ;;
    FOLDER_ID) sed -n 's/.*FOLDER_ID: *\([0-9][0-9]*\).*/\1/p' "$LZV_ROOT/PROGRESS.md" | head -1 ;;
  esac
}

require_config() {
  lzv_check_run_id
  local cfg acct want_acct org want_org folder parent
  cfg="$(gcloud config configurations list --filter=is_active:true --format='value(name)' 2>/dev/null)"
  [[ "$cfg" == "$LZV_CONFIG_NAME" ]] || lzv_die "active gcloud configuration is '$cfg', expected '$LZV_CONFIG_NAME'"
  acct="$(gcloud config get account 2>/dev/null)"
  want_acct="$(lzv_progress_value Account)"
  [[ -n "$want_acct" && "$acct" == "$want_acct" ]] || lzv_die "gcloud account does not match PROGRESS.md"
  want_org="$(lzv_progress_value ORG_ID)"
  folder="$(lzv_progress_value FOLDER_ID)"
  [[ -n "$want_org" && -n "$folder" ]] || lzv_die "ORG_ID/FOLDER_ID not found in PROGRESS.md"
  parent="$(gcloud resource-manager folders describe "$folder" --format='value(parent)' 2>&1)" \
    || { [[ "$parent" == *eauthenticat* ]] && lzv_die "gcloud credentials need re-authentication: run 'gcloud auth login'"
         lzv_die "cannot read the test folder: ${parent:0:120}"; }
  org="${parent#organizations/}"
  [[ "$org" == "$want_org" ]] || lzv_die "test folder parent does not match the organization in PROGRESS.md"
  # Terraform root folder must be the test folder.
  [[ "$(folder_id root)" == "$folder" ]] || lzv_die "terraform folder_ids.root does not match FOLDER_ID in PROGRESS.md"
  echo "config ok: $cfg"
}

# Refuse --quiet on any command, and -q on gcloud argv (CLAUDE.md safety rule).
# Shell strings are checked for --quiet only, so `grep -q` stays usable.
lzv_no_quiet() {
  local a
  if [[ $# -gt 1 && "$1" == gcloud ]]; then
    for a in "$@"; do [[ "$a" == "-q" ]] && lzv_die "-q is not allowed on gcloud (CLAUDE.md)"; done
  fi
  [[ "$*" == *--quiet* ]] && lzv_die "--quiet is not allowed (CLAUDE.md)"
  [[ "$*" =~ gcloud[^|\;]*[[:space:]]-q([[:space:]]|$) ]] && lzv_die "-q is not allowed on gcloud (CLAUDE.md)"
  return 0
}

# --- Environment lookups (from terraform output; real IDs never hard-coded) ---

lzv_tf() {
  [[ -n "$LZV_TF_JSON" ]] || LZV_TF_JSON="$(terraform -chdir="$LZV_ROOT/infra" output -json 2>/dev/null)"
  [[ -n "$LZV_TF_JSON" ]] || lzv_die "terraform output unavailable in infra/"
  jq -er "$1" <<<"$LZV_TF_JSON" || lzv_die "terraform output has no $1"
}
project_id()     { lzv_tf ".project_ids.value.$1"; }        # runtime|mcp|data|outside
project_number() { lzv_tf ".project_numbers.value.$1"; }
folder_id()      { lzv_tf ".folder_ids.value.$1" | sed 's#^folders/##'; }   # root|ai_prod
org_id()         { lzv_progress_value ORG_ID; }

# Agent runtime outputs (infra/agents/, applied by the human in Phase 4).
agents_tf() {
  local j
  j="$(terraform -chdir="$LZV_ROOT/infra/agents" output -json 2>/dev/null)"
  [[ -n "$j" ]] || return 1
  jq -er "$1" <<<"$j"
}

# Unique, lowercase resource name: lzv_name t07 -> lzv-t07-<run>-<random>
lzv_name() {
  local r
  r="$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
  echo "lzv-$1-${RUN_ID//[^a-z0-9]/}-$r"
}

# --- Header / evidence files -------------------------------------------------

lzv_tool_versions_json() {
  local g t p
  g="$(gcloud version 2>/dev/null | sed -n 's/^Google Cloud SDK //p' | head -1)"
  t="$(terraform version 2>/dev/null | sed -n 's/^Terraform v//p' | head -1)"
  p="$(awk '/hashicorp\/google"/{f=1} f&&/version/{gsub(/[" ]/,"");split($0,a,"=");print a[2];exit}' \
        "$LZV_ROOT/infra/.terraform.lock.hcl" 2>/dev/null)"
  jq -cn --arg g "$g" --arg t "$t" --arg p "$p" '{gcloud:$g, terraform:$t, google_provider:$p}'
}

# Short commit of the repository plus "-dirty" if tests/ has uncommitted changes (TS4).
lzv_script_commit() {
  local c d=""
  c="$(git -C "$LZV_ROOT" rev-parse --short HEAD 2>/dev/null)" || c="unknown"
  [[ -n "$(git -C "$LZV_ROOT" status --porcelain -- tests 2>/dev/null)" ]] && d="-dirty"
  echo "${c}${d}"
}

# header ID CHECK CONTROL EXPECTED [STAGE]
header() {
  [[ $# -ge 4 ]] || lzv_die "header needs ID CHECK CONTROL EXPECTED [STAGE]"
  LZV_ID="$1"; LZV_CHECK="$2"; LZV_CONTROL="$3"; LZV_EXPECTED="$4"; LZV_STAGE="${5:-}"
  [[ "$LZV_ID" =~ ^T[0-9]{2}R?$ ]] || lzv_die "bad test ID '$LZV_ID'"
  if [[ "$RUN_ID" == "dry" ]]; then
    LZV_DIR="$LZV_ROOT/scratch/dry/$LZV_ID"
  else
    LZV_DIR="$LZV_ROOT/evidence/$LZV_ID/$RUN_ID"
  fi
  LZV_REL="${LZV_DIR#"$LZV_ROOT"/}"
  mkdir -p "$LZV_DIR" "$LZV_DIR/stages"
  [[ -e "$LZV_DIR/result.json" ]] && lzv_die "$LZV_REL/result.json exists; use a new RUN_ID"
  if [[ -n "$LZV_STAGE" ]]; then
    [[ -e "$LZV_DIR/stages/$LZV_STAGE.json" ]] && lzv_die "stage $LZV_STAGE already recorded in $LZV_REL; use a new RUN_ID"
  else
    [[ -e "$LZV_DIR/output.txt" ]] && lzv_die "$LZV_REL/output.txt exists; use a new RUN_ID"
  fi
  LZV_CMD_FILE="$LZV_DIR/command.txt"
  LZV_OUT_FILE="$LZV_DIR/output.txt"
  LZV_TOOLS="$(lzv_tool_versions_json)"
  LZV_SCRIPT_COMMIT="$(lzv_script_commit)"
  {
    echo "# $LZV_ID ${LZV_STAGE:+stage=$LZV_STAGE }run=$RUN_ID start=$(lzv_ts)"
    echo "# script_commit=$LZV_SCRIPT_COMMIT"
    echo "# check=$LZV_CHECK control=$LZV_CONTROL"
    echo "# expected (pre-registered): $LZV_EXPECTED"
    echo "# tools: $LZV_TOOLS"
  } | tee -a "$LZV_CMD_FILE" >>"$LZV_OUT_FILE"
  echo "EXPECTED: $LZV_EXPECTED"
}

# guard_abort MESSAGE: a precondition or stage guard failed after header (operator error,
# no result). Nothing is deleted: for a single-stage test the partial command.txt/output.txt
# move to aborted-<ts>/ so the same RUN_ID can be re-run; for a multi-stage test they stay
# in place (only stages/STAGE.json blocks a re-run). Exits 2.
guard_abort() { lzv_die "$@"; }

# Free-text note into output.txt (e.g. preconditions, which bucket was targeted).
note() { echo "## note $(lzv_ts): $*" >>"$LZV_OUT_FILE"; echo "note: $*"; }

# --- Running commands --------------------------------------------------------

lzv_capture() {
  # $1 = display string; rest = command to exec
  local display="$1"; shift
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/lzv-out.XXXXXX")"
  echo "$(lzv_ts) \$ $display" >>"$LZV_CMD_FILE"
  echo "## \$ $display" >>"$LZV_OUT_FILE"
  "$@" </dev/null >"$tmp" 2>&1
  LZV_LAST_RC=$?
  cat "$tmp" >>"$LZV_OUT_FILE"
  echo "## exit=$LZV_LAST_RC at $(lzv_ts)" >>"$LZV_OUT_FILE"
  LZV_LAST_OUT="$LZV_DIR/.last-output"
  mv "$tmp" "$LZV_LAST_OUT"
  echo "rc=$LZV_LAST_RC ($(wc -l <"$LZV_LAST_OUT" | tr -d ' ') lines): $display" | cut -c1-160
  return "$LZV_LAST_RC"
}

# run_capture CMD ARGS...   (logged with %q quoting)
run_capture() {
  lzv_no_quiet "$@"
  local display
  printf -v display '%q ' "$@"
  lzv_capture "${display% }" "$@"
}

# run_capture_sh 'shell string'   (logged verbatim, BEFORE expansion; use for pipes and for
# tokens: write "$(gcloud auth print-access-token)" inside single quotes so the token never
# reaches command.txt or output.txt)
run_capture_sh() {
  lzv_no_quiet "$1"
  lzv_capture "$1" bash -c "$1"
}

# Does the last output match ALL given extended regexes?
last_output_matches() {
  local re
  for re in "$@"; do grep -Eq -- "$re" "$LZV_LAST_OUT" || return 1; done
  return 0
}

# --- Verdicts ----------------------------------------------------------------

# expect_denied REGEX [REGEX...]: all regexes must match the last output.
expect_denied() {
  if [[ "$LZV_LAST_RC" == 0 ]]; then
    LZV_VERDICT=FAIL; LZV_REASON="command succeeded; denial expected"
  elif last_output_matches "$@"; then
    LZV_VERDICT=PASS; LZV_REASON=""
  else
    LZV_VERDICT=INCONCLUSIVE; LZV_REASON="command failed (exit $LZV_LAST_RC) without the verified signature: $*"
  fi
  echo "expect_denied -> $LZV_VERDICT"
  [[ "$LZV_VERDICT" == PASS ]]
}

# expect_success [REGEX...]: PASS if exit 0 and all regexes match; FAIL if exit 0 but no
# match; INCONCLUSIVE if the command failed.
expect_success() {
  if [[ "$LZV_LAST_RC" != 0 ]]; then
    LZV_VERDICT=INCONCLUSIVE; LZV_REASON="command failed (exit $LZV_LAST_RC); success expected"
  elif [[ $# -eq 0 ]] || last_output_matches "$@"; then
    LZV_VERDICT=PASS; LZV_REASON=""
  else
    LZV_VERDICT=FAIL; LZV_REASON="command succeeded but output lacks: $*"
  fi
  echo "expect_success -> $LZV_VERDICT"
  [[ "$LZV_VERDICT" == PASS ]]
}

# Worst of several verdicts: FAIL > INCONCLUSIVE > NOT_TESTED > PASS
verdict_merge() {
  local v worst=PASS rank=0 r
  for v in "$@"; do
    case "$v" in FAIL) r=3 ;; INCONCLUSIVE) r=2 ;; NOT_TESTED) r=1 ;; PASS) r=0 ;; *) lzv_die "bad verdict '$v'" ;; esac
    (( r > rank )) && { rank=$r; worst=$v; }
  done
  echo "$worst"
}

# Multi-stage tests: record one stage's verdict; the final stage reads them back.
write_stage() {
  # write_stage VERDICT NOTE
  [[ -n "$LZV_STAGE" ]] || lzv_die "write_stage needs a STAGE in header"
  jq -n --arg s "$LZV_STAGE" --arg v "$1" --arg n "$2" --arg t "$(lzv_ts)" \
    '{stage:$s, verdict:$v, note:$n, timestamp_utc:$t}' >"$LZV_DIR/stages/$LZV_STAGE.json"
  echo "stage $LZV_STAGE -> $1"
}
read_stage() {  # read_stage STAGE -> prints verdict, or MISSING
  local f="$LZV_DIR/stages/$1.json"
  if [[ -f "$f" ]]; then jq -r .verdict "$f"; else echo MISSING; fi
}

# write_result VERDICT TIER ACTUAL [REASON]
write_result() {
  local verdict="$1" tier="$2" actual="$3" reason="${4:-}"
  case "$verdict" in PASS|FAIL|NOT_TESTED|INCONCLUSIVE) ;; *) lzv_die "bad verdict '$verdict'" ;; esac
  case "$tier" in Enforced|Configured|Documented) ;; *) lzv_die "bad tier '$tier'" ;; esac
  [[ "$verdict" == PASS || -n "$reason" ]] || lzv_die "reason is required unless PASS"
  local refs
  refs="$(printf '%s\n' "${LZV_DOC_REFS[@]+"${LZV_DOC_REFS[@]}"}" | jq -R . | jq -sc 'map(select(length>0))')"
  jq -n \
    --arg id "$LZV_ID" --arg check "$LZV_CHECK" --arg control "$LZV_CONTROL" \
    --arg scope "$LZV_SCOPE" --arg expected "$LZV_EXPECTED" --arg actual "$actual" \
    --arg verdict "$verdict" --arg tier "$tier" --arg reason "$reason" \
    --arg cmd "$LZV_REL/command.txt" --arg out "$LZV_REL/output.txt" \
    --arg run "$RUN_ID" --arg ts "$(lzv_ts)" --arg commit "${LZV_SCRIPT_COMMIT:-unknown}" --argjson tools "$LZV_TOOLS" --argjson refs "$refs" \
    '{id:$id, check:$check, control:$control, scope:$scope, expected:$expected, actual:$actual,
      verdict:$verdict, tier:$tier, reason:$reason, commands_file:$cmd, output_file:$out,
      run_id:$run, timestamp_utc:$ts, tool_versions:$tools, doc_refs:$refs, script_commit:$commit}' \
    >"$LZV_DIR/result.json"
  echo "RESULT $LZV_ID: $verdict ($tier) -> $LZV_REL/result.json"
}

# Record NOT_TESTED and stop (cleanup still runs).
not_tested() {  # not_tested TIER REASON
  write_result NOT_TESTED "$1" "not tested: $2" "$2"
  exit 0
}

# --- Cleanup -----------------------------------------------------------------

lzv_run_cleanup() {
  local rc=$? i
  [[ ${#LZV_CLEANUP[@]} -eq 0 ]] && return "$rc"
  echo "## cleanup start $(lzv_ts)" >>"$LZV_OUT_FILE"
  local c
  for (( i=${#LZV_CLEANUP[@]}-1; i>=0; i-- )); do
    c="${LZV_CLEANUP[$i]}"
    if [[ "$c" == QUIETOK:* ]]; then
      lzv_capture "${c#QUIETOK:}" bash -c "${c#QUIETOK:}" || echo "WARNING: cleanup step failed (see output.txt)" >&2
    else
      run_capture_sh "$c" || echo "WARNING: cleanup step failed (see output.txt)" >&2
    fi
  done
  echo "## cleanup end $(lzv_ts)" >>"$LZV_OUT_FILE"
  rm -f "$LZV_DIR/.last-output"
  return "$rc"
}

# cleanup_trap 'shell string'  -- register BEFORE creating the resource. Runs LIFO on exit,
# output appended to output.txt. Deletes run without --quiet and with stdin closed, so
# gcloud takes the prompt default; follow each delete with a describe/list check.
cleanup_trap() {
  lzv_no_quiet "$1"
  if [[ ${#LZV_CLEANUP[@]} -eq 0 ]]; then
    trap lzv_run_cleanup EXIT
    trap 'exit 130' INT TERM
  fi
  LZV_CLEANUP+=("$1")
}

# cleanup_run_service NAME PROJECT: delete a Cloud Run service this script created, then
# check it is gone. The only place --quiet is allowed (human-approved exception, 2026-10-23,
# CLAUDE.md): `run services delete` cannot be confirmed without a terminal.
cleanup_run_service() {
  [[ "$1" =~ ^lzv-t[0-9]{2}[a-z]?-[a-z0-9-]+$ ]] || lzv_die "cleanup_run_service: '$1' is not a test-created name"
  [[ "$2" =~ ^[a-z][a-z0-9-]+$ ]] || lzv_die "cleanup_run_service: bad project"
  cleanup_trap "gcloud run services describe $1 --region=$LZV_REGION --project=$2 --format='value(metadata.name)'"
  LZV_CLEANUP+=("QUIETOK:gcloud run services delete $1 --region=$LZV_REGION --project=$2 --quiet")
}

# --- Fixtures shared between stages of one test (scratch/, git-ignored) ------

fixture_set() {  # fixture_set KEY VALUE
  local f="$LZV_ROOT/scratch/fixtures/$LZV_ID-$RUN_ID.env"
  mkdir -p "$(dirname "$f")"
  printf '%s=%q\n' "$1" "$2" >>"$f"
}
fixture_get() {  # fixture_get KEY -> value or empty
  local f="$LZV_ROOT/scratch/fixtures/$LZV_ID-$RUN_ID.env"
  [[ -f "$f" ]] || return 1
  ( # shellcheck disable=SC1090
    source "$f"; eval "printf '%s' \"\${$1:-}\"" )
}

# --- Common reads ------------------------------------------------------------

# Quota project for Organization Policy API reads: the seed project (the API is not enabled
# in the test projects; found in run 1, T01). Read-only calls only.
quota_project() { lzv_progress_value SEED; }

# effective_policy CONSTRAINT --project=ID|--folder=ID   (read-only, captured)
effective_policy() {
  run_capture gcloud org-policies describe "$1" --effective "$2" --format=json --billing-project="$(quota_project)"
}

# retry_until N SLEEP CMD...: run CMD up to N times, SLEEP seconds apart; return 0 on the
# first success, otherwise the last exit code. For cleanup checks that lag (eventual
# consistency). Each attempt is logged to output.txt via run_capture.
retry_until() {
  local n="$1" sl="$2" i rc=1; shift 2
  for (( i=1; i<=n; i++ )); do
    run_capture "$@" && return 0
    rc=$?
    (( i < n )) && sleep "$sl"
  done
  return "$rc"
}

# --- IAM snapshots and diff (TS1) --------------------------------------------

# iam_snapshot NAME: allow policies of the runtime, mcp and data projects, the test root
# folder and the ai_prod folder, plus project deny policies, into "$LZV_DIR/iam-NAME/".
# Reads are billed to the quota project, as other reads. No organization-level
# get-iam-policy: the operator has no need for it (and none of the existing functions
# reads org IAM here), so org bindings are out of scope of this diff.
iam_snapshot() {
  local name="$1" d p f
  [[ "$name" =~ ^[a-z0-9-]+$ ]] || lzv_die "iam_snapshot: bad name '$name'"
  d="$LZV_DIR/iam-$name"
  mkdir -p "$d"
  local bp; bp="$(quota_project)"
  for p in runtime mcp data; do
    run_capture gcloud projects get-iam-policy "$(project_id "$p")" --format=json --billing-project="$bp"
    sed -n '/^[[{]/,$p' "$LZV_LAST_OUT" >"$d/project-$p.json"
    jq -e . "$d/project-$p.json" >/dev/null 2>&1 || { note "iam_snapshot $name: project $p read failed"; return 1; }
    run_capture gcloud iam policies list \
      --attachment-point="cloudresourcemanager.googleapis.com/projects/$(project_id "$p")" \
      --kind=denypolicies --format=json --billing-project="$bp"
    sed -n '/^[[{]/,$p' "$LZV_LAST_OUT" >"$d/deny-$p.json"
    [[ -s "$d/deny-$p.json" ]] || echo '[]' >"$d/deny-$p.json"
    jq -e . "$d/deny-$p.json" >/dev/null 2>&1 || { note "iam_snapshot $name: deny policies $p read failed"; return 1; }
  done
  for f in root ai_prod; do
    run_capture gcloud resource-manager folders get-iam-policy "$(folder_id "$f")" --format=json --billing-project="$bp"
    sed -n '/^[[{]/,$p' "$LZV_LAST_OUT" >"$d/folder-$f.json"
    jq -e . "$d/folder-$f.json" >/dev/null 2>&1 || { note "iam_snapshot $name: folder $f read failed"; return 1; }
  done
  note "iam_snapshot $name written to ${d#"$LZV_ROOT"/}"
}

# iam_diff BEFORE AFTER: added and removed (role, member) pairs per scope, as JSON lines
# on stdout and as an array in "$LZV_DIR/iam-diff-BEFORE-AFTER.json". Deny policies are
# compared by name (role = policy name, member empty). Scope names are logical (runtime,
# mcp, data, root, ai_prod), never real IDs.
iam_diff() {
  local b="$LZV_DIR/iam-$1" a="$LZV_DIR/iam-$2" out="$LZV_DIR/iam-diff-$1-$2.json" s f
  [[ -d "$b" && -d "$a" ]] || lzv_die "iam_diff: snapshot missing"
  : >"$out.lines"
  for f in "$b"/project-*.json "$b"/folder-*.json; do
    s="$(basename "$f" .json)"
    [[ -f "$a/$s.json" ]] || continue
    jq -nc --arg scope "$s" --slurpfile b "$f" --slurpfile a "$a/$s.json" '
      def pairs: [(.bindings // [])[] | .role as $r | (.members // [])[] | {role:$r, member:.}];
      ($b[0]|pairs) as $B | ($a[0]|pairs) as $A
      | (($A - $B)[] | {scope:$scope, change:"added", role:.role, member:.member}),
        (($B - $A)[] | {scope:$scope, change:"removed", role:.role, member:.member})' >>"$out.lines"
  done
  for f in "$b"/deny-*.json; do
    s="$(basename "$f" .json)"
    [[ -f "$a/$s.json" ]] || continue
    jq -nc --arg scope "$s" --slurpfile b "$f" --slurpfile a "$a/$s.json" '
      def names: [.[]? | .name // empty | split("/") | last];
      ($b[0]|names) as $B | ($a[0]|names) as $A
      | (($A - $B)[] | {scope:$scope, change:"added", role:., member:""}),
        (($B - $A)[] | {scope:$scope, change:"removed", role:., member:""})' >>"$out.lines"
  done
  jq -sc '.' "$out.lines" >"$out"
  cat "$out.lines" >>"$LZV_OUT_FILE"
  cat "$out.lines"
  rm -f "$out.lines"
}
