# Omarchy T1 Touch Bar recovery

Linux-only activation and driver setup for the Apple T1 Touch Bar in the
2016/2017 Intel MacBook Pro, with an exact, guarded recovery path for
`MacBookPro13,2` or `MacBookPro14,3` with the `iBridge1,1` / `x619ap` T1.

This repository exists because installing a Linux driver is only half of the
problem. The driver can bind only after the T1 has passed Apple secure boot and
enumerated as production iBridge USB device `05ac:8600`. A T1 stuck at recovery
device `05ac:1281` needs its own EmbeddedOS provisioned and booted first.

## The simple mental model

There are two computers inside a Touch Bar MacBook Pro:

1. The Intel Mac runs the main operating system. On the tested machine that is
   Omarchy/Arch Linux—not macOS, a virtual machine, or a hidden second desktop.
2. The Apple T1 coprocessor runs a small Apple EmbeddedOS. It manages hardware
   including the Touch Bar and communicates with Linux over an internal USB
   connection.

That is “two operating systems” only in the same sense that a laptop also has
firmware inside its keyboard, SSD, or Wi-Fi controller. There is one normal
computer and desktop: Linux. The T1's EmbeddedOS is appliance firmware on a
separate chip; it cannot run Mac applications or provide a macOS desktop.

In the stock strip mode, T1 firmware draws the controls. In custom-display
mode, Linux sends pixels to the T1 panel and reads finger coordinates back:

```text
finger -> T1 touch hardware -> Linux touch daemon -> Hyprland/Omarchy action
Linux renderer -> tiny DRM display -> T1 panel -> pixels on the Touch Bar
```

The T1 firmware is still required in custom mode because it boots and exposes
the hardware. Linux then owns the visible layout and button behavior.

> [!CAUTION]
> The recovery path flashes the T1 coprocessor. It is not a host OS installer,
> but an incorrect implementation can still leave the Touch Bar and iBridge
> camera unavailable. Back up first, keep all personalized artifacts private,
> and never use another Mac's FDR data, AP ticket, or `combined.memboot`.

## Status

The complete live path was verified on:

- MacBookPro13,2 (2016 13-inch Touch Bar)
- Apple T1 `iBridge1,1`, hardware model `x619ap`
- Omarchy/Arch Linux with a Linux 7.x kernel
- USB recovery `05ac:1281` to stable production iBridge `05ac:8600`
- physical HID interfaces bound to `apple-ibridge-hid`
- virtual Touch Bar HID bound to `apple-touchbar`
- the exact live-proven personalized files staged at
  `EFI/APPLE/EMBEDDEDOS`

One MacBookPro14,3 (2017 15-inch, same `x619ap` T1 and `RHUB.ASOC` FRST
method) has been activated on CachyOS with Linux 7.2. Pass A, Pass B and the
phase-14 replay completed, the T1 settled as `05ac:8600`, and it came back in
production mode after a reboot. During its first EmbeddedOS boot the T1 was
absent for about 9 seconds, which failed the stability check before the script
waited for `05ac:8600` to settle, so EFI staging on that run was done by hand.
The settle wait and the script's own EFI staging have not yet run end to end on
a MacBookPro14,3.

The live bar works, including the firmware Esc key and the Fn/function-key
layout. The shipped configuration defaults to visible F1-F12 (`fnmode=2`),
with Fn temporarily revealing the special brightness/media controls. T1
firmware persistence and the programmable service have survived repeated
normal reboots on the originating machine. Lid-resume protection remains an
explicit hardware test after changes to the pre-sleep handoff; do not report a
new sleep sequence as proven until the physical OLED has passed that test.

## Choose the right path

Run the read-only status check:

```bash
./scripts/status.sh
```

| USB state | What to do |
|---|---|
| `05ac:8600` | Install the kernel driver. Do not run T1 recovery. |
| `05ac:1281` | Use the guarded `x619ap` recovery workflow after reading the guide. |
| neither | Diagnose power/enumeration and preserve EFI files; do not guess. |

## Omarchy quick start: driver-only path

Review the scripts, then:

```bash
./scripts/setup-omarchy.sh
./scripts/install-driver-omarchy.sh
./scripts/status.sh
```

The driver installer:

- pins the tested kernel-7-compatible T1 driver source;
- installs it with DKMS and enables its existing restore routine for normal
  `s2idle` resume;
- writes `skip_acpi_power=1` before the module can load;
- forces iBridge USB configuration 1 and disables autosuspend;
- removes only the `05ac:8600` alternative from a local usbmuxd udev override;
- never reboots the computer.

Never set `skip_acpi_power=0`. The resulting `ASOC.SOCW(1)` call can hard-freeze
these Macs.

## Omarchy expert path: T1 stuck in recovery

Read [the complete Omarchy runbook](docs/OMARCHY.md) first. The high-level
sequence is:

```bash
./scripts/setup-omarchy.sh
./scripts/build-recovery-stack.sh
./scripts/fetch-firmware.sh
./scripts/install-driver-omarchy.sh
sudo ./scripts/activate-x619.sh --i-understand-this-flashes-the-t1
```

The activation script is intentionally restricted to `MacBookPro13,2` or
`MacBookPro14,3`, `iBridge1,1`, `x619ap`, and USB recovery ID `05ac:1281`. It
stores raw logs, FDR data, tickets, and personalized images below root-only
`/var/lib/t1-touchbar`; it does not print their contents; and it does not reboot
the host.

## The silver bullet

The decisive finding was not a magic driver flag. It was replaying one exact
device-personalization transaction across Apple's two boot phases:

1. Complete the guarded EmbeddedOS phase-11 restore and FDR commit.
2. Capture the personalized `OSRamdisk + KernelCache + DeviceTree + SEP` bare
   concatenation and AP ticket from that same preflight/TSS response.
3. Wait at least ten seconds, stop the private usbmuxd, and reset only the T1
   with `\_SB.PCI0.XHC1.RHUB.ASOC.FRST`.
4. In phase 14, reuse the active recovery USB handle, disable auto-boot, upload
   the saved ticket and exact saved image, set `boot-args=rd=md0`, and dispatch
   blind `memboot` with USB `bRequest=1`.

Fresh post-reset tickets repeatedly failed. Reopening the already-active
recovery handle also made the phase-14 code silently send nothing. Reusing the
active handle and replaying the matching preflight pair produced stable
`05ac:8600`.

The precise protocol and failed approaches are documented in
[docs/PROTOCOL.md](docs/PROTOCOL.md).

## Persistence

Apple EFI expects these three machine-specific files:

```text
EFI/APPLE/EMBEDDEDOS/combined.memboot
EFI/APPLE/EMBEDDEDOS/FDRData
EFI/APPLE/EMBEDDEDOS/version.plist
```

The activation script stages only the exact image that already booted live and
passed a 30-second USB stability check. It creates a root-private backup first
and compares every staged file byte-for-byte. It never initiates the reboot.

When convenient, save work and perform one normal reboot as the persistence
test. A later full shutdown/cold start is the second, stronger test. Recovery
instructions are in [docs/OMARCHY.md](docs/OMARCHY.md).

## Touch ID and a programmable bar

- **Touch ID:** available through the separate official
  [T1Bridge packages](https://github.com/standardagents/t1bridge), using this
  Mac's preserved calibration data and standard fprintd tools. See
  [the updated Touch ID notes](docs/TOUCH-ID.md) and
  [the custom renderer adapter](docs/T1BRIDGE-CUSTOM-BAR.md). Keep password
  authentication; upstream system suspend/resume support is still incomplete.
- **Custom graphics and touch:** feasible today through T1 USB configuration 2,
  `appletbdrm`, a config-selection driver, and a userspace renderer/touch
  daemon. A compiled Omarchy overlay now provides direct workspace actions,
  occupied/current-workspace visuals, and automatic app-specific decks for
  ChatGPT/Codex, browsers, terminals, VS Code, Omarchy Neovim/LazyVim, Files,
  communications, writing apps, document readers, media and unrecognized apps.
  Its Tokyo Night Prism interface uses rounded pills, restrained accents and
  native modifier-chord actions.
  A pending/committed USB transaction fence disables new contacts until the
  matching hit map is safe to publish through rapid focus/Fn changes or USB
  errors; it deliberately does not claim physical panel pixel readback. Its
  tap-to-toggle Fn watcher filters false
  up/down pulses that previously
  flooded the DRM driver, and its T1 completion-queue drain prevents repeated
  frames from wedging the bulk endpoint. The guarded live path and the
  Omarchy-specific persistent systemd installer have both been validated on the
  originating MacBookPro13,2, including repeated firmware-to-custom service
  restarts. The installer forces `s2idle` for lid-close sleep because Apple
  firmware does not restore the T1 display pipeline after deep S3; entering
  deep S3 leaves the OLED black until a reboot. Before `s2idle`, the service
  parks the T1 in Apple firmware configuration 1 so the patched stock driver
  can suspend and relight the OLED; after wake, one serialized action returns
  it to the programmable layout. A physical-lid watcher owns the low-level lid
  switch and issues one suspend per real close, avoiding logind's 30-second
  re-suspend when Apple ACPI misses the matching open event. The custom OLED
  also uses a true-black low-power palette and blanks after two idle minutes;
  keyboard, app-context, or first-touch activity restores it without firing a
  hidden action.
  The installer also protects the MacBookPro13,2 Alpine Ridge PCI trees from
  the long resume timeout and forces its BCM43602 driver during early boot.
  The persistent service remains opt-in and includes a one-command
  firmware-strip rollback. See
  [docs/CUSTOM-BAR.md](docs/CUSTOM-BAR.md), [the layout and previews](custom-bar/README.md),
  and the [custom action helper](custom-bar/touchbar-action.sh).

## Privacy and safety

Never commit, upload, paste, or attach any of the following:

- `FDRData` or an FDR plist;
- AP/SEP tickets, SHSH data, or TSS responses;
- `combined.memboot` or other personalized IMG4 objects;
- raw restore, usbmuxd, iBoot, or recovery logs;
- serials, ECIDs, chip IDs, AP nonces, or SEP nonces;
- Apple firmware packages or extracted Apple firmware.

This repository contains source, guarded tooling, patches, and official download
instructions only. See [SECURITY.md](SECURITY.md) before reporting a problem.

## Provenance

This branch is based on `libimobiledevice/idevicerestore` commit
`540c352c4c44896f7415abef87a166e8bbaea9b0`. It builds on:

- [libimobiledevice/idevicerestore](https://github.com/libimobiledevice/idevicerestore)
- [AJ-dev-i60/t1-touchbar](https://github.com/AJ-dev-i60/t1-touchbar)
- [t2linux/apple-ib-drv](https://github.com/t2linux/apple-ib-drv)
- [xeeban/macbook-t1-linux](https://github.com/xeeban/macbook-t1-linux)
- [the independently verified Linux-only T1 activation runbook](https://gist.github.com/tigercosmos/ecbfe1fc20b7303c1808d3ab74af1f5b)

This is independent community work and is not supported by Apple,
libimobiledevice, Omarchy, or the linked driver authors.

## License

The idevicerestore source retains its upstream LGPL terms in [COPYING](COPYING).
Files that patch GPL projects carry their own SPDX identifiers. Apple firmware
and device-personalized artifacts are not distributed.
