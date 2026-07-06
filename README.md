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
- Storage: SSD/eMMC, 16 GB minimum install target, 32 GB preferred.
- Display: 720p target for gamescope by default; Potato Mode drops the session target to 960x540.

## Architecture Choices

- Base: Arch Linux via archiso for a small rolling image and current Mesa/kernel access.
- Kernel: `linux-zen` by default because it is available in official Arch repositories. A CachyOS kernel can be added in a branch by adding the keyring/repository to `archiso/pacman.conf` and replacing the kernel entries in `manifests/base.packages`.
- Session: gamescope launches Steam Big Picture. If gamescope or Steam is unavailable, the session falls back to Sway.
- Desktop mode: stripped Sway/wlroots, not KDE Plasma. LXQt can be added as an optional profile later, but Sway keeps the first image Wayland-first.
- Filesystem: ext4 by default through Calamares; btrfs is available but this project does not enable snapshots or rollback by default.
- Packaging: native pacman packages first. Flatpak remains optional and is not included in the base image.
- Swap pressure: zram with `lz4`, capped at 8 GB.
- Logs: journald capped at 50 MB.

## Build The ISO

Build on an Arch machine or an Arch container with enough privileges for `mkarchiso`.

```bash
sudo pacman -Syu --needed archiso git
cd /path/to/frostbite-os
sudo ./scripts/build-iso.sh
```

The ISO lands in `out/`. The temporary build root lands in `work/archiso`.

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

## Potato Mode

Enable Potato Mode by either creating `/etc/frostbite/potato-mode` or booting with:

```text
frostbite.potato=1
```

Potato Mode lowers the gamescope target to 960x540, keeps MangoHud off by default, and applies a conservative CPU profile.

## Installer

Calamares branding/configuration lives in `calamares/`. During ISO builds, `scripts/sync-assets.sh` copies these files into `archiso/airootfs/etc/calamares`.

The installer hook preserves the lightweight defaults in the target system by enabling the Frostbite first-boot service and masking common non-essential daemons such as Bluetooth, printing, Avahi, ModemManager, PackageKit, and systemd-coredump.

## Theme

The visual identity is intentionally flat:

- Background: `#0a0a0c`
- Text/icons: `#f2f2f2`
- Accent: `#5b2a86`
- No gradients, blur, shadows, or animations by default.

The theme sources are under `themes/` and are synced into the live image at build time.

## CI

The included GitHub Actions workflow builds inside an Arch container, installs `archiso`, runs the validation helper, and uploads the generated ISO artifact. For a production pipeline, pin the container digest and mirrorlist for stronger reproducibility.

## Validate The Tree

```bash
./scripts/lint-tree.sh
```

This checks required files and shell syntax. A full ISO build still requires a privileged Arch environment.

## Non-Goals

- No KDE Plasma.
- No Flatpak-first image.
- No btrfs snapshots or rpm-ostree-style rollback.
- No bundled office suite, creative suite, VPN client, or telemetry.
- No emulator cores bundled in the default image.
