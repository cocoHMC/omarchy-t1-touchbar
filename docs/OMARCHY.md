# Omarchy step-by-step

This guide has two paths. Most machines need only the driver. The recovery path
is only for a verified `MacBookPro13,2` or `MacBookPro14,3` whose T1 appears as
`05ac:1281`.

No script in this repository reboots or shuts down the Mac.

## 1. Clone and inspect

```bash
git clone https://github.com/cocoHMC/omarchy-t1-touchbar.git
cd omarchy-t1-touchbar
git status --short
less scripts/status.sh
```

Do not pipe an installer from the internet into a root shell. Clone, inspect,
and run the local copy.

## 2. Check the model and USB state

```bash
./scripts/status.sh
```

The important line is one of:

```text
T1 USB state: production iBridge (05ac:8600)
T1 USB state: recovery (05ac:1281)
T1 USB state: not detected
```

If production iBridge is present, continue with the driver-only path and stop
after section 4. If recovery is present, read every recovery section before
running it. If neither is present, do not reset the T1 blindly.

## 3. Install Omarchy/Arch dependencies

```bash
./scripts/setup-omarchy.sh
```

This uses `omarchy pkg add`, so packages remain visible to Omarchy's package
management. It does not edit anything below `/usr/share/omarchy`.

For a non-default kernel, install the matching headers and confirm:

```bash
test -e "/usr/lib/modules/$(uname -r)/build/Makefile" \
  && echo 'kernel headers ready'
```

## 4. Driver-only path

The driver supports the fixed firmware-rendered strip: Esc, display brightness,
keyboard brightness, media, volume, and Fn/F1-F12.

```bash
./scripts/install-driver-omarchy.sh
./scripts/status.sh
```

The installer asks for sudo only for DKMS and system configuration. It:

1. checks out the tested driver commit;
2. installs `skip_acpi_power=1` before adding the module;
3. builds `apple-ib-drv/0.1` through DKMS;
4. installs a configuration-1/no-autosuspend udev rule;
5. installs a modules-load rule;
6. makes a local copy of the packaged usbmuxd rule with only
   `5ac/8600/*` removed;
7. loads the module live if `05ac:8600` is already present.

It never changes the packaged rule in `/usr/lib/udev/rules.d`.

Healthy output contains:

- USB configuration 1;
- at least two physical `05AC:8600` HIDs using `apple-ibridge-hid`;
- at least one virtual `1D6B:0301` HID using `apple-touchbar`;
- a Touch Bar entry in `/proc/bus/input/devices`.

If `05ac:8600` is present but live binding does not occur, save work and do
one normal reboot later. Early boot gives the driver first claim on the HID
interfaces. Do not continue into recovery.

## 5. Recovery prerequisites

Continue only when all are true:

- `cat /sys/class/dmi/id/product_name` is exactly `MacBookPro13,2` or
  `MacBookPro14,3`;
- `lsusb -d 05ac:1281` shows the T1 recovery device;
- `lsusb -d 05ac:8600` does not show production iBridge;
- the computer has reliable AC power and internet access;
- important Linux data is backed up;
- you understand that T1 firmware is being provisioned.

The source-level guard also requires `iBridge1,1/x619ap`. Other T1 MacBook
models need their own reviewed device identity and validation; do not remove the
guard just to make a different model proceed.

## 6. Build the private recovery stack

```bash
./scripts/build-recovery-stack.sh
```

This builds into ignored `.t1-work/` storage:

- pinned `libirecovery` with the `x619ap` device-table entry;
- pinned private `usbmuxd` with T1 restored hotplug support;
- this guarded idevicerestore branch.

It does not replace distro libraries or the system usbmuxd binary. Verify the
result without displaying private data:

```bash
test -x .t1-work/prefix/bin/irecovery
test -x .t1-work/sources/usbmuxd/src/usbmuxd
test -x src/idevicerestore
```

## 7. Obtain Apple's generic EmbeddedOS firmware

```bash
./scripts/fetch-firmware.sh
```

The script downloads Apple's public build 14Y901 package from
`swcdn.apple.com`, verifies the pinned SHA-256, extracts the XAR/PBZX payload,
and validates the expected bundle layout. Apple firmware is not committed to
this repository.

The output should identify:

```text
.t1-work/firmware/usr/standalone/firmware/iBridge1_1Customer.bundle
```

## 8. Understand private storage and backups

The activation run creates:

```text
/var/lib/t1-touchbar/private
/var/lib/t1-touchbar/efi-backups/<UTC timestamp>
```

Directories are mode `0700`; files and raw logs are mode `0600`. Never copy
this directory into the repository or attach it to an issue.

If the same Mac already has a valid
`EFI/APPLE/EMBEDDEDOS/FDRData`, the script preserves and canonicalizes it as
the input to Pass B. Otherwise Pass A obtains FDR data from Apple's service for
this device, then resets only the T1 before Pass B.

## 9. Run the guarded activation

Review the script first:

```bash
less scripts/activate-x619.sh
```

Then run:

```bash
sudo ./scripts/activate-x619.sh --i-understand-this-flashes-the-t1
```

The script performs:

1. model/USB/driver/firmware/permission checks;
2. a root-private backup of existing EFI EmbeddedOS files;
3. optional Pass A to create device-specific FDR data;
4. T1-only `FRST`;
5. Pass B to replay FDR and capture one matching preflight image/ticket pair;
6. a ten-second commit wait and another T1-only `FRST`;
7. exact phase-14 image/ticket replay;
8. a wait of up to 60 seconds for `05ac:8600` to stay present for five
   seconds, then 120 USB samples over 30 seconds;
9. driver binding and HID verification;
10. atomic EFI staging only after stable live `05ac:8600`.

It refuses to stage a phase-14 image that did not boot stably. It never sends a
host system image, never creates host partitions, never calls `SOCW(1)`, and
never reboots.

## 10. Persistence test

The live result is already useful; a reboot is not required to finish the
activation command. When you are ready:

1. save all work;
2. make sure the normal Linux boot entry is selected;
3. perform one ordinary reboot yourself;
4. run `./scripts/status.sh`;
5. verify Esc physically.

Expected: `05ac:8600`, configuration 1, and the same HID topology.

After that, a later normal shutdown and cold start is the stronger persistence
test. Do not reset the T1 during shutdown. EFI should load the staged EmbeddedOS
automatically.

## 11. Rollback

The activation script prints the root-private backup directory it created.
If a later boot leaves the T1 at `05ac:1281`, boot Linux and restore the three
files from that same-Mac backup:

```text
combined.memboot
FDRData
version.plist
```

Copy through temporary filenames on the EFI filesystem, `sync -f` each file,
rename atomically, then `sync` the EFI mount. Never use another Mac's backup.

For a driver-only boot problem, temporarily append this to the Linux kernel
command line:

```text
modprobe.blacklist=apple_ibridge,apple_touchbar
```

Boot, inspect DKMS and udev status, and fix the driver installation without
touching T1 firmware.

## Troubleshooting

### Production iBridge, dark strip

Check in order:

1. `05ac:8600` exists.
2. USB configuration is 1.
3. `/etc/udev/rules.d/39-usbmuxd.rules` has no `8600` match.
4. `apple_ibridge` loaded with `skip_acpi_power=1`.
5. Secure Boot did not reject the DKMS module.
6. physical and virtual HIDs have the expected drivers.

### Phase 11 cannot reach restored

- system usbmuxd must be stopped while the transient private instance owns
  `/run/usbmuxd`;
- the recovery boot args must be exactly
  `rd=md0 -restore IOUSBDeviceController-configuration=standardMuxOnly`;
- Apple's signing and FDR endpoints must be reachable;
- keep logs private and inspect only whitelisted status strings.

### Phase 14 returns to recovery

- do not stage the failed image;
- repeat Pass B as one transaction;
- never mix a ticket and image from different preflights;
- wait ten seconds after Restore Finished;
- use `FRST`, `rd=md0`, and blind `memboot` with `bRequest=1`;
- do not preload iBEC or generate a new post-reset ticket.

See [PROTOCOL.md](PROTOCOL.md) for the reasoning behind these constraints.
