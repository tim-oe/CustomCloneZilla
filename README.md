# CustomCloneZilla

Customize a [Clonezilla Live](https://clonezilla.org) ISO with:

- **Language / locale** — set the system locale for the live session
- **Keyboard layout** — configure keyboard layout and optional variant
- **Timezone** — set the local timezone
- **NFS share** — pre-configure an NFS mount for automated backup or restore

The output is a standard hybrid ISO (UEFI + legacy BIOS) ready to write
directly to a USB drive.

---

## Requirements

| Tool | Purpose | Install |
|------|---------|---------|
| `xorriso` | Extract and repack the ISO | `sudo apt-get install xorriso` |
| `wget` | Download the Clonezilla ISO | `sudo apt-get install wget` |
| `mtools` | Patch `efi.img` for UEFI firmware (optional) | `sudo apt-get install mtools` |

`mtools` is only needed to update the GRUB config inside the EFI partition image.
Without it, UEFI boot still works on most hardware; some Lenovo firmware
(e.g. T590) loads GRUB directly from the EFI partition and will show the original
unmodified menu if `mtools` is absent.

Or install both at once:

```bash
make deps
# equivalent to: sudo apt-get install xorriso wget mtools
```

---

## Quick Start

### 1 — Clone and enter the repo

```bash
git clone git@github.com:tim-oe/CustomCloneZilla.git
cd CustomCloneZilla
```

### 2 — Edit the config file

```bash
cp config/settings.conf config/mysite.conf
$EDITOR config/mysite.conf
```

Key settings to review:

```bash
LANGUAGE="en_US.UTF-8"
KEYBOARD_LAYOUT="us"
TIMEZONE="America/New_York"

NFS_SERVER="192.168.1.100"
NFS_SHARE="/mnt/clonezilla"

CZ_MODE="restore"       # backup | restore | interactive
CZ_DISK="sda"
CZ_IMAGE_NAME="ubuntu-24.04"
CZ_POST_ACTION="reboot"
```

### 3 — Build the ISO

```bash
./build-iso.sh --config config/mysite.conf
# or
make restore CONFIG=config/mysite.conf
```

### 4 — Write to USB

```bash
sudo ./burn-usb.sh /dev/sdX
# or with a specific ISO:
sudo ./burn-usb.sh --iso build/custom-clonezilla.iso /dev/sdX
```

`burn-usb.sh` will verify the ISO checksum, prompt for confirmation, write the
image with `dd`, then mount the USB and print the embedded `build-info.txt` so
you can confirm exactly which build landed on the device.

---

## Usage

```
./build-iso.sh [OPTIONS]
```

### Locale options

| Flag | Description | Default |
|------|-------------|---------|
| `-l, --language LOCALE` | System locale | `en_US.UTF-8` |
| `-k, --keyboard LAYOUT` | Keyboard layout code | `us` |
| `--keyboard-variant VAR` | Keyboard variant | *(none)* — **untested** |
| `-z, --timezone TZ` | Timezone | `America/Chicago` |

### Network options

| Flag | Description | Default |
|------|-------------|---------|
| `--dhcp` | Enable DHCP on boot | *(enabled by default)* |
| `--no-dhcp` | Disable DHCP injection | — |
| `--network-interface IF` | DHCP on a specific interface (e.g. `eth0`) | all interfaces — **untested** |

### NFS options

| Flag | Description | Default |
|------|-------------|---------|
| `-s, --nfs-server IP` | NFS server IP or hostname | *(required for backup/restore)* |
| `-n, --nfs-share PATH` | Exported path on the NFS server | *(required for backup/restore)* |
| `--nfs-opts OPTS` | Extra mount options (appended to `nfsvers=N`) | `defaults` — **untested** |
| `--nfs-version VER` | NFS protocol version: `3` or `4` | `4` |
| `--nfs-wait SEC` | Seconds to wait for DHCP before mounting | `15` |

### Operation options

| Flag | Description | Default |
|------|-------------|---------|
| `-m, --mode MODE` | `backup` \| `restore` \| `interactive` | `interactive` |
| `-d, --disk DISK` | Target block device (without `/dev/`) | `sda` |
| `-i, --image NAME` | Image name on NFS share | `clonezilla-img` |
| `--compress TYPE` | Compression: `z0` `z1p` `z2p` `z3p` `z4p` `z5p` | `z1p` |
| `--post-action ACTION` | `reboot` \| `poweroff` \| `choose` | `reboot` |
| `--extra-args ARGS` | Extra flags appended to `ocs-sr` | *(none)* — **untested** |

### ISO options

| Flag | Description | Default |
|------|-------------|---------|
| `--iso FILE` | Use a local ISO instead of downloading | *(download)* |
| `--czversion VER` | Clonezilla version to download | `3.3.1-35` |
| `-o, --output FILE` | Output ISO path | `./custom-clonezilla.iso` |

> **Note:** Only `amd64` is available for Clonezilla 3.x — i686 support was dropped at version 3.2.0-8.

### Script options

| Flag | Description |
|------|-------------|
| `-c, --config FILE` | Load settings from a config file |
| `--dry-run` | Show what would be done without making changes |
| `--keep-work-dir` | Keep the working directory for debugging |
| `-v, --verbose` | Enable debug output |
| `-h, --help` | Show help |

---

## Examples

### Locale and keyboard only (interactive menu)

```bash
./build-iso.sh \
  --language fr_FR.UTF-8 \
  --keyboard fr \
  --timezone Europe/Paris
```

The resulting ISO boots to the standard Clonezilla menu with French locale
and keyboard pre-selected.

### Automated NFS restore

Restores the image `ubuntu-24.04` from an NFS share to `/dev/sda`, then
reboots automatically — no user interaction required.

```bash
./build-iso.sh \
  --language en_US.UTF-8 --keyboard us \
  --nfs-server 192.168.1.100 --nfs-share /mnt/backups \
  --mode restore \
  --disk sda \
  --image ubuntu-24.04 \
  --post-action reboot
```

### Automated NFS backup

Saves a compressed image of `/dev/sda` to the NFS share as `server01`, then
powers off.

```bash
./build-iso.sh \
  --nfs-server 192.168.1.100 --nfs-share /mnt/backups \
  --mode backup \
  --disk sda \
  --image server01 \
  --compress z1p \
  --post-action poweroff
```

### Use a pre-downloaded ISO

```bash
./build-iso.sh \
  --iso ~/Downloads/clonezilla-live-3.3.1-35-amd64.iso \
  --config config/settings.conf
```

---

## Makefile targets

```
make deps         Install required system packages
make check        Validate config (dry-run, verbose)
make backup       Build backup ISO using config/settings.conf
make restore      Build restore ISO using config/settings.conf
make interactive  Build interactive ISO using config/settings.conf
make clean        Remove generated ISO files
make distclean    Remove generated ISOs and downloaded Clonezilla ISOs
```

Override settings from the make command line:

```bash
make restore \
  NFS_SERVER=10.0.0.5 \
  NFS_SHARE=/backups \
  DISK=nvme0n1 \
  IMAGE=my-image \
  CONFIG=config/mysite.conf
```

---

## Upgrading the Clonezilla version

`build-iso.sh` relies on a small number of internal Clonezilla mechanisms
(kernel parameter names, config variable names, and dialog guard logic) that
could change between upstream releases.  Before bumping `--czversion`, run the
compatibility check script against the clonezilla source repo.

### Setup (one-time)

Clone the official Clonezilla repo as a sibling of this project:

```bash
git clone https://github.com/stevenshiau/clonezilla ../clonezilla
```

### Run the check

```bash
# Check current repo state
./check-clonezilla-compat.sh

# Pull latest upstream commits, then check
./check-clonezilla-compat.sh --update

# Machine-readable output (useful for automated pipelines or AI agents)
./check-clonezilla-compat.sh --json
```

A clean run looks like:

```
>>> ocs_prerun* kernel parameter (boot → shell command bridge)
  [PASS] ocs-run-boot-param references ocs_prerun
  [PASS] ocs-run-boot-param uses parse_cmdline_option to read kernel params
...
------------------------------------------------------------------------
  Results:  14 passed  0 failed  0 warnings
------------------------------------------------------------------------
All checks passed — safe to upgrade CLONEZILLA_VERSION.
```

### What it checks

| Check | What it verifies |
|-------|-----------------|
| `ocs_prerun*` bridge | `ocs-run-boot-param` still parses numbered `ocs_prerun*` kernel params |
| `ocs-live.conf` sourcing | `ocs-prep-repo` and `clonezilla` both source the conf file before any dialog |
| `ocsroot_src=skip` | `ocs-prep-repo` still skips the storage-type dialog when `ocsroot_src` is pre-set |
| `ocs_live_type=device-image` | `clonezilla` still skips the mode dialog when `ocs_live_type` is pre-set |
| `/home/partimag` mount target | `ocs-prep-repo` still references `/home/partimag` as the image directory |
| Numeric suffix ordering | `ocs-run-boot-param` uses `sort -V` so `ocs_prerun1..4` run in order |
| Boot entry point | `ocs-live-run-menu` still calls `ocs-run-boot-param ocs_prerun` on every boot |

### When a check fails

Each failure prints:

- **Expected pattern** — the regex that was previously matched
- **Current file content** — what that section of the Clonezilla script looks like *now*
- **Fix target** — the exact function in `build-iso.sh` to update

Example failure output:

```
  [FAIL] ocs-prep-repo handles ocsroot_src=skip
         Expected pattern : ocsroot_src.*skip|skip.*ocsroot_src
         In file          : sbin/ocs-prep-repo
         Current file content (grep 'ocsroot_src', up to 10 lines):
             1187:  if [ -z "$ocsroot_source" ]; then   # <-- variable renamed
         Fix target in build-iso.sh → build_boot_params(): ocs_prerun3='echo ocsroot_src=skip ...'
```

Update `build_boot_params()` in `build-iso.sh` to match the new variable name or
option value shown in the current content, then re-run until all checks pass.

---

## How it works

1. **Download** — fetches the official Clonezilla Live ISO from SourceForge
   (or uses a local copy via `--iso`).
2. **Extract** — uses `xorriso` to unpack the ISO filesystem to a temp directory.
3. **Modify boot configs** — injects kernel parameters into both:
   - `boot/grub/grub.cfg` (UEFI / GRUB2)
   - `isolinux/isolinux.cfg` (legacy BIOS / isolinux)

   A new menu entry is prepended and set as the default (30-second timeout).
   The original entries are preserved below it.
4. **Repack** — rebuilds a bootable hybrid ISO using the original El Torito
   boot record and extracted MBR for USB compatibility.

### Key kernel parameters injected

| Parameter | Purpose |
|-----------|---------|
| `locales=` | Sets the live system locale |
| `keyboard-layouts=` | Sets the keyboard layout |
| `ocs_lang=` | Clonezilla language |
| `ip=dhcp` | DHCP on all interfaces (`--dhcp`, on by default) |
| `ip=IF:dhcp` | DHCP on a specific interface (`--network-interface IF`) |
| `net.ifnames=0` | Use traditional interface names (`eth0` etc.) |
| `ocs_prerun1=` | Waits for DHCP lease before mounting |
| `ocs_prerun2=` | Mounts the NFS share before Clonezilla starts |
| `ocs_prerun3=` | Sets `ocsroot_src=skip` — bypasses storage-type dialog |
| `ocs_prerun4=` | Sets `ocs_live_type=device-image` — bypasses mode dialog |
| `ocs_live_run=` | The `ocs-sr` command to execute |
| `ocs_live_batch=` | Enables non-interactive / batch mode |

### NFS mount point

Clonezilla stores images in `/home/partimag`.  The script mounts the NFS share
there before Clonezilla starts, making all images on the share immediately
available.

---

## Compression options

| Code | Algorithm | Speed | Size |
|------|-----------|-------|------|
| `z0` | none | fastest | largest |
| `z1p` | gzip | fast | moderate |
| `z2p` | bzip2 | moderate | smaller |
| `z3p` | lzop | very fast | moderate |
| `z4p` | lzma | slow | small |
| `z5p` | xz | slowest | smallest |

---

## Project structure

```
CustomCloneZilla/
├── build-iso.sh                  # Main build script
├── burn-usb.sh                   # Write ISO to USB and verify
├── check-clonezilla-compat.sh    # Verify Clonezilla internals before upgrading
├── config/
│   └── settings.conf             # All configurable settings (copy and edit)
├── Makefile                      # Convenience targets
├── LICENSE
└── README.md
```

---

## TODO / Untested flags

The following flags exist in the script but have not been exercised on real
hardware.  They are syntactically correct and the underlying mechanisms are
documented, but they need a test build + boot cycle before being considered
reliable.

| Flag | What to test |
|------|-------------|
| `--keyboard-variant VAR` | Build with a variant (e.g. `--keyboard de --keyboard-variant nodeadkeys`), boot, confirm correct key mapping |
| `--network-interface IF` | Build with `--network-interface eth0`, boot on a machine with a named interface, confirm DHCP lease on that interface only |
| `--nfs-opts OPTS` | Build with non-default mount options (e.g. `--nfs-opts ro,timeo=30`), confirm NFS mounts with the extra options |
| `--extra-args ARGS` | Build with an extra `ocs-sr` flag (e.g. `--extra-args "-nogui"`), confirm it is appended correctly to the clonezilla command |
| `--post-action poweroff` | Build a restore ISO with `--post-action poweroff`, complete a restore, confirm machine powers off instead of rebooting |
| `--post-action choose` | Same as above with `choose`, confirm the end-of-job selection dialog appears |
| `--compress` (non-default) | Build a backup ISO with `--compress z2p`, run a backup, confirm bzip2-compressed image is produced |
| `--no-dhcp` | Build without DHCP injection, boot, confirm network is left to the live system default |

Once a flag is verified, remove it from this table and drop the `[untested]`
marker from its entry in the option tables above.

---

## License

Apache License 2.0 — see [LICENSE](LICENSE).
