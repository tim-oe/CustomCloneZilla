# Feature request: first-class kernel-cmdline hooks for unattended NFS / SMB / SSH repository setup

## Summary

Clonezilla Live already supports unattended save/restore via `ocs_live_run=` and
`ocs_live_batch=yes`, but the **storage-repository configuration** (NFS / SMB /
SSH server, share path, mount options, protocol version) still has no documented
boot-parameter interface.  Today the only way to fully automate it from the boot
prompt is to abuse `ocs_prerun*` to (a) `mount` the share by hand and
(b) `echo` internal variable names into `/etc/ocs/ocs-live.conf` to suppress the
storage-selection and clone-mode dialogs.

This works, but it depends on internal implementation details that aren't part
of any documented contract:

- `ocsroot_src=skip` in `/etc/ocs/ocs-live.conf` (read by `sbin/ocs-prep-repo`)
- `ocs_live_type=device-image` in `/etc/ocs/ocs-live.conf` (read by `sbin/clonezilla`)
- The exact mount target `/home/partimag`
- The fact that `ocs-prep-repo` re-checks `[ -z "$ocsroot_src" ]` before showing
  its menu

A small, documented set of `ocs_repository_*` boot parameters would let
downstream tooling (custom-ISO builders, PXE configs, kickstart-style network
deployments) configure the repository declaratively, without having to track
upstream variable renames or grep through `sbin/` for guard conditions.

---

## Current workaround (in production)

We maintain [CustomCloneZilla](https://github.com/tim-oe/CustomCloneZilla),
a tool that builds custom Clonezilla Live ISOs for unattended NFS-based
backup/restore.  The boot line we inject for an automated NFS-restore looks
like this (formatted for readability):

```
locales=en_US.UTF-8
keyboard-layouts=us
ocs_lang=en_US.UTF-8
net.ifnames=0
ip=dhcp

ocs_prerun1="sleep 15"
ocs_prerun2="mount -t nfs -o nfsvers=4 192.168.1.30:/exports/images /home/partimag"
ocs_prerun3="echo ocsroot_src=skip >> /etc/ocs/ocs-live.conf"
ocs_prerun4="echo ocs_live_type=device-image >> /etc/ocs/ocs-live.conf"

ocs_live_run="ocs-sr -g auto -e1 auto -e2 -r -j2 -p reboot restoredisk ubuntu-24.04 sda"
ocs_live_batch="yes"
```

Why each `ocs_prerun*` is needed:

| # | Command | Purpose |
|---|---------|---------|
| 1 | `sleep 15` | Wait for the `ip=dhcp` lease (acquired in the initrd stage) to settle before any network traffic |
| 2 | `mount -t nfs ...` | Mount the share at `/home/partimag`, which is Clonezilla's default `ocsroot` |
| 3 | `echo ocsroot_src=skip >> /etc/ocs/ocs-live.conf` | Pre-set the variable that `ocs-prep-repo` checks; this bypasses its storage-type selection dialog |
| 4 | `echo ocs_live_type=device-image >> /etc/ocs/ocs-live.conf` | Pre-set the variable that `clonezilla` checks; this bypasses the mode selection dialog |

Without `ocs_prerun3` and `ocs_prerun4`, the share mounts correctly but the user
is still prompted to choose the storage type and the clone mode, defeating the
point of an unattended boot.

---

## Why this is fragile

Each of the four prerun lines depends on something that isn't a public contract:

1. **`ocs_prerun*` numbering** — works only because `ocs-run-boot-param` happens
   to use `sort -V` to order matching parameters.
2. **`ocsroot_src=skip`** — relies on the literal `[ -z "$ocsroot_src" ]` guard
   in `sbin/ocs-prep-repo`.  A rename, refactor, or moving the guard into
   another helper would silently re-enable the dialog.
3. **`ocs_live_type=device-image`** — same story for `sbin/clonezilla`.
4. **`/home/partimag` as a mount path** — currently the ocsroot default, but
   defined in the DRBL package outside the clonezilla repo, so a downstream
   change there is invisible to anyone watching this repo.
5. **Sourcing order of `/etc/ocs/ocs-live.conf`** — both `sbin/ocs-prep-repo`
   and `sbin/clonezilla` happen to source it before showing any dialog; if
   either ever read user input first and the conf file second, our overrides
   would have no effect.

We've written a [compatibility checker](https://github.com/tim-oe/CustomCloneZilla/blob/main/check-clonezilla-compat.sh)
that grep-matches each of these assumptions in the upstream source before we
allow `CLONEZILLA_VERSION` to be bumped, but having to do this is a sign the
contract should be promoted to a real feature.

---

## Proposed solution: `ocs_repository_*` boot parameters

A small, declarative set of boot-time parameters that `ocs-live-run-menu` (or a
new helper invoked from there) would consume *before* showing any dialog.
When `ocs_repository_type` is set, the storage-selection and clone-mode dialogs
are skipped entirely.

### NFS

```
ocs_repository_type=nfs                # nfs | nfs4 | smb | ssh | dev | local_dev
ocs_repository_server=192.168.1.30
ocs_repository_path=/exports/images
ocs_repository_mount_opts=nfsvers=4    # passed to -o
ocs_repository_wait=15                 # max seconds to wait for network
```

### SMB / CIFS

```
ocs_repository_type=smb
ocs_repository_server=192.168.1.30
ocs_repository_path=/share/images
ocs_repository_user=clonezilla
ocs_repository_pass_file=/run/initramfs/cz-pass   # path inside initrd
ocs_repository_mount_opts=vers=3.0,sec=ntlmssp
```

(Passwords on the kernel command line are visible in `/proc/cmdline` to any
local user.  Allowing a path to a file inside the initrd — populated by a
side-channel like `fetch=` or a custom hook — is much safer.)

### SSH / SSHFS

```
ocs_repository_type=ssh
ocs_repository_server=backup.example.com
ocs_repository_port=22
ocs_repository_user=backup
ocs_repository_path=/srv/clonezilla/images
ocs_repository_key_file=/run/initramfs/cz-id_ed25519
```

### Local device

```
ocs_repository_type=dev
ocs_repository_dev=/dev/disk/by-label/CZ_IMAGES
```

### Common acceptance criteria

For all of the above:

1. `ocs-prep-repo` recognises that `ocs_repository_type` is set, mounts the
   share/device at `/home/partimag` (or whatever `ocsroot` is configured to),
   and **does not** show the storage-type dialog.
2. If `ocs_live_run=` is *also* set, the clone-mode dialog is also skipped
   (this part already works with the existing `ocs_live_type` mechanism, but
   should be documented as the official combination).
3. Failures (DNS, refused connection, bad credentials, mount error) print a
   clear message and either drop to a shell or retry, controlled by
   `ocs_repository_on_fail=shell|retry|reboot|poweroff`.

### Backwards compatibility

The new parameters are additive.  All existing kernel-command-line behaviour
(including `ocs_prerun*`, `ocs_live_run=`, `ocs_live_batch=`) continues to work
unchanged.  Sites that already use the workaround can migrate at their own
pace.

### Why kernel parameters (not a config file in the ISO)

Kernel parameters are the only configuration channel that:

- works identically for both ISO boot (BIOS + UEFI) and PXE/iPXE boot
- can be templated per-host by the boot loader / DHCP server without rebuilding
  the ISO
- is already the established pattern Clonezilla uses for `ocs_live_run`,
  `ocs_lang`, `keyboard-layouts`, etc.

---

## Why this would help

This is a personal-use tool for me — I run regular backups and restores at home
and got tired of clicking through the same storage-type and clone-mode dialogs
every single time.  The `ocs_prerun` recipe above works, but it took a deep
dive into Clonezilla internals to discover, and I have no confidence it will
survive the next point release without my compatibility checker catching it.

A blessed `ocs_repository_*` interface would benefit a much wider range of
use cases than just mine:

- **Home users / homelabs** — boot the USB, walk away, image is restored
- **Small-business deployments** — image a stack of identical machines without
  an operator at each one
- **Larger fleet management** — give projects like Foreman, MAAS, Cobbler, and
  custom PXE stacks a stable, declarative interface to target instead of each
  one inventing its own boot-line hack
- **CI / lab environments** — reset test machines from a known image as part
  of an automated pipeline

The common thread: anyone who wants Clonezilla to be **boot-and-forget** today
either (a) sits at the keyboard, (b) writes the workaround above, or (c) uses
a different tool.  A documented set of repository parameters would close that
gap without changing anything for users who prefer the existing menu-driven
flow.

---

## Reference

- Working implementation we'd like to deprecate:
  https://github.com/tim-oe/CustomCloneZilla/blob/main/build-iso.sh
  (see `build_boot_params()`)
- Compatibility check showing the internal hooks we depend on:
  https://github.com/tim-oe/CustomCloneZilla/blob/main/check-clonezilla-compat.sh
- Specific upstream lines we currently grep-match against:
  - `sbin/ocs-prep-repo` — `[ -z "$ocsroot_src" ]` guard, `"skip"` option
  - `sbin/clonezilla`     — `[ -z "$ocs_live_type" ]` guard, `"device-image"` mode
  - `sbin/ocs-run-boot-param` — `sort -V` ordering of numbered prerun params
  - `sbin/ocs-live-run-menu`  — `ocs-run-boot-param ocs_prerun` invocation
