#!/usr/bin/env bash
# check-clonezilla-compat.sh
#
# Verifies that the Clonezilla source in CLONEZILLA_REPO still contains the
# exact internal hooks that CustomCloneZilla's build-iso.sh depends on.
# Run this before upgrading CLONEZILLA_VERSION in build-iso.sh.
#
# Usage:
#   ./check-clonezilla-compat.sh
#   ./check-clonezilla-compat.sh --repo /path/to/clonezilla
#   ./check-clonezilla-compat.sh --update          # git pull then check
#   ./check-clonezilla-compat.sh --json            # machine-readable output for agents

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ISO="${SCRIPT_DIR}/build-iso.sh"

# Default repo location (sibling directory of this project)
CLONEZILLA_REPO="${SCRIPT_DIR}/../clonezilla"

# ---- Terminal colors ---------------------------------------------------------
if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

PASS=0; FAIL=0; WARN=0

# Collected JSON records for --json mode
JSON_RECORDS=()

pass() {
  [[ "${JSON_MODE}" != "true" ]] && printf "  ${GREEN}[PASS]${RESET} %s\n"  "$*"
  PASS=$(( PASS + 1 ))
}
fail() {
  [[ "${JSON_MODE}" != "true" ]] && printf "  ${RED}[FAIL]${RESET} %s\n"    "$*"
  FAIL=$(( FAIL + 1 ))
}
warn() {
  [[ "${JSON_MODE}" != "true" ]] && printf "  ${YELLOW}[WARN]${RESET} %s\n" "$*"
  WARN=$(( WARN + 1 ))
}
info() {
  [[ "${JSON_MODE}" != "true" ]] && printf "  ${CYAN}      ${RESET} %s\n"   "$*"
}
section() { [[ "${JSON_MODE}" != "true" ]] && printf "\n${BOLD}>>> %s${RESET}\n" "$*" || true; }
hr()      { [[ "${JSON_MODE}" != "true" ]] && printf '%*s\n' "${COLUMNS:-72}" '' | tr ' ' '-' || true; }

# json_escape STRING — minimal JSON string escaping
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "${s}"
}

# ---- Argument parsing --------------------------------------------------------
DO_UPDATE="false"
JSON_MODE="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)   CLONEZILLA_REPO="$2"; shift 2 ;;
    --update) DO_UPDATE="true"; shift ;;
    --json)   JSON_MODE="true"; shift ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--repo DIR] [--update] [--json]"
      echo "  --repo DIR   Path to clonezilla git repo (default: ../clonezilla)"
      echo "  --update     Run 'git pull' on the repo before checking"
      echo "  --json       Emit machine-readable JSON (useful for agents)"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ---- Core check helper -------------------------------------------------------
#
# check_pattern FILE PATTERN DESCRIPTION KEYWORD FIX_HINT
#
#   FILE       — path relative to CLONEZILLA_REPO
#   PATTERN    — grep -E regex that must match at least one line
#   DESCRIPTION — human label for the check
#   KEYWORD    — plain-text word to grep for context lines when the check fails
#                (shown to the agent so it can read what replaced the old pattern)
#   FIX_HINT   — "function_name: what to verify/change" in build-iso.sh
#
check_pattern() {
  local file="$1" pattern="$2" desc="$3" keyword="${4:-}" fix_hint="${5:-}"
  local full="${CLONEZILLA_REPO}/${file}"
  local status current_content=""

  if [[ ! -f "${full}" ]]; then
    status="FAIL"
    fail "${desc}"
    info "File not found: ${file}"
    [[ -n "${fix_hint}" ]] && info "Fix target in build-iso.sh → ${fix_hint}"
  elif grep -qE "${pattern}" "${full}"; then
    status="PASS"
    pass "${desc}"
  else
    status="FAIL"
    fail "${desc}"
    info "Expected pattern : ${pattern}"
    info "In file          : ${file}"

    # Show actual current content so an agent can reason about the new API
    if [[ -n "${keyword}" ]]; then
      info "Current file content (grep '${keyword}', up to 10 lines):"
      local ctx
      ctx="$(grep -n "${keyword}" "${full}" 2>/dev/null | head -10 || true)"
      if [[ -n "${ctx}" ]]; then
        while IFS= read -r ln; do info "    ${ln}"; done <<< "${ctx}"
        current_content="${ctx}"
      else
        info "    (no lines match keyword '${keyword}' — API may have been removed)"
      fi
    fi

    [[ -n "${fix_hint}" ]] && info "Fix target in build-iso.sh → ${fix_hint}"
  fi

  # Accumulate JSON record
  if [[ "${JSON_MODE}" == "true" ]]; then
    local jfile jpattern jdesc jkeyword jfix jcontent jstatus
    jfile="$(json_escape "${file}")"
    jpattern="$(json_escape "${pattern}")"
    jdesc="$(json_escape "${desc}")"
    jkeyword="$(json_escape "${keyword}")"
    jfix="$(json_escape "${fix_hint}")"
    jcontent="$(json_escape "${current_content}")"
    jstatus="$(json_escape "${status}")"

    JSON_RECORDS+=("{\"status\":\"${jstatus}\",\"description\":\"${jdesc}\",\"file\":\"${jfile}\",\"pattern\":\"${jpattern}\",\"keyword\":\"${jkeyword}\",\"fix_hint\":\"${jfix}\",\"current_content\":\"${jcontent}\"}")
  fi
}

# ---- Pre-flight --------------------------------------------------------------
[[ -d "${CLONEZILLA_REPO}" ]] || {
  echo ""
  printf "${RED}ERROR${RESET}: Clonezilla repo not found at: %s\n" "${CLONEZILLA_REPO}"
  echo "  Clone it with:  git clone https://github.com/stevenshiau/clonezilla ../clonezilla"
  echo "  Or specify:     --repo /path/to/clonezilla"
  exit 1
}

CLONEZILLA_REPO="$(cd "${CLONEZILLA_REPO}" && pwd)"

# ---- Optional update ---------------------------------------------------------
if [[ "${DO_UPDATE}" == "true" ]]; then
  section "Updating Clonezilla repo"
  git -C "${CLONEZILLA_REPO}" pull --ff-only
fi

# ---- Repo info ---------------------------------------------------------------
REPO_HEAD="$(git -C "${CLONEZILLA_REPO}" log --oneline -1 2>/dev/null || echo 'unknown')"
REPO_TAG="$(git -C "${CLONEZILLA_REPO}" describe --tags --abbrev=0 2>/dev/null || echo 'unknown')"

if [[ "${JSON_MODE}" != "true" ]]; then
  section "Clonezilla repo"
  printf "  Repo   : %s\n" "${CLONEZILLA_REPO}"
  printf "  HEAD   : %s\n" "${REPO_HEAD}"
  printf "  Tag    : %s\n" "${REPO_TAG}"
fi

# ---- Check 1: ocs_prerun* kernel parameter mechanism -------------------------
[[ "${JSON_MODE}" != "true" ]] && section "ocs_prerun* kernel parameter (boot → shell command bridge)"
[[ "${JSON_MODE}" != "true" ]] && info "CustomCloneZilla injects ocs_prerun1..4 into the kernel cmdline."
[[ "${JSON_MODE}" != "true" ]] && info "ocs-run-boot-param must parse and execute them."

check_pattern \
  "sbin/ocs-run-boot-param" \
  "ocs_prerun" \
  "ocs-run-boot-param references ocs_prerun" \
  "ocs_prerun" \
  "build_boot_params(): ocs_prerun1..4 kernel parameter names"

check_pattern \
  "sbin/ocs-run-boot-param" \
  "parse_cmdline_option" \
  "ocs-run-boot-param uses parse_cmdline_option to read kernel params" \
  "parse_cmdline_option" \
  "build_boot_params(): kernel params are parsed via parse_cmdline_option — if this changed, the param format may have changed too"

# ---- Check 2: ocs-live.conf is sourced before dialogs -----------------------
[[ "${JSON_MODE}" != "true" ]] && section "/etc/ocs/ocs-live.conf sourcing"
[[ "${JSON_MODE}" != "true" ]] && info "build-iso.sh writes ocsroot_src and ocs_live_type into ocs-live.conf via ocs_prerun."
[[ "${JSON_MODE}" != "true" ]] && info "Both scripts must source this file before showing any dialog."

check_pattern \
  "sbin/ocs-prep-repo" \
  '\. .*ocs-live\.conf|\[ -e.*ocs-live\.conf.*\].*\.' \
  "ocs-prep-repo sources /etc/ocs/ocs-live.conf" \
  "ocs-live.conf" \
  "build_boot_params(): ocs_prerun3 and ocs_prerun4 write into /etc/ocs/ocs-live.conf — verify that file is still sourced before the first dialog"

check_pattern \
  "sbin/clonezilla" \
  '\. .*ocs-live\.conf|\[ -e.*ocs-live\.conf.*\].*\.' \
  "clonezilla sources /etc/ocs/ocs-live.conf" \
  "ocs-live.conf" \
  "build_boot_params(): ocs_prerun4 writes ocs_live_type into /etc/ocs/ocs-live.conf — verify clonezilla still sources it before the mode dialog"

# ---- Check 3: ocsroot_src=skip skips storage dialog -------------------------
[[ "${JSON_MODE}" != "true" ]] && section "ocsroot_src=skip — bypasses storage-type selection dialog"
[[ "${JSON_MODE}" != "true" ]] && info "ocs-prep-repo must check 'if [ -z \"\$ocsroot_src\" ]' before showing the menu."
[[ "${JSON_MODE}" != "true" ]] && info "If ocsroot_src is pre-set (by our ocs_prerun3), the dialog is skipped."

check_pattern \
  "sbin/ocs-prep-repo" \
  '\[ -z.*ocsroot_src.*\]' \
  "ocs-prep-repo guards storage dialog on empty ocsroot_src" \
  "ocsroot_src" \
  "build_boot_params(): ocs_prerun3 sets ocsroot_src=skip — if the guard moved or the variable was renamed, update the echo command in ocs_prerun3"

check_pattern \
  "sbin/ocs-prep-repo" \
  '"skip"' \
  "ocs-prep-repo has a 'skip' option in the storage menu" \
  "skip" \
  "build_boot_params(): ocs_prerun3 value is 'skip' — if Clonezilla renamed this option, update the ocsroot_src= value in ocs_prerun3"

check_pattern \
  "sbin/ocs-prep-repo" \
  'ocsroot_src.*skip|skip.*ocsroot_src' \
  "ocs-prep-repo handles ocsroot_src=skip" \
  "ocsroot_src" \
  "build_boot_params(): ocs_prerun3='echo ocsroot_src=skip >> /etc/ocs/ocs-live.conf'"

# ---- Check 4: ocs_live_type=device-image skips mode dialog ------------------
[[ "${JSON_MODE}" != "true" ]] && section "ocs_live_type=device-image — bypasses clone-mode selection dialog"
[[ "${JSON_MODE}" != "true" ]] && info "clonezilla must check 'if [ -z \"\$ocs_live_type\" ]' before showing the menu."
[[ "${JSON_MODE}" != "true" ]] && info "If ocs_live_type is pre-set (by our ocs_prerun4), the dialog is skipped."

check_pattern \
  "sbin/clonezilla" \
  '\[ -z.*ocs_live_type.*\]' \
  "clonezilla guards mode dialog on empty ocs_live_type" \
  "ocs_live_type" \
  "build_boot_params(): ocs_prerun4 sets ocs_live_type=device-image — if the guard moved or the variable was renamed, update ocs_prerun4"

check_pattern \
  "sbin/clonezilla" \
  '"device-image"' \
  "clonezilla has a 'device-image' mode" \
  "device-image" \
  "build_boot_params(): ocs_prerun4 value is 'device-image' — if Clonezilla renamed this mode, update the ocs_live_type= value in ocs_prerun4"

check_pattern \
  "sbin/clonezilla" \
  'ocs_live_type.*device-image|device-image.*ocs-live' \
  "clonezilla dispatches device-image mode to ocs-live" \
  "device-image" \
  "build_boot_params(): ocs_prerun4='echo ocs_live_type=device-image >> /etc/ocs/ocs-live.conf'"

# ---- Check 5: /home/partimag as ocsroot -------------------------------------
[[ "${JSON_MODE}" != "true" ]] && section "/home/partimag — NFS mount target"
[[ "${JSON_MODE}" != "true" ]] && info "build-iso.sh mounts the NFS share at /home/partimag."
[[ "${JSON_MODE}" != "true" ]] && info "Clonezilla's ocsroot variable must still default to this path."

check_pattern \
  "sbin/ocs-prep-repo" \
  '/home/partimag' \
  "ocs-prep-repo references /home/partimag as mount target" \
  "partimag" \
  "build_boot_params(): ocs_prerun2 mounts NFS at /home/partimag — if Clonezilla changed its ocsroot default path, update the mount target in ocs_prerun2"

# ocsroot default is defined by the DRBL package at runtime, not in this repo.
DRBL_OCS_CONF="${CLONEZILLA_REPO}/conf/drbl-ocs.conf"
if [[ -f "${DRBL_OCS_CONF}" ]]; then
  if grep -qE '^ocsroot=' "${DRBL_OCS_CONF}"; then
    check_pattern \
      "conf/drbl-ocs.conf" \
      '^ocsroot=.*partimag' \
      "drbl-ocs.conf does not override ocsroot away from /home/partimag" \
      "ocsroot" \
      "build_boot_params(): ocs_prerun2 NFS mount target — sync with whatever drbl-ocs.conf sets ocsroot to"
  else
    [[ "${JSON_MODE}" != "true" ]] && info "drbl-ocs.conf does not define ocsroot — set by DRBL package at runtime (expected)"
  fi
else
  [[ "${JSON_MODE}" != "true" ]] && info "conf/drbl-ocs.conf not in repo — ocsroot defined by DRBL package at runtime (expected)"
fi

# ---- Check 6: ocs_prerun numbering style still sequential -------------------
[[ "${JSON_MODE}" != "true" ]] && section "ocs_prerun numbering style"
[[ "${JSON_MODE}" != "true" ]] && info "build-iso.sh uses ocs_prerun1, ocs_prerun2, ocs_prerun3, ocs_prerun4."
[[ "${JSON_MODE}" != "true" ]] && info "ocs-run-boot-param must support numeric suffixes."

check_pattern \
  "sbin/ocs-run-boot-param" \
  'sort -V' \
  "ocs-run-boot-param sorts ocs_prerun* numerically (sort -V handles 1,2,...10 ordering)" \
  "sort" \
  "build_boot_params(): ocs_prerun1..4 — if sort -V was removed, the execution order of the prerun commands may have changed"

# ---- Check 7: ocs-run-boot-param is the entry point for ocs_prerun* --------
[[ "${JSON_MODE}" != "true" ]] && section "ocs-run-boot-param is the sole executor of ocs_prerun* commands"
[[ "${JSON_MODE}" != "true" ]] && info "build-iso.sh relies on ocs-run-boot-param being called with 'ocs_prerun' argument."
[[ "${JSON_MODE}" != "true" ]] && info "Clonezilla's init / startup scripts must invoke it on every boot."

check_pattern \
  "sbin/ocs-run-boot-param" \
  'ocs_param.*\$\{?ocs_param\}?\[' \
  "ocs-run-boot-param builds list of matching params from cmdline" \
  "ocs_param" \
  "build_boot_params(): overall ocs_prerun mechanism — if this changed, the kernel param injection approach may need to be rethought"

LIVE_MENU="${CLONEZILLA_REPO}/sbin/ocs-live-run-menu"
if [[ -f "${LIVE_MENU}" ]]; then
  check_pattern \
    "sbin/ocs-live-run-menu" \
    'ocs-run-boot-param.*ocs_prerun' \
    "ocs-live-run-menu calls ocs-run-boot-param ocs_prerun (entry point on boot)" \
    "ocs-run-boot-param" \
    "build_boot_params(): entire ocs_prerun chain — if ocs-live-run-menu no longer triggers ocs-run-boot-param, prerun commands will not run at all"
else
  warn "sbin/ocs-live-run-menu not found — cannot verify ocs-run-boot-param is invoked on boot"
fi

# ---- Summary (human mode) ----------------------------------------------------
if [[ "${JSON_MODE}" != "true" ]]; then
  printf "\n"
  hr
  printf "  Results:  ${GREEN}%d passed${RESET}  " "${PASS}"
  printf "${RED}%d failed${RESET}  " "${FAIL}"
  printf "${YELLOW}%d warnings${RESET}\n" "${WARN}"
  hr

  if (( FAIL > 0 )); then
    printf "\n${RED}BREAKING CHANGES DETECTED.${RESET}\n"
    printf "Review the failures above before upgrading CLONEZILLA_VERSION in build-iso.sh.\n"
    printf "Each [FAIL] block shows:\n"
    printf "  • The expected regex pattern\n"
    printf "  • Current file content (so you can see what changed)\n"
    printf "  • The exact function/line in build-iso.sh to update (Fix target)\n\n"
  elif (( WARN > 0 )); then
    printf "\n${YELLOW}Warnings found — review before upgrading.${RESET}\n\n"
  else
    printf "\n${GREEN}All checks passed — safe to upgrade CLONEZILLA_VERSION.${RESET}\n\n"
  fi
fi

# ---- JSON output mode --------------------------------------------------------
if [[ "${JSON_MODE}" == "true" ]]; then
  printf '{\n'
  printf '  "repo": "%s",\n'  "$(json_escape "${CLONEZILLA_REPO}")"
  printf '  "head": "%s",\n'  "$(json_escape "${REPO_HEAD}")"
  printf '  "tag": "%s",\n'   "$(json_escape "${REPO_TAG}")"
  printf '  "passed": %d,\n'  "${PASS}"
  printf '  "failed": %d,\n'  "${FAIL}"
  printf '  "warned": %d,\n'  "${WARN}"
  printf '  "build_iso": "%s",\n' "$(json_escape "${BUILD_ISO}")"
  printf '  "checks": [\n'
  local_sep=""
  for rec in "${JSON_RECORDS[@]}"; do
    printf '%s    %s\n' "${local_sep}" "${rec}"
    local_sep=","
  done
  printf '  ]\n'
  printf '}\n'
fi

(( FAIL == 0 ))
