#!/usr/bin/env bash
# Install the BOE NE160QDM-NY2 eDP 120Hz fix (Lenovo 83AR).
#
# The panel's EDID (hardcoded in the BIOS DSDT) advertises its native 120Hz mode
# needing 553.58 MHz pixel clock but declares max dotclock = 550 MHz, so the kernel
# prunes 120Hz. This installs a corrected EDID override (dotclock raised to 560 MHz,
# checksums fixed) via drm.edid_firmware.
#
# Transactional: every file touched is snapshotted first; if ANY step fails (or you
# Ctrl-C), the system is rolled back to its exact prior state and nothing is left
# changed. Self-healing: regenerates the patched EDID from the live panel each run,
# falling back to the bundled eDP-1-fixed.bin.
#
# Usage:  sudo ./install.sh        (idempotent)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
. "$HERE/txn.sh"

CONN_DIR="$(ls -d /sys/class/drm/*eDP*/ 2>/dev/null | head -1 || true)"
CONN="$(basename "${CONN_DIR%/}" 2>/dev/null | sed 's/^card[0-9]*-//')"
CONN="${CONN:-eDP-1}"
FW=/lib/firmware/edid/${CONN}-fixed.bin
PARAM="drm.edid_firmware=${CONN}:edid/${CONN}-fixed.bin"
echo ">> connector: $CONN   ->   $FW"

txn_begin   # from here on, all changes are atomic

# snapshot everything we may modify/create/regenerate
txn_track "$FW"
txn_mkdir "$(dirname "$FW")"
if [ -f /etc/default/grub ]; then txn_guard /etc/default/grub; fi
if [ -f /etc/mkinitcpio.conf ]; then txn_guard /etc/mkinitcpio.conf; fi
if [ -f /boot/grub/grub.cfg ]; then txn_track /boot/grub/grub.cfg; fi
if command -v dracut >/dev/null; then txn_track /etc/dracut.conf.d/edid-120hz.conf; fi
if [ -d /boot/loader/entries ]; then
  for e in /boot/loader/entries/*.conf; do
    if [ -e "$e" ]; then txn_guard "$e"; fi
  done
fi
for img in /boot/initramfs-*.img; do
  if [ -e "$img" ]; then txn_guard "$img"; fi
done

# --- build the corrected EDID -------------------------------------------------
python3 - "$CONN_DIR" "$HERE/eDP-1-fixed.bin" "$FW" << 'PY'
import sys, os
conn_dir, bundled, out = sys.argv[1], sys.argv[2], sys.argv[3]

def patch(d):
    d = bytearray(d)
    if len(d) < 128: raise ValueError("edid too short")
    maxclk = 0  # highest detailed-timing pixel clock, 10kHz units
    for off in (54, 72, 90, 108):
        if d[off] or d[off+1]:
            maxclk = max(maxclk, d[off] | (d[off+1] << 8))
    if len(d) >= 256 and d[128] == 0x70:                 # DisplayID extension
        b1, L = 128, d[130]; i = b1 + 5; end = min(b1 + 3 + L, 255)
        while i + 2 < end:
            tag, dl = d[i], d[i+2]
            if tag == 0x03:                              # Type 1 detailed timings
                p = i + 3
                while p + 3 <= i + 3 + dl and p + 2 < len(d):
                    maxclk = max(maxclk, d[p] | (d[p+1] << 8) | (d[p+2] << 16))
                    p += 20
            i += 3 + dl
    need_mhz = (maxclk * 10000) / 1e6
    for off in (54, 72, 90, 108):                        # Display Range Limits (0xFD)
        if d[off:off+3] == b'\x00\x00\x00' and d[off+3] == 0xFD:
            cur = d[off+9] * 10
            newmhz = max(cur, int(need_mhz) + 10)
            d[off+9] = (newmhz // 10) & 0xff
            break
    d[127] = (256 - (sum(d[0:127]) & 0xff)) & 0xff
    if len(d) >= 256 and d[128] == 0x70:
        b1, L = 128, d[130]; ck = b1 + 3 + L
        if ck < 255:
            d[ck] = (256 - (sum(d[b1+1:ck]) & 0xff)) & 0xff
        d[255] = (256 - (sum(d[128:255]) & 0xff)) & 0xff
    return bytes(d)

src = None
edid_path = os.path.join(conn_dir, "edid") if conn_dir else ""
if edid_path and os.path.exists(edid_path):
    raw = open(edid_path, "rb").read()
    if len(raw) >= 128:
        src = raw; print("   using LIVE panel EDID")
if src is None:
    src = open(bundled, "rb").read(); print("   using bundled EDID")

tmp = out + ".tmp"                                       # write atomically into place
open(tmp, "wb").write(patch(src))
os.chmod(tmp, 0o644)
os.replace(tmp, out)
print(f"   wrote {os.path.getsize(out)} bytes -> {out}")
PY

# --- kernel parameter ---------------------------------------------------------
if [ -f /etc/default/grub ]; then
  if ! grep -q "drm.edid_firmware=${CONN}" /etc/default/grub; then
    sed -i "s#^\(GRUB_CMDLINE_LINUX_DEFAULT=.[^\"']*\)\([\"']\)#\1 ${PARAM}\2#" /etc/default/grub
  fi
  echo ">> grub: $(grep ^GRUB_CMDLINE_LINUX_DEFAULT /etc/default/grub)"
elif [ -d /boot/loader/entries ]; then
  for e in /boot/loader/entries/*.conf; do
    if [ -e "$e" ] && ! grep -q "drm.edid_firmware=${CONN}" "$e"; then
      sed -i "/^options /s#\$# ${PARAM}#" "$e"
    fi
  done
  echo ">> systemd-boot entries updated"
fi

# --- include EDID in the initramfs + regenerate -------------------------------
if [ -f /etc/mkinitcpio.conf ]; then
  if ! grep -q "${CONN}-fixed.bin" /etc/mkinitcpio.conf; then
    sed -i "s#^FILES=(#FILES=(${FW} #" /etc/mkinitcpio.conf
  fi
  mkinitcpio -P
elif command -v dracut >/dev/null; then
  printf 'install_items+=" %s "\n' "$FW" > /etc/dracut.conf.d/edid-120hz.conf
  dracut -f
fi
if [ -f /boot/grub/grub.cfg ]; then grub-mkconfig -o /boot/grub/grub.cfg; fi

txn_commit   # success: keep all changes
echo
echo ">> DONE. Reboot, then verify:  edid-decode < /sys/class/drm/*eDP*/edid | grep dotclock  (-> 560 MHz)"
