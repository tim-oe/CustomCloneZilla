#!/usr/bin/env bash
#==============================================================================
# build-iso.sh
#
# Customize a Clonezilla Live ISO with:
#   - Language / locale settings
#   - Keyboard layout and variant
#   - Timezone
#   - NFS share for automated backup or restore
#
# Both UEFI (GRUB2) and legacy BIOS (isolinux/syslinux) boot entries are
# updated so the resulting ISO boots correctly on any hardware.
#
# Requires: xorriso wget mtools
# Install:  sudo apt-get install xorriso wget mtools
#
# Usage: ./build-iso.sh [OPTIONS]
#        ./build-iso.sh --help
#==============================================================================

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly VERSION="1.0.0"

# ---- Terminal colors --------------------------------------------------------
if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

# ---- Logging ----------------------------------------------------------------
log()     { printf "${GREEN}[INFO]${RESET}  %s\n"  "$*"; }
warn()    { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*" >&2; }
err()     { printf "${RED}[ERROR]${RESET} %s\n"    "$*" >&2; }
debug()   { [[ "${VERBOSE}" == "true" ]] && printf "${CYAN}[DEBUG]${RESET} %s\n" "$*" || true; }
die()     { err "$*"; exit 1; }
section() { printf "\n${BOLD}>>> %s${RESET}\n" "$*"; }
hr()      { printf '%*s\n' "${COLUMNS:-80}" '' | tr ' ' '-'; }

# ---- Defaults (overridden by config file, then by CLI args) -----------------

# Clonezilla release to download if no local ISO is provided
# amd64: stable builds on SourceForge  (3.x only; i686 was dropped at 3.2.0-8)
# arm64: experimental builds on NCHC mirror  (no official stable arm64 yet)
#        https://free.nchc.org.tw/clonezilla-live/experimental/arm/
CLONEZILLA_VERSION=""                  # auto-derived from arch in compute_defaults()
CLONEZILLA_ARCH="amd64"               # amd64 | arm64
CLONEZILLA_AMD64_VERSION="3.3.1-35"  # latest stable amd64 (SourceForge)
CLONEZILLA_ARM64_VERSION="3.3.2-21"  # latest experimental arm64 (NCHC)
# Full URL is auto-computed in compute_defaults(); override here to pin a mirror
CLONEZILLA_DOWNLOAD_URL=""

# Working / output paths (all computed in compute_defaults)
BUILD_DIR=""        # ${SCRIPT_DIR}/build  — gitignored, survives between runs
ISO_EXTRACT_DIR=""  # ${BUILD_DIR}/extract — recreated each build
OUTPUT_ISO=""       # ${BUILD_DIR}/custom-clonezilla.iso

# Build identifiers (set once at startup so all steps share the same timestamp)
BUILD_TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
BUILD_DATE_TAG="$(date '+%Y%m%d-%H%M%S')"

# ---------- Locale / Input ---------------------------------------------------
LANGUAGE="en_US.UTF-8"
KEYBOARD_LAYOUT="us"
KEYBOARD_VARIANT=""
TIMEZONE="America/Chicago"

# ---------- Network Configuration --------------------------------------------
# NETWORK_DHCP: true  = inject ip=dhcp into the boot line (recommended)
#               false = leave network configuration to the live system default
NETWORK_DHCP="true"
# NETWORK_INTERFACE: empty = DHCP on all interfaces (ip=dhcp)
#                    e.g. "eth0" = DHCP on that interface only (ip=eth0:dhcp)
NETWORK_INTERFACE=""

# ---------- NFS Configuration ------------------------------------------------
NFS_SERVER="192.168.1.30"             # your NFS server IP or hostname
NFS_SHARE="/mnt/main/backup/systems"  # your NFS share path
NFS_OPTS="defaults"                   # mount options passed to -o
NFS_VERSION="4"                       # NFS version: 3 or 4
NFS_WAIT_SEC="15"                     # seconds to sleep before NFS mount (lets DHCP settle)

# ---------- Local Device (USB) Repository ------------------------------------
# Alternative to NFS: scan for a removable USB block device at boot and mount
# it as the Clonezilla image repository.  A small detection script is injected
# into the ISO and invoked via ocs_prerun before Clonezilla starts.
# - USB_REPO_LABEL: optional FAT/ext4 volume label filter (e.g. "CZ_IMAGES").
#   Leave empty to use the first removable device found.
# - When both NFS and USB_REPO_DETECT are set, NFS runs first (prerun 1-4);
#   USB detection runs after (prerun 5) and exits silently if NFS already
#   mounted /home/partimag.
# - For Raspberry Pi 5: set CZ_DISK="nvme0n1" (NVMe via M.2 HAT+) or "mmcblk0"
#   (SD card), or keep "sda" for an external USB target drive.
USB_REPO_DETECT="false"
USB_REPO_LABEL=""          # optional volume label filter, e.g. "CZ_IMAGES"

# ---------- Clonezilla Operation ---------------------------------------------
# Mode: backup | restore | interactive
#   backup      - save disk image to NFS share (automated, no prompts)
#   restore     - restore disk image from NFS share (automated, no prompts)
#   interactive - standard Clonezilla menu (locale/keyboard still applied)
CZ_MODE="interactive"
CZ_DISK="sda"
CZ_IMAGE_NAME="clonezilla-img"
# Compression:  z0=none  z1p=gzip  z2p=bzip2  z3p=lzop  z4p=lzma  z5p=xz
CZ_COMPRESS="z1p"
# What to do when finished: reboot | poweroff | choose
CZ_POST_ACTION="reboot"
# Appended verbatim to the ocs-sr command (advanced overrides)
CZ_EXTRA_ARGS=""

# ---------- Script Behavior --------------------------------------------------
CONFIG_FILE=""
LOCAL_ISO=""        # path to a pre-downloaded ISO; skips download
KEEP_WORK_DIR="false"
DRY_RUN="false"
VERBOSE="false"

# ---- Usage ------------------------------------------------------------------
usage() {
  cat <<EOF
${BOLD}${SCRIPT_NAME} v${VERSION}${RESET}

Customize a Clonezilla Live ISO with locale, keyboard, and NFS settings.
Produces a bootable hybrid ISO (UEFI + legacy BIOS) ready to write to USB.

${BOLD}USAGE${RESET}
  ${SCRIPT_NAME} [OPTIONS]

${BOLD}LOCALE OPTIONS${RESET}
  -l, --language LOCALE       System locale            (default: ${LANGUAGE})
  -k, --keyboard LAYOUT       Keyboard layout          (default: ${KEYBOARD_LAYOUT})
      --keyboard-variant VAR  Keyboard variant         (default: none)  [untested]
  -z, --timezone TZ           Timezone                 (default: ${TIMEZONE})

${BOLD}NETWORK OPTIONS${RESET}
      --dhcp                  Enable DHCP on boot (default: enabled)
      --no-dhcp               Disable DHCP injection (use live system default)
      --network-interface IF  DHCP on a specific interface, e.g. eth0
                              uses ip=<IF>:dhcp  (default: all interfaces, ip=dhcp)
                              [untested — prefer leaving unset with ip=dhcp]

${BOLD}NFS OPTIONS${RESET}
  -s, --nfs-server IP         NFS server IP or hostname
  -n, --nfs-share PATH        Exported NFS path  (e.g. /mnt/backups)
      --nfs-opts OPTS         Extra mount options appended to nfsvers=N
                              (default: ${NFS_OPTS})  [untested — leave as default]
      --nfs-version VER       NFS version: 3 or 4     (default: ${NFS_VERSION})
      --nfs-wait SEC          Seconds to wait for DHCP (default: ${NFS_WAIT_SEC})

${BOLD}OPERATION OPTIONS${RESET}  (require --nfs-server and --nfs-share)
  -m, --mode MODE             backup | restore | interactive  (default: ${CZ_MODE})
  -d, --disk DISK             Target disk device       (default: ${CZ_DISK})
  -i, --image NAME            Image name on NFS share  (default: ${CZ_IMAGE_NAME})
      --compress TYPE         Compression type         (default: ${CZ_COMPRESS})
                              z0=none z1p=gzip z2p=bzip2 z3p=lzop z4p=lzma z5p=xz
      --post-action ACTION    reboot | poweroff | choose  (default: ${CZ_POST_ACTION})
      --extra-args ARGS       Extra ocs-sr arguments (advanced)  [untested]

${BOLD}ISO OPTIONS${RESET}
      --iso FILE              Use local ISO instead of downloading
      --czversion VER         Clonezilla version       (default: per-arch, see below)
      --arch ARCH             CPU architecture: amd64 | arm64  (default: ${CLONEZILLA_ARCH})
                              arm64 downloads from the NCHC experimental mirror
  -o, --output FILE           Output ISO path          (default: build/custom-clonezilla.iso)

${BOLD}USB REPOSITORY OPTIONS${RESET}
      --usb-repo-detect       Inject a USB drive detection script into the ISO.
                              At boot, scans for a removable block device and
                              mounts it as the Clonezilla image repo (ocs_prerun).
      --usb-repo-label LABEL  Only use a USB partition with this volume label
                              (e.g. CZ_IMAGES).  Ignored unless --usb-repo-detect.
                              Raspberry Pi 5 + NVMe: also set --disk nvme0n1.

${BOLD}SCRIPT OPTIONS${RESET}
  -c, --config FILE           Load settings from FILE  (see config/settings.conf)
      --keep-work-dir         Keep working directory after completion
      --dry-run               Show what would be done without making changes
  -v, --verbose               Verbose / debug output
  -h, --help                  Show this help and exit

${BOLD}EXAMPLES${RESET}
  # Locale + keyboard only (interactive Clonezilla menu):
  ${SCRIPT_NAME} --language fr_FR.UTF-8 --keyboard fr --timezone Europe/Paris

  # Automated NFS restore (restores image to sda then reboots):
  ${SCRIPT_NAME} \\
    --language en_US.UTF-8 --keyboard us \\
    --nfs-server 192.168.1.100 --nfs-share /mnt/backups \\
    --mode restore --disk sda --image ubuntu-24.04

  # Automated NFS backup (backs up sda then powers off):
  ${SCRIPT_NAME} \\
    --nfs-server 192.168.1.100 --nfs-share /mnt/backups \\
    --mode backup --disk sda --image server01 --post-action poweroff

  # Raspberry Pi 5 — restore NVMe from a labeled USB drive:
  #   Prerequisites:
  #     1. Install rpi5-uefi firmware on Pi 5 (https://github.com/worproject/rpi5-uefi)
  #        so the Pi boots as a standard ARM64 UEFI device.
  #     2. Set Pi EEPROM boot order: BOOT_ORDER=0xf164  (USB first, then NVMe).
  #        Run on the Pi: sudo rpi-eeprom-config --edit
  #     3. Format a USB drive, create one partition labeled "CZ_IMAGES", and
  #        copy your Clonezilla image folders onto it.
  ${SCRIPT_NAME} \\
    --arch arm64 \\
    --mode restore --disk nvme0n1 --image pi5-backup \\
    --usb-repo-detect --usb-repo-label CZ_IMAGES \\
    --post-action reboot

  # Use a config file (great for repeatable builds):
  ${SCRIPT_NAME} --config config/settings.conf

${BOLD}WRITE TO USB${RESET}
  sudo ./burn-usb.sh [--iso <output-iso>] /dev/sdX

${BOLD}DEPENDENCIES${RESET}
  Required : xorriso  wget
  Optional : mtools   (patches efi.img for UEFI; install: sudo apt-get install mtools)

EOF
}

# ---- Argument parsing -------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|--config)            CONFIG_FILE="$2";           shift 2 ;;
      -l|--language)          LANGUAGE="$2";              shift 2 ;;
      -k|--keyboard)          KEYBOARD_LAYOUT="$2";       shift 2 ;;
         --keyboard-variant)  KEYBOARD_VARIANT="$2";      shift 2 ;;
      -z|--timezone)          TIMEZONE="$2";              shift 2 ;;
         --dhcp)              NETWORK_DHCP="true";        shift   ;;
         --no-dhcp)           NETWORK_DHCP="false";       shift   ;;
         --network-interface) NETWORK_INTERFACE="$2";     shift 2 ;;
      -s|--nfs-server)        NFS_SERVER="$2";            shift 2 ;;
      -n|--nfs-share)         NFS_SHARE="$2";             shift 2 ;;
         --nfs-opts)          NFS_OPTS="$2";              shift 2 ;;
         --nfs-version)       NFS_VERSION="$2";           shift 2 ;;
         --nfs-wait)          NFS_WAIT_SEC="$2";          shift 2 ;;
      -m|--mode)              CZ_MODE="$2";               shift 2 ;;
      -d|--disk)              CZ_DISK="$2";               shift 2 ;;
      -i|--image)             CZ_IMAGE_NAME="$2";         shift 2 ;;
         --compress)          CZ_COMPRESS="$2";           shift 2 ;;
         --post-action)       CZ_POST_ACTION="$2";        shift 2 ;;
         --extra-args)        CZ_EXTRA_ARGS="$2";         shift 2 ;;
         --iso)               LOCAL_ISO="$2";             shift 2 ;;
         --czversion)         CLONEZILLA_VERSION="$2";    shift 2 ;;
         --arch)              CLONEZILLA_ARCH="$2";       shift 2 ;;
      -o|--output)            OUTPUT_ISO="$2";            shift 2 ;;
         --usb-repo-detect)   USB_REPO_DETECT="true";     shift   ;;
         --usb-repo-label)    USB_REPO_LABEL="$2";        shift 2 ;;
         --keep-work-dir)     KEEP_WORK_DIR="true";       shift   ;;
         --dry-run)           DRY_RUN="true";             shift   ;;
      -v|--verbose)           VERBOSE="true";             shift   ;;
      -h|--help)              usage; exit 0                        ;;
      *) die "Unknown option: '$1'  Run '${SCRIPT_NAME} --help' for usage." ;;
    esac
  done
}

# ---- Load config file -------------------------------------------------------
load_config() {
  [[ -z "${CONFIG_FILE}" ]] && return 0
  [[ -f "${CONFIG_FILE}" ]] || die "Config file not found: ${CONFIG_FILE}"
  log "Loading config: ${CONFIG_FILE}"
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
}

# ---- Compute derived values -------------------------------------------------
compute_defaults() {
  # All build artefacts live under build/ in the repo root.
  # build/ is gitignored so large binaries never land in the repo.
  BUILD_DIR="${SCRIPT_DIR}/build"
  ISO_EXTRACT_DIR="${BUILD_DIR}/extract"

  if [[ -z "${CLONEZILLA_DOWNLOAD_URL}" ]]; then
    # Resolve default version from arch when not explicitly pinned
    if [[ -z "${CLONEZILLA_VERSION}" ]]; then
      if [[ "${CLONEZILLA_ARCH}" == "arm64" ]]; then
        CLONEZILLA_VERSION="${CLONEZILLA_ARM64_VERSION}"
      else
        CLONEZILLA_VERSION="${CLONEZILLA_AMD64_VERSION}"
      fi
    fi
    local iso_file="clonezilla-live-${CLONEZILLA_VERSION}-${CLONEZILLA_ARCH}.iso"
    if [[ "${CLONEZILLA_ARCH}" == "arm64" ]]; then
      # arm64 ISOs are published at the NCHC experimental mirror only —
      # no official arm64 stable builds exist on SourceForge as of 2026.
      CLONEZILLA_DOWNLOAD_URL="http://free.nchc.org.tw/clonezilla-live/experimental/arm/${CLONEZILLA_VERSION}/${iso_file}"
    else
      CLONEZILLA_DOWNLOAD_URL="https://downloads.sourceforge.net/project/clonezilla/clonezilla_live_stable/${CLONEZILLA_VERSION}/${iso_file}"
    fi
  elif [[ -z "${CLONEZILLA_VERSION}" ]]; then
    # URL was pinned manually but version string is still needed for the ISO filename
    if [[ "${CLONEZILLA_ARCH}" == "arm64" ]]; then
      CLONEZILLA_VERSION="${CLONEZILLA_ARM64_VERSION}"
    else
      CLONEZILLA_VERSION="${CLONEZILLA_AMD64_VERSION}"
    fi
  fi

  # Cache the downloaded ISO in build/iso/ so subsequent runs skip the download.
  # build/iso/ is preserved across runs; everything else in build/ is purged.
  # A user-supplied --iso path is used as-is (read-only; never overwritten).
  if [[ -z "${LOCAL_ISO}" ]]; then
    LOCAL_ISO="${BUILD_DIR}/iso/clonezilla-live-${CLONEZILLA_VERSION}-${CLONEZILLA_ARCH}.iso"
  fi

  # Output ISO defaults to build/ if not explicitly set via --output
  if [[ -z "${OUTPUT_ISO}" ]]; then
    OUTPUT_ISO="${BUILD_DIR}/custom-clonezilla.iso"
  fi
}

# ---- Validate configuration -------------------------------------------------
validate_config() {
  case "${CLONEZILLA_ARCH}" in
    amd64|arm64) ;;
    *) die "Invalid --arch '${CLONEZILLA_ARCH}'. Must be: amd64 | arm64" ;;
  esac

  case "${CZ_MODE}" in
    backup|restore|interactive) ;;
    *) die "Invalid --mode '${CZ_MODE}'. Must be: backup | restore | interactive" ;;
  esac

  if [[ "${CZ_MODE}" != "interactive" ]]; then
    [[ -n "${NFS_SERVER}" ]] || die "--nfs-server is required for mode '${CZ_MODE}'"
    [[ -n "${NFS_SHARE}"  ]] || die "--nfs-share is required for mode '${CZ_MODE}'"
  fi

  case "${CZ_POST_ACTION}" in
    reboot|poweroff|choose) ;;
    *) die "Invalid --post-action '${CZ_POST_ACTION}'. Must be: reboot | poweroff | choose" ;;
  esac

  case "${NFS_VERSION}" in
    3|4) ;;
    *) die "Invalid --nfs-version '${NFS_VERSION}'. Must be: 3 | 4" ;;
  esac

  if [[ -n "${LOCAL_ISO}" && "${LOCAL_ISO}" != "${BUILD_DIR}/iso/clonezilla-live-${CLONEZILLA_VERSION}-${CLONEZILLA_ARCH}.iso" ]]; then
    [[ -f "${LOCAL_ISO}" ]] || die "Local ISO not found: ${LOCAL_ISO}"
  fi
}

# ---- Check dependencies -----------------------------------------------------
check_deps() {
  section "Checking dependencies"
  local missing=()
  for cmd in xorriso wget; do
    if command -v "${cmd}" &>/dev/null; then
      debug "Found: ${cmd} ($(command -v "${cmd}"))"
    else
      missing+=("${cmd}")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required tools: ${missing[*]}"
    die "Install with: sudo apt-get install ${missing[*]}"
  fi
  log "All dependencies satisfied."
}

# ---- Obtain ISO -------------------------------------------------------------
obtain_iso() {
  section "Obtaining Clonezilla ISO"

  # Already have a usable local file
  if [[ -f "${LOCAL_ISO}" ]]; then
    log "Using local ISO: ${LOCAL_ISO}"
    return 0
  fi

  log "Downloading Clonezilla ${CLONEZILLA_VERSION} (${CLONEZILLA_ARCH}) ..."
  log "URL: ${CLONEZILLA_DOWNLOAD_URL}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY RUN] Would download to: ${LOCAL_ISO}"
    return 0
  fi

  mkdir -p "${BUILD_DIR}/iso"
  wget --progress=bar:force:noscroll \
       --timeout=60 \
       --tries=3 \
       -O "${LOCAL_ISO}" \
       "${CLONEZILLA_DOWNLOAD_URL}" \
  || die "Download failed. Check URL or use --iso to supply a local copy."

  log "Download complete: ${LOCAL_ISO}"
}

# ---- Extract ISO ------------------------------------------------------------
extract_iso() {
  section "Extracting ISO"
  debug "Source ISO    : ${LOCAL_ISO}"
  debug "Extract dir   : ${ISO_EXTRACT_DIR}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY RUN] Would extract ISO to: ${ISO_EXTRACT_DIR}"
    return 0
  fi

  mkdir -p "${ISO_EXTRACT_DIR}"

  xorriso -osirrox on \
          -indev "${LOCAL_ISO}" \
          -extract / "${ISO_EXTRACT_DIR}" \
          2>&1 \
  | { [[ "${VERBOSE}" == "true" ]] && cat || grep -iE '(error|warn)' || true; }

  # Ensure files are writable so we can modify them
  chmod -R u+w "${ISO_EXTRACT_DIR}"

  log "Extracted to: ${ISO_EXTRACT_DIR}"
}

# ---- Build the Clonezilla boot parameter string ----------------------------
# ip=dhcp        : live-boot's built-in DHCP — resolves an address during the
#                  initrd stage, before the rootfs is mounted and before any
#                  Clonezilla script runs.  This is the earliest possible point
#                  to obtain a lease and is confirmed to work on tested hardware.
# net.ifnames=0  : keep traditional eth0/eth1 names; live-boot's ip= handling
#                  and Clonezilla both expect these predictable names.
build_boot_params() {
  local p=""
  local prerun_n=0     # running counter for ocs_prerunN keys (auto-incremented)

  # Locale / keyboard
  p+=" locales=${LANGUAGE}"
  p+=" keyboard-layouts=${KEYBOARD_LAYOUT}"
  [[ -n "${KEYBOARD_VARIANT}" ]] && p+=" keyboard-variants=${KEYBOARD_VARIANT}"
  p+=" ocs_lang=${LANGUAGE}"

  # DHCP via live-boot's ip= parameter — lease is obtained in the initrd stage
  # so the interface is up before Clonezilla or any ocs_prerun script starts.
  if [[ "${NETWORK_DHCP}" == "true" ]]; then
    p+=" net.ifnames=0"
    if [[ -n "${NETWORK_INTERFACE}" ]]; then
      p+=" ip=${NETWORK_INTERFACE}:dhcp"
    else
      p+=" ip=dhcp"
    fi
  fi

  # NFS mount via ocs_prerun — runs before Clonezilla's UI starts.
  #
  # prerunN+0: sleep so the ip=dhcp lease (obtained in initrd) has settled.
  # prerunN+1: mount the NFS share at Clonezilla's image directory.
  # prerunN+2: write ocsroot_src=skip to ocs-live.conf so ocs-prep-repo skips
  #            the storage-type selection dialog (it checks: if ocsroot_src is
  #            already set, skip the menu — source: sbin/ocs-prep-repo line 1187).
  # prerunN+3: write ocs_live_type=device-image so the clonezilla script skips
  #            the mode selection dialog and goes straight to save/restore
  #            (source: sbin/clonezilla line 52).
  if [[ -n "${NFS_SERVER}" && -n "${NFS_SHARE}" ]]; then
    local nfs_mount_opts="nfsvers=${NFS_VERSION}"
    [[ "${NFS_OPTS}" != "defaults" && -n "${NFS_OPTS}" ]] \
      && nfs_mount_opts="${nfs_mount_opts},${NFS_OPTS}"

    p+=" ocs_prerun$(( prerun_n += 1 ))=\"sleep ${NFS_WAIT_SEC}\""
    p+=" ocs_prerun$(( prerun_n += 1 ))=\"mount -t nfs -o ${nfs_mount_opts} ${NFS_SERVER}:${NFS_SHARE} /home/partimag\""
    p+=" ocs_prerun$(( prerun_n += 1 ))=\"echo ocsroot_src=skip >> /etc/ocs/ocs-live.conf\""
    p+=" ocs_prerun$(( prerun_n += 1 ))=\"echo ocs_live_type=device-image >> /etc/ocs/ocs-live.conf\""
  fi

  # USB local device detection — scan for a removable block device and mount
  # it as the image repo.  The detection script is injected into the ISO by
  # inject_usb_detect_script() and referenced here via the live-boot mount
  # point (/lib/live/mount/medium is live-boot's standard path for the boot
  # medium — USB stick, CD, etc. — after the squashfs is fully mounted).
  if [[ "${USB_REPO_DETECT}" == "true" ]]; then
    p+=" ocs_prerun$(( prerun_n += 1 ))=\"bash /lib/live/mount/medium/scripts/cz-usb-repo.sh\""
  fi

  # Clonezilla operation mode
  case "${CZ_MODE}" in
    backup)
      local ocs_cmd="ocs-sr -q2 -c -j2 -${CZ_COMPRESS} -i 4096 -sfsck -senc"
      [[ -n "${CZ_EXTRA_ARGS}" ]] && ocs_cmd+=" ${CZ_EXTRA_ARGS}"
      ocs_cmd+=" -p ${CZ_POST_ACTION} savedisk ${CZ_IMAGE_NAME} ${CZ_DISK}"
      p+=" ocs_live_run=\"${ocs_cmd}\""
      p+=" ocs_live_batch=\"yes\""
      ;;
    restore)
      local ocs_cmd="ocs-sr -g auto -e1 auto -e2 -r -j2"
      [[ -n "${CZ_EXTRA_ARGS}" ]] && ocs_cmd+=" ${CZ_EXTRA_ARGS}"
      ocs_cmd+=" -p ${CZ_POST_ACTION} restoredisk ${CZ_IMAGE_NAME} ${CZ_DISK}"
      p+=" ocs_live_run=\"${ocs_cmd}\""
      p+=" ocs_live_batch=\"yes\""
      ;;
    *)
      p+=" ocs_live_run=\"ocs-live-general\""
      p+=" ocs_live_batch=\"no\""
      ;;
  esac

  printf '%s' "${p}"
}

# ---- Build a GRUB2 menu entry -----------------------------------------------
build_grub_entry() {
  local label="$1"
  local params="$2"
  cat <<EOF
menuentry "${label}" {
  search --set -f /live/vmlinuz
  linux  /live/vmlinuz boot=live union=overlay username=user hostname=clonezilla quiet${params}
  initrd /live/initrd.img
}
EOF
}

# ---- Modify GRUB2 config (UEFI boot) ----------------------------------------
modify_grub_cfg() {
  section "Modifying GRUB2 config (UEFI)"

  local grub_cfg="${ISO_EXTRACT_DIR}/boot/grub/grub.cfg"
  if [[ ! -f "${grub_cfg}" ]]; then
    warn "GRUB config not found at ${grub_cfg} — skipping UEFI boot modification."
    return 0
  fi

  local boot_params entry_label
  boot_params="$(build_boot_params)"

  case "${CZ_MODE}" in
    backup)      entry_label="Clonezilla Backup  [${CZ_IMAGE_NAME} <- ${CZ_DISK}] [${BUILD_DATE_TAG}]" ;;
    restore)     entry_label="Clonezilla Restore [${CZ_IMAGE_NAME} -> ${CZ_DISK}] [${BUILD_DATE_TAG}]" ;;
    interactive) entry_label="Clonezilla Live Custom (${LANGUAGE} / ${KEYBOARD_LAYOUT}) [${BUILD_DATE_TAG}]" ;;
  esac

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY RUN] Would prepend entry to: ${grub_cfg}"
    log "[DRY RUN] Entry label: ${entry_label}"
    debug "Entry:\n$(build_grub_entry "${entry_label}" "${boot_params}")"
    return 0
  fi

  cp "${grub_cfg}" "${grub_cfg}.orig"

  local new_entry
  new_entry="$(build_grub_entry "${entry_label}" "${boot_params}")"

  # Prepend our entry at the top; strip duplicate set default/timeout lines from
  # the original so the menu correctly defaults to our entry (index 0).
  {
    printf "# CustomCloneZilla %s build %s\n" "${VERSION}" "${BUILD_DATE_TAG}"
    printf "set default=0\n"
    printf "set timeout=30\n\n"
    printf "%s\n" "${new_entry}"
    grep -v '^set default=' "${grub_cfg}.orig" | grep -v '^set timeout='
  } > "${grub_cfg}"

  log "Updated GRUB config: ${grub_cfg}"
  debug "Entry:\n${new_entry}"

  # ---- Also patch grub.cfg INSIDE efi.img ------------------------------------
  # Some UEFI firmware (e.g. Lenovo T590) loads GRUB directly from the FAT
  # EFI partition (efi.img) and its configfile chain never reaches the
  # ISO9660 grub.cfg we modified above.  Writing the same full grub.cfg into
  # efi.img ensures our custom entry appears on those machines too.
  # Font/background paths won't resolve from the EFI partition, so GRUB
  # falls back to a plain text menu — all entries still show and are bootable.
  local efi_img="${ISO_EXTRACT_DIR}/boot/grub/efi.img"
  if [[ -f "${efi_img}" ]]; then
    if command -v mcopy &>/dev/null; then
      cp "${efi_img}" "${efi_img}.orig"
      if mcopy -o -i "${efi_img}" "${grub_cfg}" ::/boot/grub/grub.cfg 2>/dev/null; then
        log "Updated efi.img grub.cfg"
      else
        warn "mcopy failed — efi.img grub.cfg not updated (T590 may still show original menu)"
        rm -f "${efi_img}.orig"
      fi
    else
      warn "mtools not installed — efi.img not updated.  Install with: sudo apt install mtools"
    fi
  fi
}

# ---- Build isolinux/syslinux APPEND string ----------------------------------
build_isolinux_params() {
  # isolinux APPEND is a single line — strip surrounding whitespace
  build_boot_params | tr -s ' ' | sed 's/^ //; s/ $//'
}

# ---- Build an isolinux/syslinux LABEL block ---------------------------------
build_isolinux_entry() {
  local label="$1"
  local params="$2"
  cat <<EOF
LABEL custom
  MENU LABEL ${label}
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live union=overlay username=user hostname=clonezilla quiet${params}

EOF
}

# ---- Modify isolinux/syslinux config (legacy BIOS boot) ---------------------
modify_isolinux_cfg() {
  section "Modifying isolinux/syslinux config (BIOS)"

  # isolinux/syslinux is an x86-only bootloader — not present in arm64 ISOs.
  if [[ "${CLONEZILLA_ARCH}" == "arm64" ]]; then
    log "Skipping isolinux/syslinux modification — not applicable for arm64 (UEFI-only)."
    return 0
  fi

  # Clonezilla places these configs in known locations
  local cfg_candidates=(
    "${ISO_EXTRACT_DIR}/isolinux/isolinux.cfg"
    "${ISO_EXTRACT_DIR}/syslinux/syslinux.cfg"
    "${ISO_EXTRACT_DIR}/isolinux/syslinux.cfg"
  )

  local found_any=false
  local boot_params entry_label
  boot_params="$(build_isolinux_params)"

  case "${CZ_MODE}" in
    backup)      entry_label="NFS Backup: ${CZ_IMAGE_NAME} <- ${CZ_DISK} [${BUILD_DATE_TAG}]" ;;
    restore)     entry_label="NFS Restore: ${CZ_IMAGE_NAME} -> ${CZ_DISK} [${BUILD_DATE_TAG}]" ;;
    interactive) entry_label="Custom Clonezilla (${LANGUAGE} / ${KEYBOARD_LAYOUT}) [${BUILD_DATE_TAG}]" ;;
  esac

  for cfg in "${cfg_candidates[@]}"; do
    [[ -f "${cfg}" ]] || continue
    found_any=true

    if [[ "${DRY_RUN}" == "true" ]]; then
      log "[DRY RUN] Would update: ${cfg}"
      continue
    fi

    cp "${cfg}" "${cfg}.orig"

    local new_entry
    new_entry="$(build_isolinux_entry "${entry_label}" "${boot_params}")"

    {
      printf "# Generated by CustomCloneZilla %s on %s\n" "${VERSION}" "$(date -Iseconds)"
      printf "DEFAULT custom\n"
      printf "TIMEOUT 300\n\n"
      printf "%s\n" "${new_entry}"
      printf "# ---- Original entries ----\n"
      grep -v '^DEFAULT' "${cfg}.orig" | grep -v '^TIMEOUT'
    } > "${cfg}"

    log "Updated isolinux config: ${cfg}"
  done

  if [[ "${found_any}" == "false" ]]; then
    warn "No isolinux/syslinux config found — skipping legacy BIOS modification."
  fi
}

# ---- Write build metadata into the ISO tree ---------------------------------
write_build_info() {
  section "Writing build metadata"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY RUN] Would write: ${ISO_EXTRACT_DIR}/build-info.txt"
    return 0
  fi

  local out="${ISO_EXTRACT_DIR}/build-info.txt"
  cat > "${out}" <<METAEOF
CustomCloneZilla Build
======================
ISO name   : $(basename "${OUTPUT_ISO}")
Build date : ${BUILD_TIMESTAMP}
Build tag  : ${BUILD_DATE_TAG}
Base ISO   : $(basename "${LOCAL_ISO}")
Language   : ${LANGUAGE}
Keyboard   : ${KEYBOARD_LAYOUT}${KEYBOARD_VARIANT:+ (${KEYBOARD_VARIANT})}
Timezone   : ${TIMEZONE}
DHCP       : ${NETWORK_DHCP}
Mode       : ${CZ_MODE}
$(if [[ -n "${NFS_SERVER}" ]]; then
  printf "NFS server : %s\n" "${NFS_SERVER}"
  printf "NFS share  : %s\n" "${NFS_SHARE}"
fi)
To verify a USB key written from this ISO, mount it and check:
  cat /build-info.txt
METAEOF

  log "build-info.txt written"
  debug "$(cat "${out}")"
}

# ---- Inject USB repository detection script into the ISO tree ---------------
# The script scans /sys/block for removable block devices and mounts the first
# matching partition at /home/partimag (Clonezilla's default ocsroot).  It also
# writes ocsroot_src=skip and ocs_live_type=device-image into ocs-live.conf so
# Clonezilla's storage-selection and mode-selection dialogs are suppressed.
#
# The script lands at /scripts/cz-usb-repo.sh in the ISO (non-squashfs layer).
# live-boot makes the boot medium available at /lib/live/mount/medium/ after the
# squashfs is fully mounted, so ocs_prerun can reference it there at runtime.
inject_usb_detect_script() {
  [[ "${USB_REPO_DETECT}" != "true" ]] && return 0
  section "Injecting USB repo detection script"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY RUN] Would write: ${ISO_EXTRACT_DIR}/scripts/cz-usb-repo.sh"
    return 0
  fi

  local scripts_dir="${ISO_EXTRACT_DIR}/scripts"
  mkdir -p "${scripts_dir}"
  local script="${scripts_dir}/cz-usb-repo.sh"

  # USB_REPO_LABEL is substituted at build time; the script compares it at
  # runtime against the partition's volume label returned by blkid.
  cat > "${script}" <<SCRIPT
#!/bin/bash
# Auto-detect a USB storage device and mount it as the Clonezilla image repo.
# Generated by CustomCloneZilla ${VERSION} on ${BUILD_DATE_TAG}
# Invoked via ocs_prerun from the Clonezilla boot command line.
USB_REPO_LABEL="${USB_REPO_LABEL}"

for devpath in /sys/block/sd*; do
  dev=\$(basename "\$devpath")
  [ "\$(cat "\$devpath/removable" 2>/dev/null)" = "1" ] || continue
  for part in /dev/\${dev}[0-9]*; do
    [ -b "\$part" ] || continue
    if [ -n "\$USB_REPO_LABEL" ]; then
      actual_label=\$(blkid -s LABEL -o value "\$part" 2>/dev/null)
      [ "\$actual_label" = "\$USB_REPO_LABEL" ] || continue
    fi
    if mount "\$part" /home/partimag 2>/dev/null; then
      echo "ocsroot_src=skip"           >> /etc/ocs/ocs-live.conf
      echo "ocs_live_type=device-image" >> /etc/ocs/ocs-live.conf
      echo "[usb-repo] Mounted \$part as Clonezilla image repo (label: \${USB_REPO_LABEL:-any})"
      exit 0
    fi
  done
done
echo "[usb-repo] No suitable USB storage device found"
exit 1
SCRIPT

  chmod +x "${script}"
  log "USB detection script written: ${script}"
}

# ---- Repack bootable ISO ----------------------------------------------------
repack_iso() {
  section "Repacking ISO"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY RUN] Would create ISO: ${OUTPUT_ISO}"
    return 0
  fi

  mkdir -p "$(dirname "${OUTPUT_ISO}")"
  rm -f "${OUTPUT_ISO}"
  log "Building ISO: ${OUTPUT_ISO}"

  local xorriso_log="${BUILD_DIR}/xorriso.log"

  # Extract MBR bootstrap code (first 432 bytes) for USB hybrid boot.
  # This carries the original hybrid MBR so the USB is bootable on BIOS machines.
  # Skipped for arm64: no hybrid MBR is needed on UEFI-only ARM hardware.
  local mbr_file="${BUILD_DIR}/isohdpfx.bin"
  if [[ "${CLONEZILLA_ARCH}" != "arm64" ]]; then
    dd if="${LOCAL_ISO}" bs=432 count=1 of="${mbr_file}" 2>/dev/null \
      && debug "MBR extracted: ${mbr_file}" \
      || warn "Could not extract MBR — USB hybrid boot may not work."
  fi

  # Locate the isolinux/syslinux binary inside the extracted tree
  local isolinux_bin="" isolinux_cat=""
  for candidate in \
      "${ISO_EXTRACT_DIR}/syslinux/isolinux.bin" \
      "${ISO_EXTRACT_DIR}/isolinux/isolinux.bin"; do
    if [[ -f "${candidate}" ]]; then
      isolinux_bin="${candidate#${ISO_EXTRACT_DIR}/}"
      isolinux_cat="$(dirname "${isolinux_bin}")/boot.cat"
      break
    fi
  done

  local efi_img="${ISO_EXTRACT_DIR}/boot/grub/efi.img"

  # Build boot flags as a proper bash array so IFS=$'\n\t' doesn't swallow
  # individual flags (unquoted string expansion breaks with this IFS).
  local boot_flags=()
  if [[ "${CLONEZILLA_ARCH}" == "arm64" ]]; then
    # ARM64: UEFI-only ISO — no hybrid MBR and no isolinux/syslinux.
    # The Pi 5 (and any other ARM64 UEFI board) loads GRUB directly from the
    # EFI system partition.  A Pi 5 running the rpi5-uefi firmware
    # (https://github.com/worproject/rpi5-uefi) will boot this USB as a
    # standard ARM64 UEFI device.
    if [[ -f "${efi_img}" ]]; then
      boot_flags+=( -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot )
    else
      warn "efi.img not found at boot/grub/efi.img — arm64 ISO may not boot via UEFI."
    fi
  else
    # AMD64: hybrid ISO supports both legacy BIOS (isolinux) and UEFI (GRUB2).
    if [[ -f "${mbr_file}" ]]; then
      boot_flags+=( --grub2-mbr "${mbr_file}" --protective-msdos-label -partition_offset 16 )
    fi
    if [[ -n "${isolinux_bin}" ]]; then
      boot_flags+=( -c "${isolinux_cat}" -b "${isolinux_bin}" )
      boot_flags+=( -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info )
    fi
    if [[ -f "${efi_img}" ]]; then
      boot_flags+=( -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot -isohybrid-gpt-basdat )
    fi
  fi

  debug "Boot flags: ${boot_flags[*]}"

  # xorriso -as mkisofs: rebuilds a bootable hybrid ISO from the extracted tree.
  # The original MBR (--grub2-mbr) ensures USB hybrid boot works on BIOS machines.
  # The updated efi.img in the extract dir carries our custom grub.cfg so UEFI
  # firmware sees the custom menu entry without needing a chain-loader lookup.
  log "Repacking ISO ..."
  if xorriso -as mkisofs \
       -r \
       -V "CLONEZILLA_CUSTOM" \
       -o "${OUTPUT_ISO}" \
       -J -joliet-long \
       "${boot_flags[@]}" \
       "${ISO_EXTRACT_DIR}" \
       >"${xorriso_log}" 2>&1; then
    [[ "${VERBOSE}" == "true" ]] && cat "${xorriso_log}"
    rm -f "${xorriso_log}"
  else
    cat "${xorriso_log}" >&2
    rm -f "${xorriso_log}"
    die "ISO repack failed. Re-run with --verbose for full xorriso output."
  fi

  local size
  size="$(du -sh "${OUTPUT_ISO}" 2>/dev/null | cut -f1)"
  log "ISO created: ${OUTPUT_ISO} (${size})"
}

# ---- Print run summary ------------------------------------------------------
print_summary() {
  section "Build Summary"
  hr
  printf "  %-22s %s\n" "Output ISO:"      "${OUTPUT_ISO}"
  printf "  %-22s %s\n" "Architecture:"    "${CLONEZILLA_ARCH}"
  hr
  printf "  %-22s %s\n" "Language:"        "${LANGUAGE}"
  printf "  %-22s %s\n" "Keyboard layout:" "${KEYBOARD_LAYOUT}${KEYBOARD_VARIANT:+ (${KEYBOARD_VARIANT})}"
  printf "  %-22s %s\n" "Timezone:"        "${TIMEZONE}"
  hr
  if [[ "${NETWORK_DHCP}" == "true" ]]; then
    local iface_str="${NETWORK_INTERFACE:-all interfaces}"
    printf "  %-22s %s\n" "DHCP:" "enabled (${iface_str})"
  else
    printf "  %-22s %s\n" "DHCP:" "disabled"
  fi
  hr
  if [[ -n "${NFS_SERVER}" ]]; then
    printf "  %-22s %s\n" "NFS server:"    "${NFS_SERVER}"
    printf "  %-22s %s\n" "NFS share:"     "${NFS_SHARE}"
    printf "  %-22s %s\n" "NFS version:"   "${NFS_VERSION}"
    printf "  %-22s %s\n" "NFS wait:"      "${NFS_WAIT_SEC}s"
  else
    printf "  %-22s %s\n" "NFS:" "not configured (use --nfs-server / --nfs-share)"
  fi
  hr
  printf "  %-22s %s\n" "Mode:"          "${CZ_MODE}"
  if [[ "${CZ_MODE}" != "interactive" ]]; then
    printf "  %-22s %s\n" "Disk:"          "${CZ_DISK}"
    printf "  %-22s %s\n" "Image name:"    "${CZ_IMAGE_NAME}"
    printf "  %-22s %s\n" "Compression:"   "${CZ_COMPRESS}"
    printf "  %-22s %s\n" "Post action:"   "${CZ_POST_ACTION}"
    [[ -n "${CZ_EXTRA_ARGS}" ]] && \
      printf "  %-22s %s\n" "Extra ocs-sr:" "${CZ_EXTRA_ARGS}"
  fi
  hr
  if [[ "${USB_REPO_DETECT}" == "true" ]]; then
    local label_str="${USB_REPO_LABEL:-any removable device}"
    printf "  %-22s %s\n" "USB repo detect:" "enabled (label: ${label_str})"
    printf "  %-22s %s\n" "" "script: /scripts/cz-usb-repo.sh"
  fi
  hr
  if [[ "${DRY_RUN}" != "true" ]]; then
    printf "\n  ${BOLD}Write to USB:${RESET}\n"
    printf "    sudo ./burn-usb.sh --iso %s /dev/sdX\n\n" "${OUTPUT_ISO}"
  fi
}

# ---- Cleanup ----------------------------------------------------------------
cleanup() {
  # Always remove temp files from build/
  rm -f "${BUILD_DIR}/xorriso.log" "${BUILD_DIR}/isohdpfx.bin" 2>/dev/null || true

  # Remove the extracted ISO tree (regenerated on every run).
  # The downloaded source ISO lives in build/iso/ and is intentionally
  # kept so subsequent builds skip the download step.
  if [[ -d "${ISO_EXTRACT_DIR}" ]]; then
    if [[ "${KEEP_WORK_DIR}" == "true" ]]; then
      log "Extracted tree preserved: ${ISO_EXTRACT_DIR}"
    else
      debug "Removing extracted tree: ${ISO_EXTRACT_DIR}"
      rm -rf "${ISO_EXTRACT_DIR}"
    fi
  fi
}

# ---- Main -------------------------------------------------------------------
main() {
  # Two-pass argument handling:
  # Pass 1 — extract --config path only (before sourcing the config file)
  local raw_args=("$@")
  local i
  for ((i = 0; i < ${#raw_args[@]}; i++)); do
    case "${raw_args[$i]}" in
      -c|--config)
        CONFIG_FILE="${raw_args[$((i + 1))]}"
        break
        ;;
    esac
  done

  load_config           # source config (overrides built-in defaults)
  parse_args "$@"       # CLI args override config values
  compute_defaults      # derive paths that depend on final variable values
  validate_config

  [[ "${DRY_RUN}" == "true" ]] && warn "DRY RUN — no files will be modified."

  check_deps
  trap cleanup EXIT

  # Purge all build artefacts except the ISO cache so each run starts clean.
  # build/iso/ holds the downloaded source ISO and is always preserved.
  if [[ "${DRY_RUN}" != "true" ]]; then
    mkdir -p "${BUILD_DIR}/iso"
    find "${BUILD_DIR}" -mindepth 1 -maxdepth 1 ! -name 'iso' \
      -exec sudo rm -rf {} + 2>/dev/null || true
    debug "Build directory purged (build/iso/ retained)"
  fi

  obtain_iso
  extract_iso
  write_build_info
  inject_usb_detect_script
  modify_grub_cfg
  modify_isolinux_cfg
  repack_iso
  print_summary

  log "Done."
}

main "$@"
