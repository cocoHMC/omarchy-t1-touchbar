#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -Eeuo pipefail
umask 077

acknowledged=0
stage_efi=1
for argument in "$@"; do
  case "$argument" in
    --i-understand-this-flashes-the-t1) acknowledged=1 ;;
    --no-stage-efi) stage_efi=0 ;;
    -h|--help)
      printf 'usage: sudo %s --i-understand-this-flashes-the-t1 [--no-stage-efi]\n' "$0"
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$argument" >&2
      exit 2
      ;;
  esac
done

if (( acknowledged != 1 )); then
  printf 'Refusing to run without --i-understand-this-flashes-the-t1\n' >&2
  exit 2
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
work_dir="$repo_root/.t1-work"
prefix="$work_dir/prefix"
restore_tool="$prefix/bin/idevicerestore"
private_mux="$work_dir/sources/usbmuxd/src/usbmuxd"
bundle="$work_dir/firmware/usr/standalone/firmware/iBridge1_1Customer.bundle"
firmware_dir="$bundle/Contents/Resources"
firmware_version="$bundle/Contents/version.plist"
library_path="$prefix/lib:$prefix/lib64"

private_root=/var/lib/t1-touchbar
run_stamp=$(date -u +%Y%m%dT%H%M%SZ)-$$
run_dir="$private_root/runs/$run_stamp"
backup_dir="$private_root/efi-backups/$run_stamp"
cache_dir="$private_root/cache"

mux_active=0
system_mux_was_active=0

say() {
  printf 'T1 activation: %s\n' "$*"
}

fail() {
  say "FAILED: $*"
  exit 1
}

stop_private_mux() {
  if (( mux_active == 1 )); then
    systemctl stop t1-usbmuxd.service >/dev/null 2>&1 || true
    mux_active=0
  fi
}

cleanup() {
  stop_private_mux
  if (( system_mux_was_active == 1 )); then
    systemctl start usbmuxd.service >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ $EUID -ne 0 ]]; then
  fail 'run through sudo after building the stack as your normal user'
fi

model=unknown
[[ -r /sys/class/dmi/id/product_name ]] && model=$(</sys/class/dmi/id/product_name)
[[ $model == MacBookPro13,2 || $model == MacBookPro14,3 ]] ||
  fail "recovery is guarded for MacBookPro13,2 and MacBookPro14,3, not $model"

for command in lsusb rg plistutil systemd-run systemctl modprobe udevadm findmnt; do
  command -v "$command" >/dev/null 2>&1 || fail "required command is missing: $command"
done
[[ -x $restore_tool ]] || fail 'guarded restore binary is missing; run build-recovery-stack.sh'
[[ -x $private_mux ]] || fail 'private usbmuxd is missing; run build-recovery-stack.sh'
[[ -d $firmware_dir ]] || fail 'Apple firmware is missing; run fetch-firmware.sh'
[[ -f $firmware_version ]] || fail 'Apple firmware version metadata is missing'
[[ -r /etc/modprobe.d/apple-touchbar.conf ]] ||
  fail 'driver safety configuration is missing; run install-driver-omarchy.sh'
rg -q 'skip_acpi_power=1' /etc/modprobe.d/apple-touchbar.conf ||
  fail 'skip_acpi_power=1 is not configured'
[[ -r /etc/udev/rules.d/39-usbmuxd.rules ]] ||
  fail 'local usbmuxd override is missing; run install-driver-omarchy.sh'
if rg -q '^[[:space:]]*SUBSYSTEM=.*8600' /etc/udev/rules.d/39-usbmuxd.rules; then
  fail 'local usbmuxd override still claims 05ac:8600'
fi

lsusb -d 05ac:1281 >/dev/null 2>&1 ||
  fail 'T1 is not in 05ac:1281 recovery mode'
if lsusb -d 05ac:8600 >/dev/null 2>&1; then
  fail 'T1 is already in production mode; recovery is unnecessary'
fi

esp_mount=
for candidate in /boot /boot/efi; do
  [[ -d $candidate ]] || continue
  filesystem=$(findmnt -rn -T "$candidate" -o FSTYPE 2>/dev/null | head -1)
  case "$filesystem" in
    vfat|fat|msdos) esp_mount=$candidate; break ;;
  esac
done
[[ -n $esp_mount ]] || fail 'could not locate a mounted FAT EFI System Partition'
esp_dir="$esp_mount/EFI/APPLE/EMBEDDEDOS"

install -d -o root -g root -m 0700 "$private_root" "$private_root/runs" "$private_root/efi-backups" "$run_dir" "$backup_dir" "$cache_dir"

if [[ -d $esp_dir ]]; then
  cp -a "$esp_dir/." "$backup_dir/"
  find "$backup_dir" -type f -exec chmod 0600 {} +
fi
say "same-Mac EFI backup created at $backup_dir"

fdr_input="$run_dir/FDRData"
fdr_output="$run_dir/FDRData.replayed"
memboot="$run_dir/combined.preflight.memboot"
apticket="$run_dir/preflight.apticket"
mux_log="$run_dir/usbmuxd.private.log"
phase11_log="$run_dir/phase11.private.log"
phase11_runner_log="$run_dir/phase11-runner.private.log"
phase14_log="$run_dir/phase14.private.log"
phase14_runner_log="$run_dir/phase14-runner.private.log"

install -m 0600 /dev/null "$mux_log"

if systemctl is-active --quiet usbmuxd.service 2>/dev/null; then
  system_mux_was_active=1
fi
systemctl stop usbmuxd.service >/dev/null 2>&1 || true

start_private_mux() {
  stop_private_mux
  systemctl reset-failed t1-usbmuxd.service >/dev/null 2>&1 || true
  systemd-run --quiet --collect --unit=t1-usbmuxd --property=Type=simple --property=StandardOutput=null --property=StandardError=null env LD_LIBRARY_PATH="$library_path" "$private_mux" -f -v -U root -l "$mux_log"
  mux_active=1
  for attempt in $(seq 1 80); do
    if systemctl is-active --quiet t1-usbmuxd.service && [[ -S /run/usbmuxd ]]; then
      return 0
    fi
    sleep 0.25
  done
  fail 'private usbmuxd did not start'
}

safe_frst() {
  stop_private_mux
  modprobe acpi_call
  [[ -w /proc/acpi/call ]] || fail 'safe T1 FRST interface is unavailable'
  printf '%s' '\_SB.PCI0.XHC1.RHUB.ASOC.FRST' >/proc/acpi/call
  frst_result=$(tr -cd '[:print:]' </proc/acpi/call)
  [[ $frst_result == 0x0 ]] || fail "T1 FRST returned $frst_result"
  for attempt in $(seq 1 80); do
    if lsusb -d 05ac:1281 >/dev/null 2>&1; then
      say 'safe T1-only FRST completed'
      return 0
    fi
    sleep 0.25
  done
  fail 'T1 did not return to recovery after FRST'
}

check_restore_log() {
  local private_log=$1
  local runner_log=$2
  rg -q 'Status: Restore Finished' "$private_log" "$runner_log" ||
    fail 'restore never reported Restore Finished'
  rg -q 'DONE' "$private_log" "$runner_log" ||
    fail 'restore did not complete cleanly'
  if rg -q 'Unknown data request|Unable to successfully restore|RESTORE FAILED' "$private_log" "$runner_log"; then
    fail 'restore reported an unsupported request or failure'
  fi
}

existing_fdr="$esp_dir/FDRData"
if [[ -f $existing_fdr ]] && plistutil -i "$existing_fdr" -o /dev/null >/dev/null 2>&1; then
  fdr_tmp="$run_dir/.FDRData.new"
  plistutil -f bin -i "$existing_fdr" -o "$fdr_tmp" >/dev/null
  chmod 0600 "$fdr_tmp"
  mv "$fdr_tmp" "$fdr_input"
  say 'preserved valid same-Mac FDRData from EFI; Pass A is not needed'
else
  say 'no valid same-Mac EFI FDRData; starting Pass A'
  fdr_create_log="$run_dir/fdr-create.private.log"
  fdr_create_runner_log="$run_dir/fdr-create-runner.private.log"
  install -m 0600 /dev/null "$fdr_create_log"
  install -m 0600 /dev/null "$fdr_create_runner_log"
  start_private_mux
  set +e
  env -u IDEVICERESTORE_T1_FDR_INPUT -u IDEVICERESTORE_T1_PHASE14 -u IDEVICERESTORE_T1_APTICKET_FILE -u IDEVICERESTORE_MEMBOOT_FILE -u IDEVICERESTORE_T1_PREFLIGHT_MEMBOOT_SAVE -u IDEVICERESTORE_T1_PREFLIGHT_TICKET_SAVE LD_LIBRARY_PATH="$library_path" IDEVICERESTORE_T1_EMBEDDEDOS=1 IDEVICERESTORE_T1_FDR_OUTPUT="$fdr_input" IDEVICERESTORE_RESTORE_BOOT_ARGS='rd=md0 -restore IOUSBDeviceController-configuration=standardMuxOnly' "$restore_tool" -y -P -C "$cache_dir" --variant 'Customer Boot' --logfile="$fdr_create_log" "$firmware_dir" >"$fdr_create_runner_log" 2>&1
  pass_a_status=$?
  set -e
  (( pass_a_status == 0 )) || fail "FDR Pass A exited with status $pass_a_status"
  check_restore_log "$fdr_create_log" "$fdr_create_runner_log"
  [[ -s $fdr_input ]] || fail 'Pass A did not save FDRData'
  chmod 0600 "$fdr_input"
  plistutil -i "$fdr_input" -o /dev/null >/dev/null 2>&1 ||
    fail 'Pass A FDRData is not a valid plist'
  say 'Pass A completed and saved device-specific FDRData'
  sleep 10
  safe_frst
fi

say 'starting Pass B: FDR replay plus matching preflight capture'
install -m 0600 /dev/null "$phase11_log"
install -m 0600 /dev/null "$phase11_runner_log"
start_private_mux
set +e
env -u IDEVICERESTORE_T1_PHASE14 -u IDEVICERESTORE_T1_APTICKET_FILE -u IDEVICERESTORE_MEMBOOT_FILE LD_LIBRARY_PATH="$library_path" IDEVICERESTORE_T1_EMBEDDEDOS=1 IDEVICERESTORE_T1_FDR_INPUT="$fdr_input" IDEVICERESTORE_T1_FDR_OUTPUT="$fdr_output" IDEVICERESTORE_RESTORE_BOOT_ARGS='rd=md0 -restore IOUSBDeviceController-configuration=standardMuxOnly' IDEVICERESTORE_T1_PREFLIGHT_MEMBOOT_SAVE="$memboot" IDEVICERESTORE_T1_PREFLIGHT_TICKET_SAVE="$apticket" "$restore_tool" -y -P -C "$cache_dir" --variant 'Customer Boot' --logfile="$phase11_log" "$firmware_dir" >"$phase11_runner_log" 2>&1
phase11_status=$?
set -e
(( phase11_status == 0 )) || fail "Pass B exited with status $phase11_status"
check_restore_log "$phase11_log" "$phase11_runner_log"
[[ -s $fdr_output ]] || fail 'Pass B did not save replayed FDRData'
[[ -s $memboot ]] || fail 'Pass B did not save the preflight image'
[[ -s $apticket ]] || fail 'Pass B did not save the matching AP ticket'
chmod 0600 "$fdr_output" "$memboot" "$apticket"
plistutil -i "$fdr_output" -o /dev/null >/dev/null 2>&1 ||
  fail 'replayed FDRData is not a valid plist'
cmp -s "$fdr_input" "$fdr_output" ||
  fail 'replayed FDRData differs from its input'

memboot_size=$(stat -c %s "$memboot")
ticket_size=$(stat -c %s "$apticket")
(( memboot_size >= 8 * 1024 * 1024 && memboot_size <= 128 * 1024 * 1024 )) ||
  fail 'captured preflight image has an invalid size'
(( ticket_size > 0 && ticket_size <= 4 * 1024 * 1024 )) ||
  fail 'captured AP ticket has an invalid size'
say "Pass B completed; matching image/ticket captured ($memboot_size and $ticket_size bytes)"

sleep 10
safe_frst

say 'starting exact phase-14 preflight replay'
install -m 0600 /dev/null "$phase14_log"
install -m 0600 /dev/null "$phase14_runner_log"
set +e
env -u IDEVICERESTORE_T1_EMBEDDEDOS -u IDEVICERESTORE_T1_FDR_INPUT -u IDEVICERESTORE_T1_FDR_OUTPUT -u IDEVICERESTORE_T1_PREFLIGHT_MEMBOOT_SAVE -u IDEVICERESTORE_T1_PREFLIGHT_TICKET_SAVE LD_LIBRARY_PATH="$library_path" IDEVICERESTORE_T1_PHASE14=1 IDEVICERESTORE_MEMBOOT_FILE="$memboot" IDEVICERESTORE_T1_APTICKET_FILE="$apticket" IDEVICERESTORE_RESTORE_BOOT_ARGS='rd=md0' "$restore_tool" -y -P -C "$cache_dir" --variant 'Customer Boot' --logfile="$phase14_log" "$firmware_dir" >"$phase14_runner_log" 2>&1
phase14_status=$?
set -e
(( phase14_status == 0 )) || fail "phase 14 exited with status $phase14_status"
rg -q 'memboot dispatched with USB bRequest=1' "$phase14_log" "$phase14_runner_log" ||
  fail 'phase 14 did not use the required bRequest=1 transaction'

# first boot can drop the T1 off usb for a bit (~9s on a 14,3), wait it out
settled_8600=0
for attempt in $(seq 1 240); do
  if lsusb -d 05ac:8600 >/dev/null 2>&1; then
    ((settled_8600 += 1))
    if (( settled_8600 >= 20 )); then
      break
    fi
  else
    settled_8600=0
  fi
  sleep 0.25
done
if (( settled_8600 < 20 )); then
  lsusb -d 05ac:1281 >/dev/null 2>&1 &&
    fail 'T1 returned to recovery instead of production mode'
  fail 'production iBridge did not settle within 60 seconds'
fi

seen_8600=0
seen_1281=0
seen_absent=0
for sample in $(seq 1 120); do
  if lsusb -d 05ac:8600 >/dev/null 2>&1; then
    ((seen_8600 += 1))
  elif lsusb -d 05ac:1281 >/dev/null 2>&1; then
    ((seen_1281 += 1))
  else
    ((seen_absent += 1))
  fi
  sleep 0.25
done
say "USB samples: iBridge=$seen_8600 recovery=$seen_1281 absent=$seen_absent"
lsusb -d 05ac:8600 >/dev/null 2>&1 ||
  fail 'T1 returned to recovery instead of production mode'
(( seen_8600 >= 100 )) ||
  fail 'production iBridge was not stable for 30 seconds'

modprobe apple_ibridge skip_acpi_power=1
modprobe apple_touchbar
udevadm control --reload
udevadm trigger --subsystem-match=usb --action=add
udevadm settle

usb_node=
for candidate in /sys/bus/usb/devices/*; do
  [[ -r $candidate/idVendor && -r $candidate/idProduct ]] || continue
  [[ $(<"$candidate/idVendor") == 05ac && $(<"$candidate/idProduct") == 8600 ]] || continue
  usb_node=$candidate
  break
done
[[ -n $usb_node ]] || fail 'production iBridge has no sysfs node'
[[ $(<"$usb_node/bConfigurationValue") == 1 ]] ||
  fail 'production iBridge is not in USB configuration 1'

physical_bound=0
virtual_bound=0
for hid in /sys/bus/hid/devices/*; do
  [[ -e $hid ]] || continue
  hid_name=${hid##*/}
  driver=unbound
  [[ -L $hid/driver ]] && driver=$(basename "$(readlink -f "$hid/driver")")
  if [[ $hid_name == *05AC:8600* && $driver == apple-ibridge-hid ]]; then
    ((physical_bound += 1))
  fi
  if [[ $hid_name == *1D6B:0301* && $driver == apple-touchbar ]]; then
    ((virtual_bound += 1))
  fi
done
(( physical_bound >= 2 )) ||
  fail 'physical iBridge HIDs did not bind to apple-ibridge-hid'
(( virtual_bound >= 1 )) ||
  fail 'virtual Touch Bar HID did not bind to apple-touchbar'
rg -qi 'Touch Bar|iBridge Virtual HID' /proc/bus/input/devices ||
  fail 'Touch Bar Linux input device was not registered'
say "live driver topology is healthy (physical=$physical_bound virtual=$virtual_bound)"

if (( stage_efi == 0 )); then
  say 'SUCCESS: live Touch Bar is active; EFI staging was skipped by request'
  say "private run data: $run_dir"
  say 'no reboot or shutdown was performed'
  exit 0
fi

if [[ ! -t 0 ]]; then
  fail 'EFI staging requires an interactive physical confirmation; rerun with --no-stage-efi if remote'
fi
printf '\nConfirm the strip is visibly lit and shows an Esc key.\n'
read -r -p 'Type STAGE to install this exact proven image on EFI: ' confirmation
[[ $confirmation == STAGE ]] || fail 'physical confirmation was not given; EFI was not changed'

install -d -o root -g root -m 0700 "$esp_dir"
install -m 0600 "$memboot" "$esp_dir/.combined.memboot.new"
sync -f "$esp_dir/.combined.memboot.new"
mv -f "$esp_dir/.combined.memboot.new" "$esp_dir/combined.memboot"

install -m 0600 "$fdr_input" "$esp_dir/.FDRData.new"
sync -f "$esp_dir/.FDRData.new"
mv -f "$esp_dir/.FDRData.new" "$esp_dir/FDRData"

install -m 0600 "$firmware_version" "$esp_dir/.version.plist.new"
sync -f "$esp_dir/.version.plist.new"
mv -f "$esp_dir/.version.plist.new" "$esp_dir/version.plist"
sync "$esp_mount"

cmp -s "$memboot" "$esp_dir/combined.memboot" ||
  fail 'EFI combined.memboot verification failed'
cmp -s "$fdr_input" "$esp_dir/FDRData" ||
  fail 'EFI FDRData verification failed'
cmp -s "$firmware_version" "$esp_dir/version.plist" ||
  fail 'EFI version.plist verification failed'

say 'SUCCESS: live Touch Bar is active and the exact proven files are staged on EFI'
say "private run data: $run_dir"
say "pre-change EFI backup: $backup_dir"
say 'no reboot or shutdown was performed'
