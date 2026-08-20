#!/usr/bin/env bash
set -euo pipefail

systemd-sysusers
useradd -m -G wheel,video,audio,input,storage,power,seat -s /bin/bash frostbite
echo 'frostbite:frostbite' | chpasswd
usermod -p '!' root

# Complete systemd's first-boot data before the immutable live image starts.
# Calamares replaces this with the timezone selected for the installed target.
ln -sfn /usr/share/zoneinfo/UTC /etc/localtime

chmod 0440 /etc/sudoers.d/10-frostbite-live

# mkarchiso removes /boot from the SquashFS after copying it to the ISO. Keep
# the package-generated microcode images where the offline installer can carry
# them into the installed system.
install -Dm0644 /boot/amd-ucode.img /usr/share/frostbite/installed/amd-ucode.img
install -Dm0644 /boot/intel-ucode.img /usr/share/frostbite/installed/intel-ucode.img

systemctl enable NetworkManager.service
systemctl enable NetworkManager-wait-online.service
systemctl enable fstrim.timer
systemctl enable getty@tty1.service
systemctl enable frostbite-firstboot.service
systemctl enable frostbite-performance.service
systemctl enable seatd.service

for unit in \
  avahi-daemon.service avahi-daemon.socket \
  bluetooth.service \
  cups.service cups.socket cups.path \
  ModemManager.service \
  packagekit.service \
  systemd-coredump.socket
do
  systemctl mask "$unit" >/dev/null 2>&1 || true
done
