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

Install-time NVIDIA fetching is intentionally left as a Calamares hook extension rather than being forced in the base hook, because driver installation policies differ between offline and online installers.

## Theme Strategy

GTK, Qt/Kvantum, Plymouth, and icons live in `themes/` as plain assets. `scripts/sync-assets.sh` copies them into the ISO root. The PKGBUILD templates in `packaging/` are a starting point for publishing them as real pacman packages.

## Reproducibility Notes

Arch rolling packages are inherently time-sensitive. For stronger reproducibility, pin:

- an Arch container digest for CI,
- a dated Arch Linux Archive mirror,
- package versions for the kernel, Mesa, Steam, and gamescope,
- and the generated `packages.x86_64` artifact.
