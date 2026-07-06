#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
profile="$repo_root/archiso"
work_dir="${WORK_DIR:-$repo_root/work/archiso}"
out_dir="${OUT_DIR:-$repo_root/out}"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "build-iso.sh must run as root because mkarchiso creates a chroot." >&2
  exit 1
fi

if ! command -v mkarchiso >/dev/null 2>&1; then
  echo "mkarchiso is not installed. On Arch, install the archiso package." >&2
  exit 1
fi

"$repo_root/scripts/compose-packages.sh"
"$repo_root/scripts/sync-assets.sh"

mkdir -p "$work_dir" "$out_dir"
mkarchiso -v -w "$work_dir" -o "$out_dir" "$profile"
