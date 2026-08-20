# Frostbite OS

Frostbite OS is an Arch Linux archiso profile for an ultra-lightweight gaming distribution aimed at low-end hardware: dual-core and quad-core CPUs, 4-8 GB RAM, integrated or entry-level GPUs, budget SSDs, and eMMC storage.

The design goal is a Bazzite-like "boot to games and get out of the way" experience with less background weight. The default path is Steam Big Picture inside gamescope, a Wayland-only Sway fallback desktop, native packages instead of Flatpak-first packaging, zram instead of snapshot-heavy rollback, and a flat black/white/dark-purple visual theme.

## Current Deliverables

- `archiso/`: bootable ISO profile with `profiledef.sh`, `pacman.conf`, `packages.x86_64`, and live root filesystem overrides.
- `manifests/`: split package lists for base, gaming core, AMD/Intel drivers, NVIDIA drivers, installer, and optional emulation.
- `scripts/`: package composition, asset sync, ISO build, and tree validation helpers.
- `themes/`: GTK 3/4, Kvantum, Plymouth, and minimal outline icon theme sources.
- `calamares/`: Frostbite-branded installer settings, branding, and hardware tuning hook.
- `packaging/`: starter Arch PKGBUILD templates for installable theme/config packages.
- `.github/workflows/build-iso.yml`: CI-oriented ISO build job.

## Hardware Target

- CPU: 2-4 cores, low-power x86_64.
- RAM: 4 GB minimum, 8 GB preferred.
- GPU: AMD/Intel integrated graphics by default; NVIDIA installed only when building or installing that variant.
- Storage: SSD/eMMC, 12 GiB minimum install target, 16 GiB preferred.
- Display: 720p target for gamescope by default; Potato Mode drops the session target to 960x540.

## Architecture Choices

- Base: Arch Linux via archiso for a small rolling image and current Mesa/kernel access.
- Kernel: `linux-zen` by default because it is available in official Arch repositories. A CachyOS kernel can be added in a branch by adding the keyring/repository to `archiso/pacman.conf` and replacing the kernel entries in `manifests/base.packages`.
- Session: gamescope launches Steam Big Picture. If gamescope or Steam is unavailable, the session falls back to Sway.
- Desktop mode: stripped Sway/wlroots, not KDE Plasma. LXQt can be added as an optional profile later, but Sway keeps the first image Wayland-first.
- Filesystem: one ext4 root plus a 512 MiB EFI system partition. The first installer deliberately does not expose btrfs, manual partitioning, encryption, LVM, or swap.
- Packaging: native pacman packages first. Flatpak remains optional and is not included in the base image.
- Swap pressure: zram with `lz4`, capped at 8 GB.
- Logs: journald capped at 50 MB.

## Build The ISO

Build on an Arch machine or an Arch container with enough privileges for `mkarchiso`.

```bash
sudo pacman -Syu --needed \
  archiso base-devel cmake extra-cmake-modules git kcoreaddons kpmcore \
  libpwquality namcap ninja parted polkit polkit-qt6 python python-yaml qt6-base \
  qt6-svg qt6-tools squashfs-tools yaml-cpp
cd /path/to/frostbite-os
./scripts/build-calamares-package.sh
sudo ./scripts/build-iso.sh
```

The first command builds Frostbite's pinned, Qt Widgets-only Calamares package
as an unprivileged user. The ISO build then exposes that package through a
temporary local pacman repository so dependency reasons remain correct. The ISO
lands in `out/`; disposable package and Archiso build state stays under `work/`.

Optional variants:

```bash
sudo env INCLUDE_NVIDIA=1 ./scripts/build-iso.sh
sudo env INCLUDE_EMULATION=1 ./scripts/build-iso.sh
sudo env INCLUDE_NVIDIA=1 INCLUDE_EMULATION=1 ./scripts/build-iso.sh
```

## Package Manifests

The source manifests live in `manifests/`. `scripts/compose-packages.sh` combines them into `archiso/packages.x86_64`.

Default build:

- `base.packages`
- `gaming-core.packages`
- `drivers-amd-intel.packages`
- `installer.packages`

Optional build flags:

- `INCLUDE_NVIDIA=1` adds `drivers-nvidia.packages`.
- `INCLUDE_EMULATION=1` adds `optional-emulation.packages`.

## Runtime Tuning

The live system includes:

- `frostbite-hardware-detect`: writes RAM, CPU, GPU, zram, irqbalance, and Potato Mode facts to `/var/lib/frostbite/hardware.env`.
- `frostbite-firstboot`: applies zram sizing, enables trim/network basics, masks non-essential services, and sets the initial performance profile.
- `frostbite-performance`: toggles `balanced`, `performance`, `battery`, and `potato` CPU profiles.
- `frostbite-session`: starts Steam Big Picture through gamescope, then falls back to Sway if needed.
- `frostbite-steam-setup`: creates Steam compatibility directories and a launch-options reference using `gamemoderun %command%`.

The live image raises Archiso's RAM-backed writable-overlay limit from the
256 MiB default to 3072 MiB so Steam can unpack client and runtime updates. The
overlay grows on demand, but its contents remain ephemeral and still consume
RAM or swap when written. Use an installed system or a disk-backed Steam library
for games that need substantial storage.

## Potato Mode

Enable Potato Mode by either creating `/etc/frostbite/potato-mode` or booting with:

```text
frostbite.potato=1
```

Potato Mode lowers the gamescope target to 960x540, keeps MangoHud off by default, and applies a conservative CPU profile.

## Installer

Choose **Install Frostbite OS (erase one disk)** in the USB's GRUB menu. This
forces the Sway path even on hardware that would normally enter gamescope and
opens Calamares automatically. `Super+I` can retry the guarded launcher within
that dedicated installer desktop. The first release is intentionally narrow and
destructive: it supports UEFI x86_64 only, erases one explicitly selected disk,
writes GPT, creates a 512 MiB FAT32 ESP, and uses the remainder for one ext4
root. Nothing is selected by default, and the final summary must still be
confirmed. Installation is fully offline.

The installed user and password come from Calamares. Root is locked, sudo
requires that user's password, and TTY1 autologin is rewritten to the chosen
username. Installation fails if the known live account, passwordless sudo,
Archiso initramfs state, installer packages, or installer shortcuts survive in
the target. The full scope and release gates are in
[`docs/installer-acceptance.md`](docs/installer-acceptance.md).

Calamares configuration lives in `calamares/`; `scripts/sync-assets.sh` mirrors
it into the Archiso root. Frostbite builds upstream Calamares 3.4.2 with Qt
Widgets and only the required modules, avoiding Qt Quick/QML's roughly 120 MiB
installed dependency cost. After installation, the Calamares package and its
now-unused dependency closure are removed from the target.

## Theme

The visual identity is intentionally flat:

- Background: `#0a0a0c`
- Text/icons: `#f2f2f2`
- Accent: `#5b2a86`
- No gradients, blur, shadows, or animations by default.

The theme sources are under `themes/` and are synced into the live image at build time.

## CI

The included GitHub Actions workflow builds the pinned Calamares package and
ISO in one Arch package snapshot, validates the installer contract, records
package and ISO checksums/footprint, and uploads the generated artifacts. The
release gate also performs a disposable UEFI VM installation and target audit;
no physical disk is used for automated testing. For stronger reproducibility,
pin the container digest and an Arch Linux Archive snapshot.

## Validate The Tree

```bash
./scripts/lint-tree.sh
```

This checks required files, synchronized installer assets, pinned patch
checksum, shell/Python syntax, and the exact erase-only installer contract.
`python-yaml` is required so configuration validation cannot be skipped. A full
ISO build still requires a privileged Arch environment.

## Non-Goals

- No KDE Plasma.
- No Flatpak-first image.
- No btrfs snapshots or rpm-ostree-style rollback.
- No bundled office suite, creative suite, VPN client, or telemetry.
- No emulator cores bundled in the default image.
