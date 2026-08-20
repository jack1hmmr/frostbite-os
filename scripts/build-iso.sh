#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source_profile="$repo_root/archiso"
work_dir="${WORK_DIR:-$repo_root/work/archiso}"
out_dir="${OUT_DIR:-$repo_root/out}"
package_dir="${CALAMARES_PACKAGE_DIR:-$repo_root/work/packages}"
build_profile="$repo_root/work/profile"
local_repo="$repo_root/work/installer-repo"
generated_pacman_conf="$local_repo/pacman.conf"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "build-iso.sh must run as root because mkarchiso creates a chroot." >&2
  exit 1
fi

for command_name in mkarchiso pacman repo-add; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "missing ISO-build command: $command_name" >&2
    exit 1
  fi
done

shopt -s nullglob
calamares_packages=("$package_dir"/calamares-frostbite-3.4.2-1-x86_64.pkg.tar.zst)
if (( ${#calamares_packages[@]} != 1 )); then
  echo "expected one verified Calamares package in $package_dir" >&2
  echo "run scripts/build-calamares-package.sh as an unprivileged user first" >&2
  exit 1
fi
calamares_package="${calamares_packages[0]}"
if [[ "$(pacman -Qp "$calamares_package")" != "calamares-frostbite 3.4.2-1" ]]; then
  echo "unexpected Calamares package identity: $calamares_package" >&2
  exit 1
fi
package_checksum="$calamares_package.sha256"
package_buildinfo="$calamares_package.BUILDINFO"
if [[ ! -f "$package_checksum" || ! -f "$package_buildinfo" ]]; then
  echo "Calamares package provenance sidecars are missing" >&2
  exit 1
fi
if ! (cd "$package_dir" && sha256sum --check --status "$(basename -- "$package_checksum")"); then
  echo "Calamares package checksum verification failed" >&2
  exit 1
fi

# Reject a package reused across an incompatible Arch snapshot. These are the
# ABI-sensitive build/runtime dependencies most likely to invalidate the
# Python, Qt, KPMCore, or YAML bindings carried by the custom package.
for build_dependency in \
  kcoreaddons \
  kpmcore \
  libpwquality \
  parted \
  polkit \
  python \
  qt6-base \
  qt6-svg \
  yaml-cpp
do
  installed_buildinfo="$(pacman -Q --print-format '%n-%v-%a' "$build_dependency")"
  if ! grep -Fqx "installed = ${installed_buildinfo}" "$package_buildinfo"; then
    echo "Calamares package was built against a different $build_dependency snapshot" >&2
    exit 1
  fi
done

"$repo_root/scripts/compose-packages.sh"
"$repo_root/scripts/sync-assets.sh"

# Build from a disposable profile copy so date synchronization and mkarchiso
# never edit tracked source files in place.
if [[ "$build_profile" != "$repo_root/work/"* || "$local_repo" != "$repo_root/work/"* ]]; then
  echo "refusing to prepare build paths outside the repository work directory" >&2
  exit 1
fi
rm -rf -- "$build_profile" "$local_repo"
mkdir -p "$repo_root/work" "$local_repo"
cp -a "$source_profile" "$build_profile"

cp "$source_profile/pacman.conf" "$generated_pacman_conf"
cp "$calamares_package" "$local_repo/"
repo-add \
  "$local_repo/frostbite-build.db.tar.zst" \
  "$local_repo/$(basename -- "$calamares_package")"
cat >> "$generated_pacman_conf" <<CONF

[frostbite-build]
SigLevel = Optional TrustAll
Server = file://$local_repo
CONF

# Keep grub.cfg's archisolabel in sync with profiledef.sh's iso_label,
# since iso_label is date-based and grub.cfg is a static committed file. This
# only touches the disposable profile copy above.
current_label="FROSTBITE_$(date +%Y%m)"
sed -i "s/archisolabel=FROSTBITE_[0-9]\{6\}/archisolabel=${current_label}/g" "$build_profile/grub/grub.cfg"
echo "synced grub.cfg archisolabel to ${current_label}"

if [[ -e "$work_dir" ]]; then
  echo "mkarchiso work directory must not already exist: $work_dir" >&2
  echo "use a fresh WORK_DIR so run-once markers cannot hide stale build state" >&2
  exit 1
fi
mkdir -p "$out_dir"
mkarchiso \
  -C "$generated_pacman_conf" \
  -v \
  -w "$work_dir" \
  -o "$out_dir" \
  "$build_profile"
