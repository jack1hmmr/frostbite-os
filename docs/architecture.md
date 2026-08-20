# Frostbite OS Architecture

## Boot And Session Flow

1. `systemd` boots the live image.
2. `frostbite-firstboot.service` runs once, detects hardware, configures zram, masks non-essential daemons, and applies the balanced performance profile.
3. TTY1 autologs into the `frostbite` live user.
4. The user starts the `Frostbite Gamescope` session, or the session script is reused by a display manager after install.
5. `frostbite-session` launches Steam Big Picture through gamescope.
6. If Steam or gamescope is missing, Sway starts as the recovery desktop.

## Performance Priorities

Storage pressure is handled first because low-end systems often stall on swap and slow flash. Frostbite uses zram with `lz4`, weekly trim, and capped journals. CPU tuning is intentionally simple and handled through sysfs governors to avoid a heavy resident daemon. GPU tuning is mostly package selection: the default image carries Mesa for AMD/Intel and keeps NVIDIA separate.

## Driver Strategy

The default ISO includes AMD/Intel Mesa packages. NVIDIA is isolated in `manifests/drivers-nvidia.packages` so builders can decide between a small open-driver image and a vendor-specific image.

The MVP installer performs no network fetches. NVIDIA remains a separate ISO
build variant so the installed system always comes from the exact offline image
the user booted.

## Installer Strategy

The live image carries one small custom Calamares package built from the pinned
3.4.2 release. It uses Qt Widgets only and builds just the modules named by the
committed sequence. A build-local pacman repository keeps installer
dependencies marked as dependencies; the target finalizer can therefore remove
Calamares, SquashFS tooling, and their newly orphaned closure with `pacman
-Rns`.

Partitioning is UEFI/GPT only: a 512 MiB FAT32 ESP at `/boot/efi`, with the
remainder as ext4 root. A source patch hides Calamares' alongside and replace
paths, while configuration disables manual partitioning, encryption, LVM, and
swap. The installer unpacks the live SquashFS and never upgrades or downloads
target packages.

Target cleanup is split around user creation. The first fail-hard chroot stage
locks root and removes the known live account and credential backups. Calamares
then creates the real user. The second fail-hard stage restores the normal
kernel preset and microcode, removes live-only packages and shortcuts, writes
the exact chosen-user autologin, and asserts every security and boot invariant
before GRUB is installed.

## Theme Strategy

GTK, Qt/Kvantum, Plymouth, and icons live in `themes/` as plain assets. `scripts/sync-assets.sh` copies them into the ISO root. The PKGBUILD templates in `packaging/` are a starting point for publishing them as real pacman packages.

## Reproducibility Notes

Arch rolling packages are inherently time-sensitive. For stronger reproducibility, pin:

- an Arch container digest for CI,
- a dated Arch Linux Archive mirror,
- package versions for the kernel, Mesa, Steam, and gamescope,
- and the generated `packages.x86_64` artifact.
