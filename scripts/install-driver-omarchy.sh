#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail

driver_commit=20d65c7b0fe6d05ea9734f869b27384a62de5109
driver_url=https://github.com/AJ-dev-i60/t1-touchbar.git
dkms_name=apple-ib-drv
dkms_version=0.1

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
driver_checkout="$repo_root/.t1-work/sources/t1-touchbar"
driver_source="$driver_checkout/apple-ib-drv"
driver_patch="$repo_root/patches/apple-touchbar-s2idle-resume.patch"

say() {
  printf 'T1 driver: %s\n' "$*"
}

fail() {
  printf 'T1 driver: FAILED: %s\n' "$*" >&2
  exit 1
}

model=unknown
[[ -r /sys/class/dmi/id/product_name ]] && model=$(</sys/class/dmi/id/product_name)
case "$model" in
  MacBookPro13,2|MacBookPro13,3|MacBookPro14,2|MacBookPro14,3) ;;
  *) fail "unsupported or unverified host model: $model" ;;
esac

if [[ ${EUID} -ne 0 ]]; then
  command -v git >/dev/null 2>&1 || fail 'git is missing; run setup-omarchy.sh'
  mkdir -p "$repo_root/.t1-work/sources"
  if [[ ! -d $driver_checkout/.git ]]; then
    say 'cloning the pinned kernel driver'
    git clone "$driver_url" "$driver_checkout"
  fi
  if [[ -n $(git -C "$driver_checkout" status --porcelain) ]]; then
    fail "driver checkout has local changes: $driver_checkout"
  fi
  git -C "$driver_checkout" fetch --quiet origin "$driver_commit"
  git -C "$driver_checkout" checkout --quiet --detach "$driver_commit"
  [[ $(git -C "$driver_checkout" rev-parse HEAD) == "$driver_commit" ]] ||
    fail 'driver commit verification failed'
  exec sudo bash "$0" "$@"
fi

[[ -d $driver_source ]] || fail 'pinned driver checkout is missing'
[[ $(git -C "$driver_checkout" rev-parse HEAD) == "$driver_commit" ]] ||
  fail 'driver checkout is not at the pinned commit'
[[ -r $driver_patch ]] || fail 'the s2idle resume patch is missing'
[[ -e /usr/lib/modules/$(uname -r)/build/Makefile ]] ||
  fail 'headers for the running kernel are missing'

# Install the freeze guard before a DKMS module can be auto-loaded.
install -D -m 0644 "$repo_root/config/apple-touchbar.conf" /etc/modprobe.d/apple-touchbar.conf
say 'installed skip_acpi_power=1 before the module build'

dkms_source="/usr/src/${dkms_name}-${dkms_version}"
# `dkms status mod/ver` exits 0 on dkms 3.4.x even when nothing is
# registered, so check the DKMS tree instead.
dkms_registered="/var/lib/dkms/$dkms_name/$dkms_version"
driver_files=(
  Makefile
  apple-ibridge.c
  apple-ibridge.h
  apple-touchbar.c
  hid-ids.h
  dkms.conf
)

# Keep the pinned checkout pristine.  DKMS receives a staged copy with the
# T1 fixed-function driver's normal-resume callback enabled.  s2idle invokes
# .resume rather than .reset_resume because the iBridge remains enumerated.
driver_stage=$(mktemp -d /tmp/t1-driver-stage.XXXXXX)
trap 'rm -rf -- "$driver_stage"' EXIT
for file in "${driver_files[@]}"; do
  install -m 0644 "$driver_source/$file" "$driver_stage/$file"
done
patch --silent -d "$driver_stage" -p1 < "$driver_patch"

source_state=missing

if [[ -d $dkms_source ]]; then
  source_state=patched
  for file in "${driver_files[@]}"; do
    [[ -f $dkms_source/$file ]] || fail "existing DKMS source is incomplete: $dkms_source"
    if ! cmp -s "$driver_stage/$file" "$dkms_source/$file"; then
      source_state=other
      break
    fi
  done

  if [[ $source_state == other ]]; then
    source_state=pristine
    for file in "${driver_files[@]}"; do
      if ! cmp -s "$driver_source/$file" "$dkms_source/$file"; then
        source_state=other
        break
      fi
    done
  fi

  [[ $source_state != other ]] ||
    fail "existing DKMS source has unrecognized local changes: $dkms_source"
fi

if [[ $source_state != patched ]]; then
  if [[ -d $dkms_registered ]]; then
    dkms remove -m "$dkms_name" -v "$dkms_version" --all
  fi
  install -d -m 0755 "$dkms_source"
  for file in "${driver_files[@]}"; do
    install -m 0644 "$driver_stage/$file" "$dkms_source/$file"
  done
  say "installed pinned source plus the s2idle resume patch at $dkms_source"
else
  say 'existing DKMS source includes the pinned s2idle resume patch'
fi

dkms_state=$(dkms status "$dkms_name/$dkms_version" 2>/dev/null || true)
running_kernel=$(uname -r)
module_rebuilt=0
if [[ $dkms_state != *"$running_kernel"*installed* ]]; then
  if [[ ! -d $dkms_registered ]]; then
    dkms add -m "$dkms_name" -v "$dkms_version"
  fi
  dkms build -m "$dkms_name" -v "$dkms_version"
  dkms install -m "$dkms_name" -v "$dkms_version"
  module_rebuilt=1
else
  say 'patched DKMS module is already installed'
fi

if (( module_rebuilt == 1 )) && command -v limine-mkinitcpio >/dev/null 2>&1; then
  limine-mkinitcpio
  say 'rebuilt the Omarchy unified kernel image'
fi

install -D -m 0644 "$repo_root/config/99-ibridge.rules" /etc/udev/rules.d/99-ibridge.rules
install -D -m 0644 "$repo_root/config/apple-touchbar.modules-load.conf" /etc/modules-load.d/apple-touchbar.conf

packaged_rule=/usr/lib/udev/rules.d/39-usbmuxd.rules
if [[ -r $packaged_rule ]] && rg -q '8600' "$packaged_rule"; then
  override_tmp=$(mktemp /tmp/t1-usbmuxd-rule.XXXXXX)
  trap 'rm -f -- "$override_tmp"' EXIT
  sed -e 's/|5ac\/8600\/\*//g' -e 's/5ac\/8600\/\*|//g' "$packaged_rule" >"$override_tmp"
  if rg -q '8600' "$override_tmp"; then
    fail 'could not safely remove only the iBridge match from the usbmuxd rule'
  fi
  install -m 0644 "$override_tmp" /etc/udev/rules.d/39-usbmuxd.rules
  say 'installed local usbmuxd rule override; phone/tablet support is preserved'
fi

udevadm control --reload

ibridge_config=
for path in /sys/bus/usb/devices/*; do
  [[ -r $path/idVendor && -r $path/idProduct && -r $path/bConfigurationValue ]] || continue
  [[ $(<"$path/idVendor") == 05ac && $(<"$path/idProduct") == 8600 ]] || continue
  ibridge_config=$(<"$path/bConfigurationValue")
  break
done

if [[ $ibridge_config == 1 ]]; then
  modprobe apple_ibridge skip_acpi_power=1
  modprobe apple_touchbar
  udevadm trigger --subsystem-match=usb --action=add
  udevadm settle
  say 'loaded the firmware Touch Bar driver live'
elif [[ $ibridge_config == 2 ]]; then
  say 'programmable USB configuration 2 is active; firmware driver is staged for the next handoff'
else
  say 'driver is staged; no production iBridge is currently present'
fi

say 'complete; no reboot or shutdown was performed'
say 'run ./scripts/status.sh as your normal user'
