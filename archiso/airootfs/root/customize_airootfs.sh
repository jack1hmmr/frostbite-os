#!/usr/bin/env bash
set -euo pipefail

useradd -m -G wheel,video,audio,input,storage,power -s /bin/bash frostbite 2>/dev/null || true
echo 'frostbite:frostbite' | chpasswd
passwd -d root >/dev/null 2>&1 || true

chmod 0440 /etc/sudoers.d/10-frostbite-live

systemctl enable NetworkManager.service
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
