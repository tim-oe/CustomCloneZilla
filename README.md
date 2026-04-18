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

| Tool | Install |
|------|---------|
| `xorriso` | `sudo apt-get install xorriso` |
| `wget` | `sudo apt-get install wget` |

Or install both at once:

```bash
make deps
# equivalent to: sudo apt-get install xorriso wget
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
./customize-clonezilla.sh --config config/mysite.conf
# or
make restore CONFIG=config/mysite.conf
```

### 4 — Write to USB

```bash
sudo dd if=custom-clonezilla.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

---

## Usage

```
./customize-clonezilla.sh [OPTIONS]
```

### Locale options

| Flag | Description | Default |
|------|-------------|---------|
| `-l, --language LOCALE` | System locale | `en_US.UTF-8` |
| `-k, --keyboard LAYOUT` | Keyboard layout code | `us` |
| `--keyboard-variant VAR` | Keyboard variant | *(none)* |
| `-z, --timezone TZ` | Timezone | `America/New_York` |

### Network options

| Flag | Description | Default |
|------|-------------|---------|
| `--dhcp` | Enable DHCP on boot | *(enabled by default)* |
| `--no-dhcp` | Disable DHCP injection | — |
| `--network-interface IF` | DHCP on a specific interface (e.g. `eth0`) | all interfaces |

### NFS options

| Flag | Description | Default |
|------|-------------|---------|
| `-s, --nfs-server IP` | NFS server IP or hostname | *(required for backup/restore)* |
| `-n, --nfs-share PATH` | Exported path on the NFS server | *(required for backup/restore)* |
| `--nfs-opts OPTS` | Mount options (`-o`) | `defaults` |
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
| `--extra-args ARGS` | Extra flags appended to `ocs-sr` | *(none)* |

### ISO options

| Flag | Description | Default |
|------|-------------|---------|
| `--iso FILE` | Use a local ISO instead of downloading | *(download)* |
| `--czversion VER` | Clonezilla version to download | `3.1.2-22` |
| `--czarch ARCH` | `amd64` \| `i686` | `amd64` |
| `--czflavor FLAVOR` | `debian-bookworm` \| `ubuntu-focal` | `debian-bookworm` |
| `-o, --output FILE` | Output ISO path | `./custom-clonezilla.iso` |

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
./customize-clonezilla.sh \
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
./customize-clonezilla.sh \
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
./customize-clonezilla.sh \
  --nfs-server 192.168.1.100 --nfs-share /mnt/backups \
  --mode backup \
  --disk sda \
  --image server01 \
  --compress z1p \
  --post-action poweroff
```

### Use a pre-downloaded ISO

```bash
./customize-clonezilla.sh \
  --iso ~/Downloads/clonezilla-live-3.1.2-22-amd64.iso \
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
| `ocs_prerun1=` | Mounts the NFS share before Clonezilla starts |
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
├── customize-clonezilla.sh   # Main script
├── config/
│   └── settings.conf         # All configurable settings (copy and edit)
├── Makefile                  # Convenience targets
├── LICENSE
└── README.md
```

---

## License

Apache License 2.0 — see [LICENSE](LICENSE).
