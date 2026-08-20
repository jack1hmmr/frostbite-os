#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
package_source="$repo_root/packaging/calamares-frostbite"
work_root="${CALAMARES_BUILD_DIR:-$repo_root/work/calamares-package}"
package_dir="${CALAMARES_PACKAGE_DIR:-$repo_root/work/packages}"

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  echo "build-calamares-package.sh must run as an unprivileged user; makepkg refuses root." >&2
  exit 1
fi

required_commands=(bsdtar makepkg namcap pacman sha256sum)
for command_name in "${required_commands[@]}"; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "missing build command: $command_name" >&2
    exit 1
  fi
done

required_packages=(
  base-devel
  cmake
  extra-cmake-modules
  kcoreaddons
  kpmcore
  libpwquality
  namcap
  ninja
  parted
  polkit
  polkit-qt6
  python
  qt6-base
  qt6-svg
  qt6-tools
  squashfs-tools
  yaml-cpp
)
missing_packages="$(pacman -T "${required_packages[@]}" 2>/dev/null || true)"
if [[ -n "$missing_packages" ]]; then
  printf 'missing package-build dependencies:\n%s\n' "$missing_packages" >&2
  exit 1
fi

mkdir -p "$work_root" "$package_dir"
stage_dir="$(mktemp -d "$work_root/source.XXXXXXXX")"
install -Dm0644 "$package_source/PKGBUILD" "$stage_dir/PKGBUILD"
install -Dm0644 \
  "$package_source/frostbite-erase-only.patch" \
  "$stage_dir/frostbite-erase-only.patch"
install -Dm0644 \
  "$package_source/frostbite-existing-user.patch" \
  "$stage_dir/frostbite-existing-user.patch"

(
  cd "$stage_dir"
  export PKGDEST="$package_dir"
  export SOURCE_DATE_EPOCH=1773154435
  export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-2}"
  makepkg --cleanbuild --clean --force --noconfirm
)

shopt -s nullglob
packages=("$package_dir"/calamares-frostbite-3.4.2-1-x86_64.pkg.tar.zst)
if (( ${#packages[@]} != 1 )); then
  echo "expected exactly one Calamares package, found ${#packages[@]}" >&2
  exit 1
fi
package_path="${packages[0]}"

if [[ "$(pacman -Qp "$package_path")" != "calamares-frostbite 3.4.2-1" ]]; then
  echo "unexpected Calamares package identity: $package_path" >&2
  exit 1
fi

required_modules=(
  bootloader
  finished
  fstab
  hwclock
  initcpio
  keyboard
  locale
  localecfg
  machineid
  mount
  partition
  services-systemd
  shellprocess
  summary
  umount
  unpackfs
  users
  welcome
)
archive_listing="$(bsdtar -tf "$package_path")"
for module in "${required_modules[@]}"; do
  if ! grep -Fqx "usr/lib/calamares/modules/$module/module.desc" <<<"$archive_listing"; then
    echo "Calamares package is missing required module: $module" >&2
    exit 1
  fi
done

for forbidden_module in packages packagechooserq removeuser usersq welcomeq; do
  if grep -Fq "usr/lib/calamares/modules/$forbidden_module/" <<<"$archive_listing"; then
    echo "Calamares package unexpectedly contains module: $forbidden_module" >&2
    exit 1
  fi
done

namcap "$stage_dir/PKGBUILD"
namcap "$package_path"
(cd "$package_dir" && sha256sum "$(basename -- "$package_path")") > "$package_path.sha256"
bsdtar -xOf "$package_path" .BUILDINFO > "$package_path.BUILDINFO"

echo "built and verified $package_path"
