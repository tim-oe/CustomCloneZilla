#!/usr/bin/env bash
# burn-usb.sh — write dhcp-clonezilla.iso to a USB device and verify the build.
#
# Usage:
#   ./burn-usb.sh /dev/sdX
#   ./burn-usb.sh --iso /path/to/other.iso /dev/sdX

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
DEFAULT_ISO="${BUILD_DIR}/dhcp-clonezilla.iso"

# ---- Terminal colors ---------------------------------------------------------
if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

log()  { printf "${GREEN}[INFO]${RESET}  %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*" >&2; }
err()  { printf "${RED}[ERROR]${RESET} %s\n"    "$*" >&2; }
die()  { err "$*"; exit 1; }
hr()   { printf '%*s\n' "${COLUMNS:-72}" '' | tr ' ' '-'; }

# ---- Usage -------------------------------------------------------------------
usage() {
  cat <<EOF
${BOLD}burn-usb.sh${RESET} — write a CustomCloneZilla ISO to a USB device and verify it.

${BOLD}USAGE${RESET}
  $(basename "$0") [--iso FILE] <device>

${BOLD}OPTIONS${RESET}
  --iso FILE   ISO to write  (default: ${DEFAULT_ISO})
  -h, --help   Show this help

${BOLD}EXAMPLES${RESET}
  sudo $(basename "$0") /dev/sdb
  sudo $(basename "$0") --iso build/custom-clonezilla.iso /dev/sdc

${BOLD}NOTE${RESET}
  Must be run with sudo — dd and mount require root.

${BOLD}REQUIREMENTS${RESET}
  sudo, dd, lsblk, mount

EOF
}

# ---- Argument parsing --------------------------------------------------------
ISO_FILE="${DEFAULT_ISO}"
DEVICE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso)   ISO_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    /dev/*)  DEVICE="$1"; shift ;;
    *) die "Unknown argument: '$1'  Run '$(basename "$0") --help' for usage." ;;
  esac
done

[[ -n "${DEVICE}" ]] || { usage; die "No device specified."; }

# ---- Must run as root --------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
  die "This script must be run as root.
  Re-run with: sudo $(basename "$0") ${DEVICE:+${DEVICE} }${ISO_FILE:+--iso ${ISO_FILE}}"
fi

# ---- Pre-flight checks -------------------------------------------------------
[[ -f "${ISO_FILE}" ]] || die "ISO not found: ${ISO_FILE}
  Build it first with: ./dhcp.sh"

command -v dd     >/dev/null || die "dd not found"
command -v lsblk  >/dev/null || die "lsblk not found"
command -v mount  >/dev/null || die "mount not found"
command -v umount >/dev/null || die "umount not found"

# Device must be a recognised block device.
# Use lsblk (reads sysfs) as the primary check — it works even when the
# process lacks the privilege to stat /dev/* as a block node directly.
# Fall back to the bash -b test as confirmation when lsblk is ambiguous.
if ! lsblk "${DEVICE}" >/dev/null 2>&1; then
  die "Device not found: ${DEVICE}
  Run 'lsblk' to list available devices."
fi
# Confirm lsblk sees it as a disk/partition, not a loop or zram
DEV_TYPE="$(lsblk -no TYPE "${DEVICE}" 2>/dev/null | head -1)"
case "${DEV_TYPE}" in
  disk|part) ;;
  "") die "Device not found: ${DEVICE}" ;;
  *)  die "Unexpected device type '${DEV_TYPE}' for ${DEVICE} — expected disk or part." ;;
esac

# Refuse to write to a mounted device
if grep -q "^${DEVICE}" /proc/mounts 2>/dev/null; then
  die "${DEVICE} (or a partition on it) is currently mounted.
  Unmount it first, then re-run this script."
fi

# Refuse to write to the root or boot device
ROOT_DEV="$(lsblk -no pkname "$(findmnt -n -o SOURCE /)" 2>/dev/null || true)"
[[ -n "${ROOT_DEV}" && "${DEVICE}" == "/dev/${ROOT_DEV}" ]] \
  && die "Refusing to overwrite the system root device (${DEVICE})."

# ---- Show what we're about to do ---------------------------------------------
ISO_SIZE="$(du -h "${ISO_FILE}" | cut -f1)"
DEV_INFO="$(lsblk -no NAME,SIZE,MODEL,VENDOR "${DEVICE}" 2>/dev/null | head -1 || echo "(unknown)")"

printf "\n"
hr
printf "  ${BOLD}ISO${RESET}    : %s (%s)\n" "${ISO_FILE}" "${ISO_SIZE}"
printf "  ${BOLD}Device${RESET} : %s  —  %s\n" "${DEVICE}" "${DEV_INFO}"
hr
printf "\n"

# Show checksum if available
SHA_FILE="${ISO_FILE}.sha256"
if [[ -f "${SHA_FILE}" ]]; then
  printf "  ${CYAN}Verifying ISO checksum ...${RESET}\n"
  if sha256sum -c "${SHA_FILE}" --status 2>/dev/null; then
    log "ISO checksum OK  ($(cat "${SHA_FILE}" | cut -c1-16)...)"
  else
    warn "ISO checksum MISMATCH — the file may be corrupt."
    printf "  Continue anyway? [y/N] "
    read -r _reply
    [[ "${_reply,,}" == "y" ]] || { log "Aborted."; exit 0; }
  fi
fi

# ---- Confirmation prompt -----------------------------------------------------
printf "${YELLOW}  WARNING: ALL DATA ON %s WILL BE PERMANENTLY ERASED.${RESET}\n" "${DEVICE}"
printf "  Proceed? [y/N] "
read -r _confirm
[[ "${_confirm,,}" == "y" ]] || { log "Aborted."; exit 0; }

# ---- Write ISO ---------------------------------------------------------------
printf "\n"
log "Writing ${ISO_FILE} → ${DEVICE} ..."
WRITE_START="$(date +%s)"

dd \
  if="${ISO_FILE}" \
  of="${DEVICE}" \
  bs=4M \
  status=progress \
  oflag=sync \
  conv=fsync

WRITE_END="$(date +%s)"
ELAPSED=$(( WRITE_END - WRITE_START ))
log "Write complete in ${ELAPSED}s — syncing ..."
sync
log "Sync done."

# ---- Verify: mount and read build-info.txt -----------------------------------
MOUNT_DIR="$(mktemp -d /tmp/cz-verify-XXXXXX)"

cleanup() {
  if mountpoint -q "${MOUNT_DIR}" 2>/dev/null; then
    umount "${MOUNT_DIR}" 2>/dev/null || true
  fi
  rmdir "${MOUNT_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

printf "\n"
log "Mounting ${DEVICE} for verification ..."

# Try partitions in order, then the raw device
MOUNTED_FROM=""
for _src in "${DEVICE}1" "${DEVICE}p1" "${DEVICE}"; do
  lsblk "${_src}" >/dev/null 2>&1 || continue
  if mount -o ro "${_src}" "${MOUNT_DIR}" 2>/dev/null; then
    MOUNTED_FROM="${_src}"
    break
  fi
done

if [[ -z "${MOUNTED_FROM}" ]]; then
  warn "Could not mount any partition on ${DEVICE} — skipping build-info verification."
  warn "The ISO was written; try mounting manually:"
  warn "  sudo mount -o ro ${DEVICE}1 /mnt && cat /mnt/build-info.txt"
  exit 0
fi

log "Mounted ${MOUNTED_FROM} → ${MOUNT_DIR}"

# ---- Dump build-info.txt -----------------------------------------------------
BUILD_INFO="${MOUNT_DIR}/build-info.txt"
printf "\n"
hr
if [[ -f "${BUILD_INFO}" ]]; then
  printf "  ${BOLD}build-info.txt${RESET}\n\n"
  while IFS= read -r _line; do
    printf "    %s\n" "${_line}"
  done < "${BUILD_INFO}"
else
  printf "  ${YELLOW}build-info.txt not found on device${RESET}\n"
  printf "  (ISO may have been built without metadata support)\n"
fi
hr
printf "\n"

log "Verification complete. USB is ready."
