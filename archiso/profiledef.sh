#!/usr/bin/env bash
# shellcheck shell=bash

iso_name="frostbite-os"
iso_label="FROSTBITE_$(date +%Y%m)"
iso_publisher="Frostbite OS"
iso_application="Frostbite OS Live/Install Media"
iso_version="$(date +%Y.%m.%d)"
install_dir="frostbite"
buildmodes=('iso')
bootmodes=('uefi.grub')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '1')

file_permissions=(
  ["/root/customize_airootfs.sh"]="0:0:755"
  ["/usr/local/bin/frostbite-firstboot"]="0:0:755"
  ["/usr/local/bin/frostbite-hardware-detect"]="0:0:755"
  ["/usr/local/bin/frostbite-install-finalize"]="0:0:755"
  ["/usr/local/bin/frostbite-performance"]="0:0:755"
  ["/usr/local/bin/frostbite-session"]="0:0:755"
  ["/usr/local/bin/frostbite-steam-setup"]="0:0:755"
  ["/etc/sudoers.d/10-frostbite-live"]="0:0:440"
)
