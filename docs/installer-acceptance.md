# Frostbite Installer MVP Acceptance Gates

The first Frostbite installer is intentionally narrow. It installs the same
offline system carried by the live image and supports one destructive layout:
erase one selected disk, create GPT, create a 512 MiB FAT32 EFI system
partition, and use the remainder as one ext4 root filesystem.

## Supported scope

- UEFI x86_64 only. The installer must refuse to run when `/sys/firmware/efi`
  is absent.
- GRUB has a dedicated `frostbite.install=1` entry which forces Sway and opens
  Calamares, so installer reachability does not depend on GPU capability. That
  offline entry masks live hardware tuning and network-online waiting, retains
  both graphical and serial boot consoles, and uses a live-only Sway
  configuration which forces wlroots' CPU-backed pixman renderer and records
  tagged Sway debug output. It has no window-kill, reload, or compositor-exit
  shortcut, preventing an accidental key chord from aborting the destructive
  phase. The ordinary Steam desktop retains hardware rendering.
- The privileged Calamares process receives Xwayland access only through a
  temporary `si:localuser:root` entry. The launcher revokes that entry when
  Calamares exits, and the target removes the live-only `xorg-xhost` package.
- Whole-disk erase only. Alongside, replace-partition, manual partitioning,
  LVM, encryption, swap partitions, swap files, and non-ext4 roots are not
  offered by this release.
- No partitioning option is selected initially. The user must select the disk
  and choose erase explicitly, then confirm the final Calamares summary.
- Installation is fully offline. The target is unpacked from
  `/run/archiso/bootmnt/frostbite/x86_64/airootfs.sfs`; no package download or
  system upgrade is allowed during installation.
- The minimum target is 12 GiB. Frostbite's pre-installer baseline is
  3,590,175,347 uncompressed bytes (3.34 GiB), measured from the known-good
  1,700,769,792-byte SquashFS. The 12 GiB gate leaves meaningful room for the
  Steam client and small games on the 14.7 GB test eMMC.

## Reproducibility and footprint

- Calamares is built from the checksum-pinned upstream v3.4.2 release tarball.
  The committed source checksum is
  `733bbbb00dc9f84874bd5c22960952f317ea2537565431179fa2152b2fbfdccc`.
- The package is built in the same Arch package snapshot as the ISO. A binary
  package must never be reused across Python, Qt, or KPMCore snapshots.
- Frostbite installs its own configuration in `/etc/calamares`; upstream
  example configuration is not installed.
- Only modules present in `calamares/settings.conf` are built. Qt Widgets is
  enabled, QML is disabled, Python jobs are required, tests and crash-reporting
  code are excluded from the live package.
- Only `calamares-frostbite` and `squashfs-tools` are explicit live-installer
  packages. Pacman resolves their dependencies so `pacman -Rns` can remove the
  unused dependency closure from the target safely.
- The baseline ISO is 1,998,891,008 bytes. CI records the final ISO byte delta,
  custom package size, installed dependency size, `.BUILDINFO`, and SHA-256.

## Installed-system security

Installation fails unless every condition below is true in the target:

- The live `frostbite` account, group, home, mail, subuid/subgid entries, and
  account-database backup entries are absent.
- `/etc/sudoers.d/10-frostbite-live` and every live-only polkit rule are absent.
- No active sudo rule contains `NOPASSWD`.
- Root is locked. The user created in Calamares is in `wheel`, has the chosen
  password, and can use password-authenticated sudo.
- TTY1 autologin names the created user; it never falls back to the live user.
- `calamares-frostbite`, `squashfs-tools`, and `mkinitcpio-archiso` are absent.
- `/etc/calamares`, live Archiso initramfs configuration, and every Archiso
  mount/cowspace reference are absent.
- A normal `linux-zen` initramfs is generated after live artifacts are removed;
  it contains no Archiso hooks.

## Boot and runtime proof

The release gate is a q35/OVMF disposable UEFI VM with 4 GiB RAM, two CPUs,
one 16 GiB sparse qcow2, and no network, host directory, or host block-device
passthrough. KVM is used when the runner exposes it; otherwise the same gate
runs with TCG:

1. Boot the Frostbite ISO read-only and select its dedicated second GRUB entry.
   QMP input and OCR from QEMU screendumps must identify each central Calamares
   page. Every state is OCR'd in normal and inverted contrast for light and
   dark screens; no blind coordinate or time-based destructive click is
   accepted.
2. Select **Erase disk** and create the disposable `frosttest` user. The Summary
   page must visibly prove `/dev/vda`, erase, GPT, the roughly 512 MiB EFI
   partition, and ext4 root before the driver may send Calamares' Install
   mnemonic. The real Calamares 3.4.2 success text, `All done.` and
   `has been installed`, is required; failure text always aborts the gate.
3. Power off, detach the Frostbite ISO, copy a fresh OVMF variable template, and
   boot only the virtual disk. Reaching installed GRUB without a saved firmware
   entry proves `EFI/BOOT/BOOTX64.EFI`; TTY2 then waits for the first-boot marker
   before requesting a clean ACPI poweroff.
4. Create a tiny nonbootable ISO containing only the audit script. On a second
   installed-system boot, attach that ISO read-only after the target disk, log
   in on TTY2, authenticate sudo, mount the CD read-only, and run the audit.
   The host accepts exactly one `FROSTBITE_VM_AUDIT_PASS` serial line and zero
   `FROSTBITE_VM_AUDIT_FAIL` lines.
5. The in-guest audit hard-checks the GPT/ESP/ext4 layout, UUID fstab, fallback
   EFI loader, normal kernel/initramfs, live-account and installer removal,
   locked root and password sudo, expected enabled services, completed
   firstboot state, an empty failed-unit list, and a running Sway or gamescope
   session.
6. Preserve screenshots, OCR text, serial/QEMU logs, journal diagnostics,
   package inventory, and checksums on success or failure. The validated mktemp
   directory holding qcow2, OVMF variables, audit ISO, and disposable password
   state is always deleted and is never included in an artifact upload.

No physical disk is an acceptable installer test target until this disposable
VM gate passes.
