# ARM64 / Raspberry Pi 5 Guide

This document covers building and using CustomCloneZilla ISOs on ARM64 hardware,
with a focus on the Raspberry Pi 5 + NVMe SSD configuration.

---

## Overview

Clonezilla's official stable releases are `amd64`-only.  The DRBL team publishes
experimental ARM64 builds on the [NCHC mirror](https://free.nchc.org.tw/clonezilla-live/experimental/arm/).
`build-iso.sh` targets these builds via `--arch arm64`.

Key differences from the standard `amd64` build:

| Aspect | amd64 | arm64 |
|--------|-------|-------|
| Download source | SourceForge (stable) | NCHC mirror (experimental) |
| Default version | `3.3.1-35` | `3.3.2-21` |
| Boot method | Hybrid ISO (BIOS + UEFI) | UEFI-only |
| isolinux / syslinux | Included | **Skipped** (x86-only bootloader) |
| Hybrid MBR | Extracted from source ISO | **Skipped** (not needed for UEFI-only) |
| USB write | `burn-usb.sh` as normal | `burn-usb.sh` as normal |

---

## Hardware prerequisites

### Raspberry Pi 5 UEFI firmware (one-time setup)

The Pi 5's native bootloader cannot boot a generic ARM64 UEFI ISO directly.
Install the community UEFI firmware to make the Pi 5 behave as a standard
ARM64 UEFI machine:

1. Download the latest release from [worproject/rpi5-uefi](https://github.com/worproject/rpi5-uefi)
   (use the [NumberOneGit fork](https://github.com/NumberOneGit/rpi5-uefi) for
   newer D0-revision boards — all 16 GB and 2 GB models and Compute Modules).
2. Format a FAT32 drive or partition and extract the firmware archive to its root.
3. Boot the Pi from that drive once to confirm UEFI loads correctly.

> **Note:** The UEFI firmware has a known framebuffer issue on D0 boards with
> older EEPROM.  Update the Pi 5 EEPROM to the June 2025 or later release
> (`sudo rpi-eeprom-update -a`) before flashing the UEFI firmware.

### Boot order — USB before NVMe

By default the Pi 5 EEPROM does **not** prioritize USB over NVMe.  Set the boot
order once so the Clonezilla USB is tried first:

```bash
# Run on the Raspberry Pi 5 itself
sudo rpi-eeprom-config --edit
```

Set or update this line, then save and reboot:

```ini
BOOT_ORDER=0xf164
```

Boot mode values in `BOOT_ORDER` (right-to-left priority):

| Hex digit | Boot device |
|-----------|-------------|
| `1` | SD card |
| `4` | USB mass storage |
| `6` | NVMe (PCIe) |
| `f` | Restart from the beginning of the list |

`0xf164` = NVMe → USB → SD → (restart), so `4` (USB) is tried first.

Alternatively, hold **Space** at power-on for a one-time boot device selector
without changing the stored order.

### NVMe disk name

An NVMe SSD connected via the Pi 5's M.2 HAT+ appears as:

```
/dev/nvme0n1          whole disk
/dev/nvme0n1p1        partition 1
/dev/nvme0n1p2        partition 2
...
```

Pass `--disk nvme0n1` (without `/dev/`) to `build-iso.sh`.
Other common Pi 5 device names:

| Device | Description |
|--------|-------------|
| `nvme0n1` | NVMe SSD via M.2 HAT+ (PCIe) |
| `mmcblk0` | Built-in SD card slot |
| `sda` | USB storage device |

---

## Build options

### `--arch arm64`

Selects the ARM64 Clonezilla ISO and switches the ISO repack to UEFI-only mode.

```bash
./build-iso.sh --arch arm64 [other options]
```

### `--usb-repo-detect`

Injects a detection script (`/scripts/cz-usb-repo.sh`) into the ISO.  At boot,
an `ocs_prerun` command calls this script via live-boot's boot-medium mount point
(`/lib/live/mount/medium/`).  The script:

1. Iterates `/sys/block/sd*/removable` looking for a removable block device.
2. Optionally filters by volume label (`--usb-repo-label`).
3. Mounts the first matching partition at `/home/partimag` (Clonezilla's image
   directory) and writes `ocsroot_src=skip` / `ocs_live_type=device-image` into
   `/etc/ocs/ocs-live.conf` to suppress the storage-type and mode-selection
   dialogs — the same flags used by the NFS path.

This is the recommended repository method for Pi 5 deployments that have no NFS
server available.

### `--usb-repo-label LABEL`

Restricts USB detection to a partition whose volume label matches `LABEL`
(checked via `blkid`).  Without this flag the first removable device found is
used.

Recommended label: `CZ_IMAGES` (FAT32 or ext4).

---

## Step-by-step: restore NVMe from a USB image drive

### Step 1 — Prepare the image drive

Format a USB drive with one partition and set its label:

```bash
# FAT32 (works for images up to 4 GB per file; use ext4 for larger)
sudo mkfs.vfat -F 32 -n CZ_IMAGES /dev/sdX1

# ext4 (no 4 GB file-size limit)
sudo mkfs.ext4 -L CZ_IMAGES /dev/sdX1
```

Mount it and copy your Clonezilla image folder(s) onto it:

```bash
sudo mount /dev/sdX1 /mnt/usb
sudo cp -r /path/to/your/clonezilla-image /mnt/usb/
sudo umount /mnt/usb
```

The partition must contain Clonezilla image directories at its root — the same
layout you would put on an NFS share.

### Step 2 — Build the ISO

```bash
./build-iso.sh \
  --arch arm64 \
  --mode restore \
  --disk nvme0n1 \
  --image pi5-backup \
  --usb-repo-detect \
  --usb-repo-label CZ_IMAGES \
  --post-action reboot
```

Or via a config file (`config/pi5-restore.conf`):

```bash
CLONEZILLA_ARCH="arm64"
USB_REPO_DETECT="true"
USB_REPO_LABEL="CZ_IMAGES"
CZ_MODE="restore"
CZ_DISK="nvme0n1"
CZ_IMAGE_NAME="pi5-backup"
CZ_POST_ACTION="reboot"
```

```bash
./build-iso.sh --config config/pi5-restore.conf
```

### Step 3 — Write the ISO to a second USB drive

```bash
sudo ./burn-usb.sh build/custom-clonezilla.iso /dev/sdY
```

You now have two USB drives:

| Drive | Contents |
|-------|----------|
| Boot USB | Custom Clonezilla ISO (arm64, UEFI) |
| Image USB | Partition labeled `CZ_IMAGES` with the image folder |

### Step 4 — Boot and restore

1. Plug both USB drives into the Pi 5.
2. Power on.  The UEFI firmware loads GRUB from the boot USB.
3. GRUB displays the custom menu entry and auto-boots after the timeout.
4. The `ocs_prerun` detection script scans for the `CZ_IMAGES` USB, mounts it
   at `/home/partimag`, and suppresses the storage/mode dialogs.
5. Clonezilla restores `pi5-backup` onto `nvme0n1` and reboots.

No keyboard interaction required.

---

## Combining NFS and USB detection

When both `NFS_SERVER`/`NFS_SHARE` and `USB_REPO_DETECT` are configured, the
`ocs_prerun` commands run in this order:

| Prerun | Action |
|--------|--------|
| 1 | `sleep NFS_WAIT_SEC` — let DHCP settle |
| 2 | Mount NFS share at `/home/partimag` |
| 3 | Write `ocsroot_src=skip` |
| 4 | Write `ocs_live_type=device-image` |
| 5 | Run USB detection script |

NFS takes precedence.  If NFS mounts successfully, USB detection exits silently
(the mount will fail since `/home/partimag` is already in use, and the script
exits with code 1 without overwriting the NFS conf entries).

To use USB detection as a standalone fallback with no NFS:
omit `--nfs-server` / `--nfs-share` entirely.

---

## Disk imaging — backup vs. restore

### Backup NVMe to USB image drive

```bash
./build-iso.sh \
  --arch arm64 \
  --mode backup \
  --disk nvme0n1 \
  --image pi5-backup \
  --compress z1p \
  --usb-repo-detect \
  --usb-repo-label CZ_IMAGES \
  --post-action poweroff
```

The image is written into a new subdirectory on the `CZ_IMAGES` USB partition.

### Interactive mode

```bash
./build-iso.sh \
  --arch arm64 \
  --language en_US.UTF-8 \
  --keyboard us
```

Boots the standard Clonezilla menu with your locale pre-selected.  All storage
and operation choices are made at the keyboard after boot — useful for
exploratory use or one-off jobs.

---

## Troubleshooting

### Pi 5 does not boot from USB

- Confirm UEFI firmware is installed and the Pi POSTs to the UEFI shell or GRUB.
- Check `BOOT_ORDER` with `sudo rpi-eeprom-config` — it must include `4` (USB)
  before `6` (NVMe).  `0xf164` is the recommended value.
- Ensure the boot USB was written with `burn-usb.sh` (uses `dd` for a raw block
  copy, which preserves the El Torito EFI boot record).

### GRUB loads but shows the original Clonezilla menu

`mtools` is needed to patch `grub.cfg` inside `efi.img`.  Without it the custom
entry may not appear on some UEFI firmware:

```bash
sudo apt-get install mtools
./build-iso.sh --arch arm64 [your options]   # rebuild
sudo ./burn-usb.sh build/custom-clonezilla.iso /dev/sdX
```

### USB detection script finds no device

- Run interactively first (`--mode interactive`, no `--usb-repo-detect`) and
  check whether `lsblk` shows the image USB as a removable device (`rm=1`).
- Verify the partition label: `sudo blkid /dev/sdX1 | grep LABEL`.
- If the Pi's boot USB appears as `sda`, the image USB may be `sdb`.  The
  detection script iterates all `sd*` devices and skips non-removable ones, so
  both should work as long as the image USB is marked removable in sysfs.

### NVMe not detected by Clonezilla

The Pi 5 M.2 HAT+ (Pimoroni, Waveshare, official Pi HAT+, etc.) attaches NVMe
via PCIe and the kernel names it `nvme0n1`.  If the device does not appear:

- Confirm the HAT+ is firmly seated and the NVMe SSD is compatible
  (M.2 2230 or 2242 recommended).
- The Clonezilla ARM64 ISO ships a recent Debian kernel that includes
  `nvme_core`.  No extra driver steps are needed.
- Check `dmesg | grep nvme` in an interactive boot to confirm the drive is
  enumerated.

---

## Compatibility notes

ARM64 builds are published on the NCHC experimental mirror and track the same
Clonezilla codebase as the `amd64` stable releases.  The same internal hooks
used by the NFS automation path apply:

- `ocsroot_src=skip` in `/etc/ocs/ocs-live.conf`
- `ocs_live_type=device-image` in `/etc/ocs/ocs-live.conf`
- `ocs_prerun*` numbered parameters processed by `sort -V` in `ocs-run-boot-param`

Run `check-clonezilla-compat.sh` before bumping `CLONEZILLA_ARM64_VERSION` —
the same checks that guard `amd64` upgrades apply equally to `arm64`.

### Tested versions

| Clonezilla arm64 | Status |
|-----------------|--------|
| `3.3.2-21` | Reference version; initial arm64 support added |

Add rows here as new versions are validated.
