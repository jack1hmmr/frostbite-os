#!/usr/bin/env bash
# Runs as root inside the second installed-system boot. Output is intentionally
# routed to QEMU's serial log so the host can require an exact terminal marker.
exec >/dev/ttyS0 2>&1
set -Eeuo pipefail

expected_user="frosttest"
audit_result="FAIL"
audit_password=""

fail() {
  printf 'AUDIT ERROR: %s\n' "$*" >&2
  return 1
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || fail "required file is missing: $path"
}

require_absent() {
  local path="$1"
  [[ ! -e "$path" ]] || fail "live-only path survived: $path"
}

on_error() {
  local line="$1"
  local status="$2"
  printf 'AUDIT ERROR: command failed at line %s with status %s\n' "$line" "$status" >&2
}

finish() {
  local status="$?"
  trap - EXIT
  audit_password=""
  unset audit_password

  echo "--- failed units ---"
  systemctl --failed --no-legend --plain --no-pager || true
  echo "--- priority err journal (diagnostic only) ---"
  journalctl -b -p err --no-pager || true
  echo "--- end diagnostics ---"

  if (( status == 0 )) && [[ "$audit_result" == "PASS" ]]; then
    echo "FROSTBITE_VM_AUDIT_PASS"
  else
    echo "FROSTBITE_VM_AUDIT_FAIL"
    status=1
  fi
  sync
  systemctl poweroff --no-block || poweroff -f || true
  exit "$status"
}

trap 'on_error "$LINENO" "$?"' ERR
trap finish EXIT

[[ "$(id -u)" == "0" ]] || fail "audit must run as root"
uid_min="$(awk '$1 == "UID_MIN" { print $2; exit }' /etc/login.defs)"
uid_max="$(awk '$1 == "UID_MAX" { print $2; exit }' /etc/login.defs)"
if [[ ! "$uid_min" =~ ^[0-9]+$ || ! "$uid_max" =~ ^[0-9]+$ ]] || (( uid_min > uid_max )); then
  fail "could not determine normal-user UID range from /etc/login.defs"
fi
[[ -d /sys/firmware/efi ]] || fail "installed audit boot is not UEFI"
[[ "$(findmnt -n -o SOURCE /mnt/ci)" == "/dev/sr0" ]] || fail "audit CD is not /dev/sr0"
[[ "$(findmnt -n -o FSTYPE /mnt/ci)" == "iso9660" ]] || fail "audit media is not ISO9660"
findmnt -n -o OPTIONS /mnt/ci | tr ',' '\n' | grep -Fxq ro || fail "audit CD is not mounted read-only"

# Disk and partition contract: one 16 GiB virtio disk, GPT, a roughly 512 MiB
# EFI System Partition, and one ext4 root. No host block device is ever passed
# to this guest; /dev/vda is the disposable qcow2 created by the host wrapper.
[[ -b /dev/vda ]] || fail "disposable target /dev/vda is missing"
[[ "$(lsblk -dn -o TYPE /dev/vda)" == "disk" ]] || fail "/dev/vda is not a disk"
disk_bytes="$(blockdev --getsize64 /dev/vda)"
[[ "$disk_bytes" == "17179869184" ]] || fail "target is not exactly 16 GiB: $disk_bytes bytes"
[[ "$(blkid -p -s PTTYPE -o value /dev/vda)" == "gpt" ]] || fail "target partition table is not GPT"

mapfile -t target_partitions < <(lsblk -lnpo NAME,TYPE /dev/vda | awk '$2 == "part" { print $1 }')
(( ${#target_partitions[@]} == 2 )) || fail "expected exactly two target partitions"
[[ "${target_partitions[0]}" == "/dev/vda1" && "${target_partitions[1]}" == "/dev/vda2" ]] || \
  fail "unexpected target partition ordering: ${target_partitions[*]}"

root_source="$(readlink -f -- "$(findmnt -n -o SOURCE /)")"
esp_source="$(readlink -f -- "$(findmnt -n -o SOURCE /boot/efi)")"
[[ "$root_source" == "/dev/vda2" ]] || fail "root is not /dev/vda2: $root_source"
[[ "$esp_source" == "/dev/vda1" ]] || fail "ESP is not /dev/vda1: $esp_source"
[[ "$(findmnt -n -o FSTYPE /)" == "ext4" ]] || fail "root filesystem is not ext4"
[[ "$(findmnt -n -o FSTYPE /boot/efi)" == "vfat" ]] || fail "ESP filesystem is not vfat"

esp_type="$(lsblk -dn -o PARTTYPE /dev/vda1 | tr '[:upper:]' '[:lower:]')"
[[ "$esp_type" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] || fail "partition 1 is not an EFI System Partition"
esp_bytes="$(blockdev --getsize64 /dev/vda1)"
(( esp_bytes >= 500 * 1024 * 1024 && esp_bytes <= 520 * 1024 * 1024 )) || \
  fail "ESP is not approximately 512 MiB: $esp_bytes bytes"

# fstab must be stable across device enumeration and contain no live-media
# references. Verify both its syntax and the UUIDs of the active filesystems.
findmnt --verify --verbose >/dev/null
if grep -Eqs '(^|[[:space:]])/dev/vd|archiso|cowspace|airootfs|overlay' /etc/fstab; then
  fail "fstab contains a volatile device path or live-media reference"
fi
root_uuid="$(blkid -s UUID -o value /dev/vda2)"
esp_uuid="$(blkid -s UUID -o value /dev/vda1)"
awk -v uuid="$root_uuid" '$1 == "UUID=" uuid && $2 == "/" && $3 == "ext4" { found=1 } END { exit !found }' /etc/fstab || \
  fail "fstab does not mount ext4 root by its UUID"
awk -v uuid="$esp_uuid" '$1 == "UUID=" uuid && $2 == "/boot/efi" && $3 == "vfat" { found=1 } END { exit !found }' /etc/fstab || \
  fail "fstab does not mount the ESP by its UUID"

# Boot proof includes the removable-media fallback. Boot A used a fresh OVMF
# variable store and no ISO, so reaching this second boot already exercised it.
require_file /boot/efi/EFI/BOOT/BOOTX64.EFI
require_file /boot/efi/EFI/Frostbite/grubx64.efi
require_file /boot/grub/grub.cfg
require_file /boot/vmlinuz-linux-zen
require_file /boot/initramfs-linux-zen.img
require_file /boot/amd-ucode.img
require_file /boot/intel-ucode.img
require_file /etc/mkinitcpio.d/linux-zen.preset
grep -Fq '/boot/initramfs-linux-zen.img' /etc/mkinitcpio.d/linux-zen.preset || fail "normal initramfs preset is missing"
if grep -RqsE 'archiso|cowspace|airootfs' \
  /etc/mkinitcpio.conf /etc/mkinitcpio.conf.d /etc/mkinitcpio.d /boot/grub/grub.cfg
then
  fail "installed boot configuration contains an Archiso reference"
fi
initramfs_listing="$(lsinitcpio -l /boot/initramfs-linux-zen.img)"
if grep -Eqi 'archiso|cowspace|airootfs' <<<"$initramfs_listing"; then
  fail "normal initramfs contains an Archiso hook or file"
fi

# Account and credential cleanup. Exactly one human account may remain, and no
# active or backup database may contain the known live identity.
mapfile -t normal_users < <(awk -F: -v uid_min="$uid_min" -v uid_max="$uid_max" \
  '$3 >= uid_min && $3 <= uid_max { print $1 }' /etc/passwd)
(( ${#normal_users[@]} == 1 )) && [[ "${normal_users[0]}" == "$expected_user" ]] || \
  fail "expected exactly one normal user named $expected_user: ${normal_users[*]}"
getent passwd "$expected_user" >/dev/null || fail "installed user is missing"
[[ "$(passwd -S "$expected_user" | awk '{print $2}')" == "P" ]] || fail "installed user has no usable password"
[[ "$(cat /etc/hostname)" == "frostbite-ci" ]] || fail "installed hostname is not frostbite-ci"
[[ "$(hostnamectl --static)" == "frostbite-ci" ]] || fail "running static hostname is not frostbite-ci"
root_password_field="$(getent shadow root | cut -d: -f2)"
[[ "$root_password_field" == '!'* || "$root_password_field" == '*'* ]] || fail "root is not locked"
[[ "$(stat -c '%U:%G:%a' "/home/$expected_user")" == "$expected_user:$expected_user:700" ]] || \
  fail "installed home ownership or mode is unsafe"

for required_group in wheel video audio input storage power seat; do
  id -nG "$expected_user" | tr ' ' '\n' | grep -Fxq "$required_group" || \
    fail "installed user is missing group $required_group"
done
for database in /etc/passwd /etc/shadow /etc/group /etc/gshadow /etc/subuid /etc/subgid; do
  [[ -e "$database" ]] || continue
  if awk -F: '
    { for (field=1; field<=NF; field++) { count=split($field, values, ","); for (item=1; item<=count; item++) if (values[item] == "frostbite") found=1 } }
    END { exit found ? 0 : 1 }
  ' "$database"
  then
    fail "live identity survived in $database"
  fi
done
for path in \
  /home/frostbite \
  /var/mail/frostbite \
  /var/spool/mail/frostbite \
  /var/spool/cron/frostbite \
  /var/spool/cron/crontabs/frostbite \
  /var/lib/AccountsService/icons/frostbite \
  /var/lib/AccountsService/users/frostbite \
  /var/lib/systemd/linger/frostbite \
  /etc/passwd- /etc/shadow- /etc/group- /etc/gshadow- /etc/subuid- /etc/subgid-
do
  require_absent "$path"
done
getent group frostbite >/dev/null 2>&1 && fail "live frostbite group survived"

# Sudo must require the disposable user's password. Read it silently from
# tty2 only after the host sees the readiness marker; it never enters a shell
# command, history file, screenshot, serial log, or retained artifact.
require_absent /etc/sudoers.d/10-frostbite-live
require_absent /etc/polkit-1/rules.d/49-frostbite-live-installer.rules
require_absent /usr/share/polkit-1/actions/io.calamares.calamares.policy
[[ "$(stat -c '%a' /etc/sudoers.d/10-installer)" == "440" ]] || fail "installed sudoers mode is not 0440"
grep -Fqx '%wheel ALL=(ALL:ALL) ALL' /etc/sudoers.d/10-installer || fail "installed wheel sudo rule is wrong"
visudo -cf /etc/sudoers >/dev/null
if grep -RhsE '^[[:space:]]*[^#].*(NOPASSWD|!authenticate)' /etc/sudoers /etc/sudoers.d; then
  fail "passwordless sudo survived"
fi
runuser -u "$expected_user" -- sudo -k
if runuser -u "$expected_user" -- sudo -n /usr/bin/true >/dev/null 2>&1; then
  fail "installed user has noninteractive passwordless sudo"
fi
echo "FROSTBITE_VM_AUDIT_PASSWORD_READY"
IFS= read -r -s audit_password </dev/tty2
[[ -n "$audit_password" ]] || fail "audit password was empty"
printf '%s\n' "$audit_password" | runuser -u "$expected_user" -- sudo -S -p '' /usr/bin/true >/dev/null
audit_password=""
unset audit_password

# Installer packages, launchers, policy, configuration, and desktop entry
# must not consume target space or remain callable after installation.
for removed_package in calamares-frostbite squashfs-tools mkinitcpio-archiso xorg-xhost; do
  if pacman -Q "$removed_package" >/dev/null 2>&1; then
    fail "live-only package survived: $removed_package"
  fi
done
for path in \
  /etc/calamares \
  /etc/mkinitcpio.conf.d/archiso.conf \
  /etc/sway/frostbite-installer.conf \
  /root/customize_airootfs.sh \
  /usr/local/bin/frostbite-installer \
  /usr/local/bin/frostbite-install-prepare \
  /usr/local/bin/frostbite-install-finalize
do
  require_absent "$path"
done
if grep -RqsE 'frostbite-installer|frostbite\.install=1' \
  /etc/skel/.config/sway "/home/$expected_user/.config/sway"
then
  fail "live installer shortcut survived in the installed desktop"
fi
grep -Fqx 'exec $steam' "/home/$expected_user/.config/sway/config" || fail "installed Sway session does not launch Steam"

# Installed services and one-time state must match what a real first boot uses.
for enabled_unit in \
  NetworkManager.service fstrim.timer seatd.service frostbite-firstboot.service \
  frostbite-performance.service getty@tty1.service
do
  [[ "$(systemctl is-enabled "$enabled_unit")" == "enabled" ]] || fail "$enabled_unit is not enabled"
done
[[ "$(systemctl is-enabled NetworkManager-wait-online.service)" == "disabled" ]] || \
  fail "NetworkManager-wait-online.service is not disabled"
for active_unit in NetworkManager.service fstrim.timer seatd.service frostbite-performance.service getty@tty1.service; do
  systemctl is-active --quiet "$active_unit" || fail "$active_unit is not active"
done
require_file /var/lib/frostbite/firstboot.done
require_file /var/lib/frostbite/hardware.env
require_file /var/lib/frostbite/session-mode-detect.log
require_file /etc/frostbite/session-mode
grep -Eq '^(sway|gamescope)$' /etc/frostbite/session-mode || fail "invalid persisted session mode"
grep -Fqx "ExecStart=-/usr/bin/agetty --autologin $expected_user --noclear %I \$TERM" \
  /etc/systemd/system/getty@tty1.service.d/autologin.conf || fail "TTY1 autologin does not name the installed user"
[[ "$(cat /etc/machine-id)" =~ ^[0-9a-f]{32}$ ]] || fail "machine-id is not 32 lowercase hex characters"
[[ -z "$(systemctl --failed --no-legend --plain --no-pager)" ]] || fail "installed system has failed units"
if ! pgrep -x sway >/dev/null && ! pgrep -x gamescope >/dev/null; then
  fail "neither Sway nor gamescope is alive for the autologin session"
fi

echo "--- installed block layout ---"
lsblk -o NAME,TYPE,SIZE,FSTYPE,PARTTYPE,UUID,MOUNTPOINTS /dev/vda
echo "--- installed checksums ---"
sha256sum \
  /boot/efi/EFI/BOOT/BOOTX64.EFI \
  /boot/efi/EFI/Frostbite/grubx64.efi \
  /boot/vmlinuz-linux-zen \
  /boot/initramfs-linux-zen.img \
  /boot/amd-ucode.img \
  /boot/intel-ucode.img
echo "--- installed package inventory ---"
pacman -Q | sort
echo "--- end installed package inventory ---"

audit_result="PASS"
