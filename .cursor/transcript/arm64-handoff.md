# ARM64 Implementation Handoff

**Session transcript:** `arm64-session-a257ff78.jsonl` (in this directory)
**Session date:** 2026-04-18
**Conversation ID:** `a257ff78-75b2-4e8c-adb7-2e4f1e4e1271`

This document is written for a future agent continuing ARM64 / Raspberry Pi 5
work on CustomCloneZilla.  It summarises what was built, every file changed,
design decisions made, and what still needs to be done.

---

## What was built in this session

Two features were added to `build-iso.sh`:

1. **`--arch arm64`** — downloads the experimental ARM64 Clonezilla ISO from the
   NCHC mirror, skips the x86-only isolinux step, and repacks as a UEFI-only ISO
   (no hybrid MBR).

2. **`--usb-repo-detect` / `--usb-repo-label LABEL`** — injects a shell script
   into the ISO at build time.  At boot, an `ocs_prerun` command calls the script
   via the live-boot mount point; it scans `/sys/block/sd*/removable` for a
   removable USB block device, optionally matches a volume label, mounts the
   partition at `/home/partimag`, and writes the Clonezilla conf flags that
   suppress the storage-type and mode-selection dialogs.

A reference doc was also created at `docs/arm64-raspberry-pi5.md`.

---

## Files changed

### `build-iso.sh`

| Section | Change |
|---------|--------|
| **Defaults** (top of file) | Replaced single `CLONEZILLA_VERSION` + `CLONEZILLA_ARCH` with `CLONEZILLA_AMD64_VERSION`, `CLONEZILLA_ARM64_VERSION`, and an empty `CLONEZILLA_VERSION` that auto-resolves in `compute_defaults()` |
| **Defaults** | Added `USB_REPO_DETECT="false"` and `USB_REPO_LABEL=""` |
| **`usage()`** | Added `--arch ARCH` under ISO OPTIONS; added new USB REPOSITORY OPTIONS block; added Raspberry Pi 5 example |
| **`parse_args()`** | Added `--arch`, `--usb-repo-detect`, `--usb-repo-label` |
| **`compute_defaults()`** | Auto-sets `CLONEZILLA_VERSION` from arch; selects download URL: SourceForge for `amd64`, NCHC experimental mirror for `arm64` |
| **`validate_config()`** | Added arch validation: `amd64 \| arm64` |
| **`build_boot_params()`** | Replaced hardcoded `ocs_prerun1`…`ocs_prerun4` with an auto-incrementing counter `$(( prerun_n += 1 ))`; added USB detection prerun block |
| **`inject_usb_detect_script()`** | **New function** — writes `/scripts/cz-usb-repo.sh` into the extracted ISO tree when `USB_REPO_DETECT=true` |
| **`modify_isolinux_cfg()`** | Early return with log message when `CLONEZILLA_ARCH=arm64` |
| **`repack_iso()`** | Skips MBR `dd` extraction for arm64; branches boot flag construction: arm64 gets EFI-only flags, amd64 keeps the existing hybrid MBR + isolinux + EFI flags |
| **`print_summary()`** | Added `Architecture:` row; added USB repo detect section when enabled |
| **`main()`** | Added `inject_usb_detect_script` call between `write_build_info` and `modify_grub_cfg` |

### `config/settings.conf`

- Added `CLONEZILLA_ARCH`, `CLONEZILLA_AMD64_VERSION`, `CLONEZILLA_ARM64_VERSION`
  with comments
- Added `USB_REPO_DETECT` / `USB_REPO_LABEL` section with full Raspberry Pi 5
  example workflow in comments
- Updated `CZ_DISK` comment to list Pi 5 device names (`nvme0n1`, `mmcblk0`, `sda`)

### `docs/arm64-raspberry-pi5.md` *(new)*

End-user reference covering:
- Pi 5 UEFI firmware install (worproject/rpi5-uefi, NumberOneGit fork for D0 boards)
- EEPROM `BOOT_ORDER=0xf164` (USB-first)
- NVMe device naming
- Full step-by-step restore walkthrough (two-USB workflow)
- NFS + USB detection ordering
- Troubleshooting section

---

## Key design decisions

### Why the NCHC experimental mirror

Clonezilla's SourceForge stable channel only publishes `amd64`.  The DRBL team
publishes experimental ARM64 builds at:

```
http://free.nchc.org.tw/clonezilla-live/experimental/arm/<VERSION>/
```

The latest confirmed build as of this session was `3.3.2-21` (2026-04-11).  The
URL pattern is:

```
http://free.nchc.org.tw/clonezilla-live/experimental/arm/${VERSION}/clonezilla-live-${VERSION}-arm64.iso
```

### Why UEFI-only for arm64

The Pi 5 has no legacy BIOS.  ARM hardware in general does not use isolinux/syslinux
(those are x86 bootloaders that require the PC BIOS INT 13h disk services).
The arm64 ISO only needs an EFI boot record; the hybrid MBR bootstrap is x86
machine code and serves no purpose on ARM.

### Why the USB detection script lives in the ISO, not inline in kernel params

`ocs_prerun` values are embedded in the kernel command line, which has a practical
~4096-byte limit.  Multi-device iteration with optional label matching is too long
to be a safe one-liner.  Instead, the script is written to `/scripts/cz-usb-repo.sh`
in the ISO's non-squashfs tree at build time.  At runtime, live-boot mounts the
boot medium at `/lib/live/mount/medium/` (standard live-boot path, available
after squashfs is fully mounted), so `ocs_prerun` can call:

```
bash /lib/live/mount/medium/scripts/cz-usb-repo.sh
```

### Why the auto-incrementing prerun counter

The original code had hardcoded `ocs_prerun1`…`ocs_prerun4` for NFS.  Adding USB
detection as `ocs_prerun5` would have worked but would break if someone later
added another prerun between NFS and USB.  The counter (`$(( prerun_n += 1 ))`)
ensures the numbers are always sequential regardless of which features are enabled,
and Clonezilla's `ocs-run-boot-param` processes them in `sort -V` order.

---

## Outstanding work / known gaps

The following items were identified but not implemented.  They are listed in
rough priority order.

### 1. Pi 5 native boot (without UEFI firmware) *(not started)*

The current arm64 path requires the third-party rpi5-uefi firmware to be
pre-installed on the Pi.  A native Pi boot path (no UEFI required) would need:

- `config.txt` in the ISO root (Pi firmware configuration)
- Device tree blobs for BCM2712 (`bcm2712-rpi-5-b.dtb`) in `/dtbs/`
- A `cmdline.txt` alongside `config.txt` carrying the kernel parameters
- U-Boot or a direct kernel image in a Pi-compatible format

This would be a significant addition.  The UEFI path is simpler and covers most
homelab / deployment use cases.

### 2. Test with a real Pi 5 + UEFI firmware *(not tested)*

The arm64 build has been verified:
- Script syntax (`bash -n`)
- Dry-run output (correct URL, correct skip of isolinux, correct summary)
- GRUB config modification logic (same code path as amd64)

It has **not** been validated on real hardware.  The first real test should verify:
- The ISO writes to USB and the Pi 5 loads GRUB from it
- The GRUB menu entry appears and boots correctly
- The `cz-usb-repo.sh` script runs and mounts the image USB
- Clonezilla completes a full backup and restore cycle to/from NVMe

### 3. `check-clonezilla-compat.sh` arm64 awareness *(not started)*

The compatibility checker (`check-clonezilla-compat.sh`) validates Clonezilla
internals before a version bump.  It currently has no concept of arm64 vs amd64
— it checks the upstream `sbin/` scripts which are architecture-neutral, so
functionally it works for both.  However it should:
- Accept a `--arch` flag that sets `CLONEZILLA_ARM64_VERSION` as the version to check
- Warn when the arm64 version differs from the amd64 stable version (they may
  diverge on experimental builds)

### 4. `README.md` update *(not started)*

`README.md` still says:
- Only amd64 is available for Clonezilla 3.x
- The ISO options table shows `--czversion` with a hardcoded version string

It should be updated to:
- Document `--arch arm64`
- Update the ISO options table
- Link to `docs/arm64-raspberry-pi5.md`
- Note that the experimental arm64 builds are not subject to the same
  `check-clonezilla-compat.sh` green-run guarantee as amd64 stable builds

### 5. `Makefile` arm64 targets *(not started)*

The Makefile has `backup`, `restore`, `interactive` targets that all pass
`CLONEZILLA_ARCH=amd64` implicitly.  Convenience targets for Pi 5 would be
useful:

```makefile
arm64-restore:
	./build-iso.sh \
	  --arch arm64 \
	  --mode restore \
	  --disk $(DISK) \
	  --image $(IMAGE) \
	  --usb-repo-detect \
	  --usb-repo-label $(USB_LABEL) \
	  --post-action $(POST_ACTION) \
	  $(if $(CONFIG),--config $(CONFIG),)
```

### 6. `burn-usb.sh` verification for arm64 *(not started)*

`burn-usb.sh` uses `dd` for the raw write, which is correct for both amd64 and
arm64 ISOs.  However it currently mounts the USB after writing and reads
`build-info.txt` from the root of the ISO.  It should be verified that the
arm64 ISO (UEFI-only, no hybrid partition table) mounts and shows `build-info.txt`
correctly.

### 7. USB detection: NVMe as image repo *(not started)*

The current USB detection script only scans `sd*` devices (USB mass storage
exposes as SCSI block devices).  An NVMe drive used as the image repo (e.g.
booting from SD, restoring to a separate NVMe) would appear as `nvme0n1` and
would not be found by the current script.  A more general approach would scan
both `sd*` and `nvme*` if needed.

### 8. efi.img patching for arm64 *(unknown status)*

The `modify_grub_cfg()` function patches `grub.cfg` inside `efi.img` using
`mcopy` (mtools).  This is known to be needed on some x86 UEFI firmware (Lenovo
T590) that loads GRUB directly from the EFI partition.  Whether the same is
needed on Pi 5 UEFI firmware has not been tested.  The code path runs for arm64
as well, so if `mtools` is installed the patch will be applied — but the Pi 5
UEFI behaviour with and without the patch is unknown.

---

## Technical reference

### ARM64 Clonezilla download URL pattern

```
http://free.nchc.org.tw/clonezilla-live/experimental/arm/<VERSION>/clonezilla-live-<VERSION>-arm64.iso
```

Versions confirmed available as of 2026-04-18: `3.3.2-21`, `3.3.2-20`, `3.3.2-18`, `3.3.2-16`

### Pi 5 UEFI firmware repos

- Main: https://github.com/worproject/rpi5-uefi  (archived; tested on C1 boards)
- Active fork for D0 boards: https://github.com/NumberOneGit/rpi5-uefi

### Pi 5 EEPROM boot order values

| Hex digit | Boot device |
|-----------|-------------|
| `1` | SD card |
| `4` | USB mass storage |
| `6` | NVMe (PCIe) |
| `f` | Restart list |

`BOOT_ORDER=0xf164` = USB first (recommended for recovery scenarios).

### Pi 5 disk device names

| Device | Description |
|--------|-------------|
| `nvme0n1` | NVMe via M.2 HAT+ (PCIe) |
| `mmcblk0` | Built-in SD card |
| `sda` | USB storage |

### live-boot mount point

At `ocs_prerun` execution time (after squashfs is fully mounted), the boot
medium is available at:

```
/lib/live/mount/medium/
```

Files written to the root of the ISO (non-squashfs layer) are accessible under
this path at runtime.

### Clonezilla dialog-suppression flags

These are written by the USB detection script (and the NFS prerun) into
`/etc/ocs/ocs-live.conf`:

| Flag | Effect |
|------|--------|
| `ocsroot_src=skip` | `ocs-prep-repo` skips storage-type dialog |
| `ocs_live_type=device-image` | `clonezilla` script skips mode dialog |

Both flags are checked before any dialog is shown and must be present before
Clonezilla's main script runs.  They are validated by `check-clonezilla-compat.sh`.

### `ocs_prerun` ordering

Clonezilla's `ocs-run-boot-param` uses `sort -V` to order numbered `ocs_prerunN`
kernel parameters.  The auto-counter in `build_boot_params()` guarantees sequential
numbering: NFS uses prerun 1-4, USB detection appends as the next number (5 when
NFS is present, 1 when standalone).

---

## How to resume this work

1. Open `build-iso.sh` — the arm64 changes are integrated throughout.
2. Read `docs/arm64-raspberry-pi5.md` for the end-user view.
3. Read this file for design context and the outstanding work list above.
4. The raw conversation JSONL is in `arm64-session-a257ff78.jsonl` (same directory)
   for full context including all tool calls, web searches, and intermediate reasoning.
5. Start with item 2 (hardware test) or item 4 (README update) — both are
   self-contained and have no dependencies on each other.
