#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
driver="$repo_root/scripts/lib/calamares-vm-driver.py"
audit_script="$repo_root/scripts/audit-installed-vm.sh"
evidence_dir="${FROSTBITE_VM_EVIDENCE_DIR:-$repo_root/out/vm-test-evidence}"
vm_parent="${RUNNER_TEMP:-$repo_root/work}"
vm_dir=""
qemu_pid=""
evidence_dir_created="0"

# Deliberately fixed and disposable: it is used only in a qcow2 that is erased
# at exit and is never uploaded. It is not a credential for any real account.
export FROSTBITE_VM_PASSWORD="Arctic9Comet27"

die() {
  printf 'VM acceptance error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

validate_qemu_path() {
  local path="$1"
  local label="$2"
  [[ "$path" == /* ]] || die "$label is not an absolute path"
  [[ "$path" != *','* && "$path" != *$'\n'* && "$path" != *$'\r'* ]] || \
    die "$label contains a QEMU option delimiter or newline"
}

stop_qemu() {
  if [[ -n "$qemu_pid" ]] && kill -0 "$qemu_pid" >/dev/null 2>&1; then
    kill -TERM "$qemu_pid" >/dev/null 2>&1 || true
    local deadline=$((SECONDS + 15))
    while kill -0 "$qemu_pid" >/dev/null 2>&1 && (( SECONDS < deadline )); do
      sleep 1
    done
    if kill -0 "$qemu_pid" >/dev/null 2>&1; then
      kill -KILL "$qemu_pid" >/dev/null 2>&1 || true
    fi
    wait "$qemu_pid" >/dev/null 2>&1 || true
  fi
  qemu_pid=""
}

cleanup() {
  local status="$?"
  trap - EXIT INT TERM
  set +e
  stop_qemu
  unset FROSTBITE_VM_PASSWORD

  # Polling images are replaceable scratch. Named success/timeout screenshots,
  # OCR, serial logs, and QEMU logs remain as upload-safe evidence.
  if [[ "$evidence_dir_created" == "1" ]]; then
    for phase in install boot-a boot-b; do
      poll_dir="$evidence_dir/$phase/.poll"
      if [[ -d "$poll_dir" && ! -L "$poll_dir" ]]; then
        find "$poll_dir" -depth -delete
      fi
    done
  fi

  # Refuse broad cleanup. The only deletable directory is the validated mktemp
  # child created below; qcow2, OVMF vars, and audit ISO never leave it.
  if [[ -n "$vm_dir" && -d "$vm_dir" && ! -L "$vm_dir" && "$vm_dir" == "$vm_parent"/frostbite-installer-vm.* ]]; then
    find "$vm_dir" -depth -delete
  fi
  if (( status != 0 )); then
    if [[ "$evidence_dir_created" == "1" ]]; then
      printf 'VM acceptance failed; upload-safe evidence remains in %s\n' "$evidence_dir" >&2
    else
      echo 'VM acceptance failed before its evidence directory was created' >&2
    fi
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for command_name in \
  awk blkid findmnt grep install lsblk magick python3 qemu-img qemu-system-x86_64 \
  realpath sed sha256sum stat tesseract xorriso
do
  require_command "$command_name"
done
[[ -x "$driver" ]] || die "VM driver is not executable: $driver"
[[ -x "$audit_script" ]] || die "installed-system audit is not executable: $audit_script"

if (( $# > 1 )); then
  die "usage: $0 [frostbite.iso]"
fi
if (( $# == 1 )); then
  iso_path="$(realpath -e -- "$1")"
else
  mapfile -t iso_candidates < <(find "$repo_root/out" -maxdepth 1 -type f -name '*.iso' -print | sort)
  (( ${#iso_candidates[@]} == 1 )) || die "expected exactly one ISO under $repo_root/out"
  iso_path="$(realpath -e -- "${iso_candidates[0]}")"
fi
[[ -f "$iso_path" && -r "$iso_path" && ! -L "$iso_path" && ! -b "$iso_path" ]] || \
  die "installer input must be one readable regular ISO file"
validate_qemu_path "$iso_path" "installer ISO"

mkdir -p -- "$vm_parent"
vm_parent="$(realpath -e -- "$vm_parent")"
[[ -d "$vm_parent" && ! -L "$vm_parent" ]] || die "unsafe VM temporary parent: $vm_parent"
vm_dir="$(mktemp -d -- "$vm_parent/frostbite-installer-vm.XXXXXXXX")"
[[ -d "$vm_dir" && ! -L "$vm_dir" && "$vm_dir" == "$vm_parent"/frostbite-installer-vm.* ]] || \
  die "mktemp returned an unsafe VM directory: $vm_dir"
chmod 0700 "$vm_dir"
validate_qemu_path "$vm_dir" "VM temporary directory"

evidence_dir="$(realpath -m -- "$evidence_dir")"
[[ "$evidence_dir" == "$repo_root"/out/* ]] || die "evidence directory must be a child of $repo_root/out"
evidence_parent="$(dirname -- "$evidence_dir")"
mkdir -p -- "$evidence_parent"
evidence_parent="$(realpath -e -- "$evidence_parent")"
evidence_dir="$evidence_parent/$(basename -- "$evidence_dir")"
[[ "$evidence_dir" == "$repo_root"/out/* ]] || die "evidence directory must be a child of $repo_root/out"
[[ ! -e "$evidence_dir" ]] || die "refusing to overwrite existing VM evidence: $evidence_dir"
mkdir -m 0755 -- "$evidence_dir"
evidence_dir_created="1"
validate_qemu_path "$evidence_dir" "VM evidence directory"

ovmf_code=""
ovmf_vars_template=""
for ovmf_root in /usr/share/edk2/x64 /usr/share/edk2-ovmf/x64; do
  if [[ -f "$ovmf_root/OVMF_CODE.4m.fd" && -f "$ovmf_root/OVMF_VARS.4m.fd" ]]; then
    ovmf_code="$ovmf_root/OVMF_CODE.4m.fd"
    ovmf_vars_template="$ovmf_root/OVMF_VARS.4m.fd"
    break
  fi
done
[[ -n "$ovmf_code" && -n "$ovmf_vars_template" ]] || die "OVMF 4 MiB firmware files were not found"
[[ -f "$ovmf_code" && ! -L "$ovmf_code" && -f "$ovmf_vars_template" && ! -L "$ovmf_vars_template" ]] || \
  die "OVMF inputs must be regular non-symlink files"
validate_qemu_path "$ovmf_code" "OVMF code"
validate_qemu_path "$ovmf_vars_template" "OVMF variables template"

if [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
  accelerator_args=(-accel kvm -cpu host)
  accelerator_name="kvm"
else
  accelerator_args=(-accel tcg,thread=multi -cpu max)
  accelerator_name="tcg"
fi

target_disk="$vm_dir/frostbite-target.qcow2"
qemu-img create -q -f qcow2 "$target_disk" 16G
[[ -f "$target_disk" && ! -L "$target_disk" ]] || die "qemu-img did not create a regular target"
[[ "$(qemu-img info --output=json "$target_disk" | python3 -c 'import json,sys; print(json.load(sys.stdin)["virtual-size"])')" == "17179869184" ]] || \
  die "target virtual size is not exactly 16 GiB"
[[ "$(qemu-img info --output=json "$target_disk" | python3 -c 'import json,sys; print(json.load(sys.stdin)["format"])')" == "qcow2" ]] || \
  die "target format is not qcow2"

{
  printf 'accelerator=%s\n' "$accelerator_name"
  printf 'target_virtual_bytes=17179869184\n'
  printf 'guest_memory_mib=4096\n'
  printf 'guest_cpus=2\n'
  printf 'network=none\n'
  qemu-system-x86_64 --version | head -1
  sha256sum "$iso_path" "$audit_script"
} >"$evidence_dir/vm-manifest.txt"

wait_for_qemu_exit() {
  local phase="$1"
  local timeout_seconds="$2"
  local deadline=$((SECONDS + timeout_seconds))
  while kill -0 "$qemu_pid" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      die "$phase VM did not power off within ${timeout_seconds}s"
    fi
    sleep 1
  done
  local status=0
  wait "$qemu_pid" || status="$?"
  qemu_pid=""
  (( status == 0 )) || die "$phase QEMU exited with status $status"
}

start_vm() {
  local phase="$1"
  local vars_path="$2"
  local cd_path="${3:-}"
  local cd_bootindex="${4:-}"
  local disk_bootindex="1"
  if [[ "$phase" == "install" ]]; then
    disk_bootindex="2"
  fi
  local qmp_socket="$vm_dir/$phase.qmp.sock"
  local serial_log="$evidence_dir/$phase-serial.log"
  local qemu_log="$evidence_dir/$phase-qemu.log"

  [[ -f "$vars_path" && ! -L "$vars_path" ]] || die "unsafe OVMF vars for $phase"
  [[ ! -e "$qmp_socket" ]] || die "stale control socket for $phase"
  validate_qemu_path "$vars_path" "$phase OVMF vars"
  validate_qemu_path "$target_disk" "$phase target disk"
  validate_qemu_path "$qmp_socket" "$phase QMP socket"
  validate_qemu_path "$serial_log" "$phase serial log"
  [[ "$(realpath -e -- "$vars_path")" == "$vm_dir"/* ]] || die "$phase OVMF vars escaped VM temporary directory"
  [[ "$(realpath -e -- "$target_disk")" == "$vm_dir"/* ]] || die "$phase target escaped VM temporary directory"
  [[ "$(realpath -m -- "$serial_log")" == "$evidence_dir"/* ]] || die "$phase serial log escaped evidence directory"

  local -a args=(
    -name "frostbite-$phase"
    -machine q35,smm=on
    "${accelerator_args[@]}"
    -m 4096
    -smp 2
    -nodefaults
    -no-user-config
    -no-reboot
    -rtc base=utc
    -monitor none
    -display none
    -qmp "unix:$qmp_socket,server=on,wait=off"
    -chardev "file,id=serial0,path=$serial_log"
    -device isa-serial,chardev=serial0
    -device virtio-vga
    -device qemu-xhci,id=xhci
    -device usb-kbd,bus=xhci.0
    -device usb-tablet,bus=xhci.0
    -nic none
    -drive "if=pflash,unit=0,format=raw,readonly=on,file=$ovmf_code"
    -drive "if=pflash,unit=1,format=raw,file=$vars_path"
    -drive "if=none,id=target,format=qcow2,cache=writeback,discard=unmap,file=$target_disk"
    -device "virtio-blk-pci,drive=target,serial=FROSTBITE_VM_TARGET,bootindex=$disk_bootindex"
  )
  if [[ -n "$cd_path" ]]; then
    [[ -f "$cd_path" && ! -L "$cd_path" && ! -b "$cd_path" ]] || die "unsafe read-only CD for $phase"
    validate_qemu_path "$cd_path" "$phase read-only CD"
    args+=(
      -device virtio-scsi-pci,id=scsi0
      -drive "if=none,id=cdrom,format=raw,media=cdrom,readonly=on,file=$cd_path"
      -device "scsi-cd,drive=cdrom,bootindex=$cd_bootindex"
    )
  fi

  # Safety invariants are enforced immediately before every launch. There is
  # one writable guest disk, no network backend, and no host filesystem or
  # physical-block passthrough option.
  [[ " ${args[*]} " == *" -nic none "* ]] || die "networking was not disabled"
  (( $(printf '%s\n' "${args[@]}" | grep -Fxc "virtio-blk-pci,drive=target,serial=FROSTBITE_VM_TARGET,bootindex=$disk_bootindex") == 1 )) || \
    die "VM does not have exactly one target disk device"
  if printf '%s\n' "${args[@]}" | grep -Eq -- '^-((fsdev|virtfs|net|netdev)|device .*host)|file=/dev/'; then
    die "unsafe host passthrough or network option was generated"
  fi

  qemu-system-x86_64 "${args[@]}" >"$qemu_log" 2>&1 &
  qemu_pid="$!"
  phase_qmp_socket="$qmp_socket"
}

run_phase() {
  local phase="$1"
  local mode="$2"
  local vars_path="$3"
  local cd_path="${4:-}"
  local cd_bootindex="${5:-}"
  start_vm "$phase" "$vars_path" "$cd_path" "$cd_bootindex"
  [[ "$qemu_pid" =~ ^[0-9]+$ ]] || die "could not identify $phase QEMU process"

  local -a driver_args=("$mode" --qmp "$phase_qmp_socket" --evidence "$evidence_dir/$phase")
  if [[ "$mode" == "install" || "$mode" == "audit-boot" ]]; then
    driver_args+=(--serial-log "$evidence_dir/$phase-serial.log")
  fi
  if ! "$driver" "${driver_args[@]}"; then
    if [[ -s "$evidence_dir/$phase-qemu.log" ]]; then
      printf '%s\n' "--- $phase QEMU log ---" >&2
      sed -n '1,160p' "$evidence_dir/$phase-qemu.log" >&2
    fi
    return 1
  fi
}

# Install boot: ISO is read-only and first in firmware boot order. The qcow2 is
# the only writable guest disk.
install -m 0600 "$ovmf_vars_template" "$vm_dir/install-vars.fd"
run_phase install install "$vm_dir/install-vars.fd" "$iso_path" 1
wait_for_qemu_exit install 240

# Boot A: no ISO is attached, and the firmware variables are a fresh template.
# Reaching installed GRUB and firstboot proves EFI/BOOT/BOOTX64.EFI fallback.
install -m 0600 "$ovmf_vars_template" "$vm_dir/boot-a-vars.fd"
run_phase boot-a first-boot "$vm_dir/boot-a-vars.fd"
wait_for_qemu_exit boot-a 240

# Boot B: a tiny, nonbootable audit ISO is attached read-only after the target
# disk. The installed OS still boots from qcow2; tty2 mounts the CD read-only.
xorriso -as mkisofs -quiet -r -J -V FROSTBITE_CI_AUDIT \
  -o "$vm_dir/audit.iso" "$audit_script"
[[ -f "$vm_dir/audit.iso" && ! -L "$vm_dir/audit.iso" ]] || die "audit ISO was not created safely"
install -m 0600 "$ovmf_vars_template" "$vm_dir/boot-b-vars.fd"
run_phase boot-b audit-boot "$vm_dir/boot-b-vars.fd" "$vm_dir/audit.iso" 3
wait_for_qemu_exit boot-b 900

pass_count="$(tr -d '\r' <"$evidence_dir/boot-b-serial.log" | awk '$0 == "FROSTBITE_VM_AUDIT_PASS" { count++ } END { print count+0 }')"
fail_count="$(tr -d '\r' <"$evidence_dir/boot-b-serial.log" | awk '$0 == "FROSTBITE_VM_AUDIT_FAIL" { count++ } END { print count+0 }')"
[[ "$pass_count" == "1" && "$fail_count" == "0" ]] || \
  die "audit serial log did not contain exactly one PASS and zero FAIL markers"

echo "disposable UEFI installer VM acceptance passed"
