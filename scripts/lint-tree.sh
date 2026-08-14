#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

required=(
  "$repo_root/README.md"
  "$repo_root/archiso/profiledef.sh"
  "$repo_root/archiso/pacman.conf"
  "$repo_root/archiso/packages.x86_64"
  "$repo_root/archiso/grub/grub.cfg"
  "$repo_root/archiso/airootfs/etc/skel/.config/sway/config"
  "$repo_root/archiso/airootfs/usr/local/bin/frostbite-firstboot"
  "$repo_root/archiso/airootfs/usr/local/bin/frostbite-hardware-detect"
  "$repo_root/archiso/airootfs/usr/local/bin/frostbite-performance"
  "$repo_root/archiso/airootfs/usr/local/bin/frostbite-session"
  "$repo_root/archiso/airootfs/usr/local/bin/frostbite-steam-launch"
  "$repo_root/calamares/settings.conf"
  "$repo_root/themes/gtk/Frostbite/gtk-3.0/gtk.css"
  "$repo_root/themes/kvantum/Frostbite/Frostbite.kvconfig"
  "$repo_root/themes/plymouth/frostbite/frostbite.plymouth"
)

for path in "${required[@]}"; do
  if [[ ! -e "$path" ]]; then
    echo "missing: $path" >&2
    exit 1
  fi
done

grub_cfg="$repo_root/archiso/grub/grub.cfg"
mapfile -t live_boot_entries < <(
  grep -E '^[[:space:]]+linux /frostbite/boot/x86_64/vmlinuz-linux-zen ' "$grub_cfg"
)

if (( ${#live_boot_entries[@]} == 0 )); then
  echo "missing Frostbite live boot entry: $grub_cfg" >&2
  exit 1
fi

for entry in "${live_boot_entries[@]}"; do
  if [[ "$entry" != *" cow_spacesize=3072M"* ]]; then
    echo "live boot entry is missing cow_spacesize=3072M: $entry" >&2
    exit 1
  fi
done

sway_cfg="$repo_root/archiso/airootfs/etc/skel/.config/sway/config"
steam_launcher="$repo_root/archiso/airootfs/usr/local/bin/frostbite-steam-launch"
if ! grep -Fqx 'include /etc/sway/config.d/*' "$sway_cfg"; then
  echo "Sway config does not load the distribution session integration: $sway_cfg" >&2
  exit 1
fi

if ! grep -Fqx 'xwayland force' "$sway_cfg"; then
  echo "Sway config does not start Xwayland eagerly for Steam: $sway_cfg" >&2
  exit 1
fi

if ! grep -Fqx 'set $steam frostbite-steam-launch' "$sway_cfg" || \
   ! grep -Fqx 'bindsym $mod+d exec $steam' "$sway_cfg" || \
   ! grep -Fqx 'exec $steam' "$sway_cfg"
then
  echo "Sway config does not launch Steam through the environment-safe wrapper: $sway_cfg" >&2
  exit 1
fi

if ! grep -Eq '^[[:space:]]*if ! dbus-update-activation-environment --systemd' "$steam_launcher"; then
  echo "Steam launcher is missing the Xwayland activation environment update: $steam_launcher" >&2
  exit 1
fi

find "$repo_root" -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
find "$repo_root/archiso/airootfs/usr/local/bin" -type f -print0 | xargs -0 -n1 bash -n

echo "tree looks complete"
