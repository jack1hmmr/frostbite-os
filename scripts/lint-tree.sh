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
  "$repo_root/archiso/airootfs/etc/sway/frostbite-installer.conf"
  "$repo_root/archiso/airootfs/usr/local/bin/frostbite-firstboot"
  "$repo_root/archiso/airootfs/usr/local/bin/frostbite-hardware-detect"
  "$repo_root/archiso/airootfs/usr/local/bin/frostbite-install-finalize"
  "$repo_root/archiso/airootfs/usr/local/bin/frostbite-install-prepare"
  "$repo_root/archiso/airootfs/usr/local/bin/frostbite-installer"
  "$repo_root/archiso/airootfs/usr/local/bin/frostbite-performance"
  "$repo_root/archiso/airootfs/usr/local/bin/frostbite-session"
  "$repo_root/archiso/airootfs/usr/local/bin/frostbite-steam-launch"
  "$repo_root/calamares/settings.conf"
  "$repo_root/calamares/modules/partition.conf"
  "$repo_root/calamares/modules/shellprocess-prepare.conf"
  "$repo_root/calamares/modules/shellprocess-finalize.conf"
  "$repo_root/calamares/modules/users.conf"
  "$repo_root/calamares/branding/frostbite/stylesheet.qss"
  "$repo_root/docs/installer-acceptance.md"
  "$repo_root/packaging/calamares-frostbite/PKGBUILD"
  "$repo_root/packaging/calamares-frostbite/frostbite-erase-only.patch"
  "$repo_root/packaging/calamares-frostbite/frostbite-existing-user.patch"
  "$repo_root/scripts/audit-installed-vm.sh"
  "$repo_root/scripts/build-calamares-package.sh"
  "$repo_root/scripts/lib/calamares-vm-driver.py"
  "$repo_root/scripts/test-installer-vm.sh"
  "$repo_root/scripts/validate-installer.py"
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
installer_sway_cfg="$repo_root/archiso/airootfs/etc/sway/frostbite-installer.conf"
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
  echo "ordinary Sway config does not launch Steam safely: $sway_cfg" >&2
  exit 1
fi
if grep -Eq 'frostbite-installer|frostbite\.install=1' "$sway_cfg"; then
  echo "ordinary Sway config exposes the live-only installer: $sway_cfg" >&2
  exit 1
fi

if ! grep -Eq '^[[:space:]]*if ! dbus-update-activation-environment --systemd' "$steam_launcher"; then
  echo "Steam launcher is missing the Xwayland activation environment update: $steam_launcher" >&2
  exit 1
fi

if grep -RqsF '|| true' "$repo_root/calamares"; then
  echo "Calamares configuration contains a fail-open command" >&2
  exit 1
fi

if [[ -e "$repo_root/calamares/modules/packages.conf" || \
      -e "$repo_root/calamares/modules/shellprocess-frostbite.conf" || \
      -e "$repo_root/calamares/branding/frostbite/style.qss" ]]
then
  echo "obsolete permissive installer configuration survived" >&2
  exit 1
fi

if ! grep -Fqx 'include /etc/sway/config.d/*' "$installer_sway_cfg" || \
   ! grep -Fqx 'xwayland force' "$installer_sway_cfg" || \
   ! grep -Fqx 'set $installer frostbite-installer' "$installer_sway_cfg" || \
   ! grep -Fqx 'bindsym $mod+i exec $installer' "$installer_sway_cfg" || \
   ! grep -Fqx 'exec $installer' "$installer_sway_cfg"
then
  echo "dedicated Sway config does not launch the installer safely: $installer_sway_cfg" >&2
  exit 1
fi
if grep -Eq '^[[:space:]]*bind(sym|code).*[[:space:]](kill|reload)([[:space:]]|$)|swaymsg[[:space:]]+exit' \
  "$installer_sway_cfg"
then
  echo "dedicated installer Sway config exposes a kill, reload, or exit shortcut" >&2
  exit 1
fi

installer_boot_count="$(grep -Ec '^[[:space:]]+linux .*frostbite\.install=1([[:space:]]|$)' "$grub_cfg")"
if [[ "$installer_boot_count" != "1" ]] || \
   ! grep -Fq -- "--id 'frostbite-installer'" "$grub_cfg"
then
  echo "GRUB must expose exactly one dedicated Frostbite installer entry" >&2
  exit 1
fi
installer_kernel_line="$(grep -E '^[[:space:]]+linux .*frostbite\.install=1([[:space:]]|$)' "$grub_cfg")"
for installer_boot_token in \
  'systemd.mask=frostbite-firstboot.service' \
  'systemd.mask=NetworkManager-wait-online.service' \
  'console=ttyS0,115200n8' \
  'console=tty0'
do
  if [[ "$installer_kernel_line" != *"$installer_boot_token"* ]]; then
    echo "dedicated installer boot entry is missing: $installer_boot_token" >&2
    exit 1
  fi
done

session_launcher="$repo_root/archiso/airootfs/usr/local/bin/frostbite-session"
if ! grep -Fq "grep -qw 'frostbite.install=1' /proc/cmdline" "$session_launcher" || \
   ! grep -Fqx '  export WLR_RENDERER=pixman' "$session_launcher" || \
   ! grep -Fqx '      > >(sudo -n tee -a /dev/ttyS0 | \' "$session_launcher" || \
   ! grep -Fqx '  exec systemd-cat --identifier=frostbite-installer --priority=debug \' "$session_launcher" || \
   ! grep -Fqx '    sway --debug --config "$installer_sway_config"' "$session_launcher"
then
  echo "the installer boot flag does not force the dedicated recoverable Sway path" >&2
  exit 1
fi
fallback_sway_block="$(
  sed -n '/^if \[\[ "$session_mode" == "sway" \]\]; then$/,/^exec sway$/p' "$session_launcher"
)"
if ! grep -Fqx 'if [[ "$session_mode" == "sway" ]]; then' <<<"$fallback_sway_block" || \
   ! grep -Fqx '  export WLR_RENDERER=pixman' <<<"$fallback_sway_block" || \
   ! grep -Fqx 'exec sway' <<<"$fallback_sway_block"
then
  echo "the persisted Sway fallback must force wlroots' pixman renderer" >&2
  exit 1
fi

installer_launcher="$repo_root/archiso/airootfs/usr/local/bin/frostbite-installer"
if ! grep -Fqx 'xhost +SI:localuser:root >/dev/null 2>&1 || \' "$installer_launcher" || \
   ! grep -Fqx '    xhost -SI:localuser:root >/dev/null 2>&1 || true' "$installer_launcher" || \
   grep -Eq 'xhost[[:space:]]+\+([[:space:]]|$)' "$installer_launcher"
then
  echo "installer launcher lost its scoped, revocable root-only Xwayland authorization" >&2
  exit 1
fi

if ! grep -Fqx 'swaybg' "$repo_root/manifests/gaming-core.packages" || \
   ! grep -Fqx 'xorg-xhost' "$repo_root/manifests/installer.packages"
then
  echo "Sway or the live-only Xwayland authorization helper is missing" >&2
  exit 1
fi

if ! grep -Fqx '    removeuser' "$repo_root/packaging/calamares-frostbite/PKGBUILD"; then
  echo "the unsafe removeuser module is not excluded from the custom package" >&2
  exit 1
fi

if ! grep -Fqx '  ["/etc/polkit-1/rules.d/49-frostbite-live-installer.rules"]="0:0:644"' \
  "$repo_root/archiso/profiledef.sh"
then
  echo "the live installer polkit rule lacks an explicit root-owned mode" >&2
  exit 1
fi
if ! grep -Fqx '  ["/etc/sway/frostbite-installer.conf"]="0:0:644"' \
  "$repo_root/archiso/profiledef.sh"
then
  echo "dedicated installer Sway config lacks an explicit root-owned mode" >&2
  exit 1
fi

if grep -Fqx 'linux-zen-headers' "$repo_root/archiso/packages.x86_64" || \
   grep -Fqx 'linux-zen-headers' "$repo_root/manifests/base.packages"
then
  echo "default Frostbite image still carries DKMS kernel headers" >&2
  exit 1
fi
if ! grep -Fqx 'linux-zen-headers' "$repo_root/manifests/drivers-nvidia.packages"; then
  echo "optional NVIDIA DKMS manifest is missing linux-zen-headers" >&2
  exit 1
fi

if ! grep -Fqx "usermod -p '!' root" "$repo_root/archiso/airootfs/root/customize_airootfs.sh" || \
   grep -Fq 'passwd -d root' "$repo_root/archiso/airootfs/root/customize_airootfs.sh"
then
  echo "the live root account is not fail-hard locked at image creation" >&2
  exit 1
fi

if ! grep -Fq 'llvmpipe|lavapipe|software rasterizer' \
  "$repo_root/archiso/airootfs/usr/local/bin/frostbite-firstboot"
then
  echo "first boot does not reject software-only Vulkan for gamescope" >&2
  exit 1
fi

patch_checksum="$({ sha256sum "$repo_root/packaging/calamares-frostbite/frostbite-erase-only.patch"; } | awk '{print $1}')"
if [[ "$patch_checksum" != "cdb91f9613edf26a92b812a5aa76053c29ea1f9ddebe4b1674a2ab031416d2d0" ]]; then
  echo "Frostbite erase-only patch checksum changed: $patch_checksum" >&2
  exit 1
fi
existing_user_patch_checksum="$({ sha256sum "$repo_root/packaging/calamares-frostbite/frostbite-existing-user.patch"; } | awk '{print $1}')"
if [[ "$existing_user_patch_checksum" != "dc41c953b83b3b2ccc36e94139b1c07b8d88b11eabc5a0fd34e53e554febd8fb" ]]; then
  echo "Frostbite existing-user patch checksum changed: $existing_user_patch_checksum" >&2
  exit 1
fi

if ! diff -qr "$repo_root/calamares" "$repo_root/archiso/airootfs/etc/calamares" >/dev/null; then
  echo "tracked Calamares configuration is not synchronized into airootfs" >&2
  exit 1
fi

vm_wrapper="$repo_root/scripts/test-installer-vm.sh"
vm_driver="$repo_root/scripts/lib/calamares-vm-driver.py"
vm_audit="$repo_root/scripts/audit-installed-vm.sh"
if ! grep -Fq 'qemu-img create -q -f qcow2 "$target_disk" 16G' "$vm_wrapper" || \
   ! grep -Fq -- '-nic none' "$vm_wrapper" || \
   ! grep -Fq -- '-nodefaults' "$vm_wrapper" || \
   ! grep -Fq 'FROSTBITE_VM_EVIDENCE_DIR' "$vm_wrapper"
then
  echo "disposable VM wrapper lost a disk, network, default-device, or evidence safety invariant" >&2
  exit 1
fi
if grep -Eq -- '^[[:space:]]+-(fsdev|virtfs|netdev)([[:space:],]|$)|^[[:space:]]+-drive .*file=/dev/' "$vm_wrapper"; then
  echo "disposable VM wrapper contains a host passthrough or network backend" >&2
  exit 1
fi
for required_vm_token in \
  screendump input-send-event tesseract 'Start Frostbite OS[\s\S]*Install Frostbite OS' \
  'Erase disk' destructive-summary \
  'all done' 'has been installed' central-inverted FROSTBITE_VM_AUDIT_PASSWORD_READY \
  TEXT_KEY_DELAY POINTER_EVENT_DELAY
do
  if ! grep -Fq "$required_vm_token" "$vm_driver"; then
    echo "stateful VM driver is missing contract token: $required_vm_token" >&2
    exit 1
  fi
done
destructive_summary_block="$(
  sed -n '/"destructive-summary"/,/driver.shortcut("alt", "i")/p' "$vm_driver"
)"
for required_summary_token in \
  'r"install procedure"' 'r"erase"' 'r"vda"' 'r"gpt"' \
  'r"512\s*mib"' 'r"efi"' 'r"ext4"' 'central=False'
do
  if ! grep -Fq "$required_summary_token" <<<"$destructive_summary_block"; then
    echo "destructive Summary gate is missing contract token: $required_summary_token" >&2
    exit 1
  fi
done
if ! grep -Fqx '    echo "FROSTBITE_VM_AUDIT_PASS"' "$vm_audit" || \
   ! grep -Fqx '    echo "FROSTBITE_VM_AUDIT_FAIL"' "$vm_audit"
then
  echo "installed-system audit lost its exact serial terminal markers" >&2
  exit 1
fi
if ! grep -Fq 'driver.type_text("frostbite-ci")' "$vm_driver" || \
   ! grep -Fq 'installed hostname is not frostbite-ci' "$vm_audit"
then
  echo "VM input and installed-system audit disagree on the disposable hostname" >&2
  exit 1
fi

find "$repo_root" -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
find "$repo_root/archiso/airootfs/usr/local/bin" -type f -print0 | xargs -0 -n1 bash -n
for python_script in "$repo_root/scripts/validate-installer.py" "$vm_driver"; do
  python3 -c 'import pathlib, sys; path = pathlib.Path(sys.argv[1]); compile(path.read_text(), str(path), "exec")' \
    "$python_script"
done
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  echo "python-yaml is required for fail-hard installer validation" >&2
  exit 1
fi
"$repo_root/scripts/validate-installer.py"

echo "tree looks complete"
