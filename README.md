# Lenovo 83AR — internal display 120Hz fix

> AMD Phoenix1 / Radeon 780M · BOE **NE160QDM-NY2** panel (2560×1600, 120Hz) · `eDP-1`

Unlocks the panel's native **120Hz** mode on Linux when only 60Hz is offered.

## The problem
The laptop panel's EDID (hardcoded as a raw blob in the BIOS **DSDT**, offset ~17497)
advertises its native 120 Hz mode requiring **553.58 MHz** pixel clock, but the same
EDID declares **max dotclock = 550 MHz**. Newer kernels enforce that ceiling and prune
the 120 Hz mode, so only 60 Hz is offered. The panel and eDP link (HBR2, 4 lanes) are
fully capable of 120 Hz — it's purely a buggy EDID.

## The fix
Feed amdgpu a corrected EDID via `drm.edid_firmware` with:
- max dotclock raised `550 -> 560 MHz` (byte offset 81: `0x37 -> 0x38`)
- DisplayID block + EDID checksums recomputed

## Reapply after an OS reinstall
```
sudo ./install.sh
sudo reboot
```
The script regenerates the patched EDID from the live panel each run (falling back to
the bundled `eDP-1-fixed.bin`), installs it to `/lib/firmware/edid/`, adds the kernel
parameter (GRUB or systemd-boot), embeds it in the initramfs, and regenerates configs.
Idempotent — safe to run more than once.

**Atomic (all-or-nothing).** Both scripts run as a transaction (`txn.sh`): every file
they touch is snapshotted first, and if any step fails — or you Ctrl-C mid-run — the
system is rolled back to its **exact** prior state (bytes, mode, owner, mtime), with
any created files/dirs removed. Nothing is changed, moved, or deleted unless the whole
run succeeds.

## Verify

**Canonical — works in any session (Wayland, Xorg, or a bare TTY).** Reads the
kernel/DRM layer directly, where the fix actually lives, so no compositor is involved:
```
edid-decode < /sys/class/drm/*eDP*/edid | grep dotclock   # fixed -> "max dotclock 560 MHz" (broken: 550)
```

**KDE Wayland:**
```
kscreen-doctor -o | grep -A2 eDP-1     # should list 2560x1600@120.00
```

**Xorg sessions only:**
```
xrandr --query | grep -A1 '^eDP-1 connected'   # the 2560x1600 line should include 120.00
```
> ⚠️ `xrandr` is unreliable under Wayland: it runs against XWayland and reports only
> virtual modes (you'll see 60 Hz and no 120 Hz even when the fix is working). Use the
> canonical check instead unless you're in a real Xorg session.

## Uninstall
```
sudo ./uninstall.sh
sudo reboot
```
Surgically removes the kernel parameter, the initramfs `FILES` entry, and the
`/lib/firmware/edid/*-fixed.bin` blob, then regenerates initramfs + bootloader config.
Idempotent; takes effect after a reboot (panel returns to 60Hz max).

## Files
- `eDP-1-fixed.bin` — the corrected 256-byte EDID (fallback copy)
- `install.sh`      — idempotent, self-healing, transactional installer
- `uninstall.sh`    — surgical, transactional undo
- `txn.sh`          — all-or-nothing transaction helper sourced by both scripts

## Notes
- This does **not** touch the BIOS/firmware; it's an OS-side override, so it must be
  reapplied after wiping the OS disk.
