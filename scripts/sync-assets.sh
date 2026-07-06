#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
airootfs="$repo_root/archiso/airootfs"

copy_dir() {
  local src="$1"
  local dst="$2"
  rm -rf "$dst"
  mkdir -p "$(dirname -- "$dst")"
  cp -a "$src" "$dst"
}

copy_dir "$repo_root/themes/gtk/Frostbite" "$airootfs/usr/share/themes/Frostbite"
copy_dir "$repo_root/themes/icons/Frostbite" "$airootfs/usr/share/icons/Frostbite"
copy_dir "$repo_root/themes/kvantum/Frostbite" "$airootfs/usr/share/Kvantum/Frostbite"
copy_dir "$repo_root/themes/plymouth/frostbite" "$airootfs/usr/share/plymouth/themes/frostbite"
copy_dir "$repo_root/calamares/branding/frostbite" "$airootfs/etc/calamares/branding/frostbite"
copy_dir "$repo_root/calamares/modules" "$airootfs/etc/calamares/modules"
mkdir -p "$airootfs/etc/calamares"
cp "$repo_root/calamares/settings.conf" "$airootfs/etc/calamares/settings.conf"

echo "synced theme and Calamares assets into archiso/airootfs"
