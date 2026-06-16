#!/usr/bin/env bash
# Undo the eDP 120Hz fix installed by install.sh (Lenovo 83AR).
#
# Removes the drm.edid_firmware kernel parameter, the initramfs FILES entry, and the
# /lib/firmware/edid/<conn>-fixed.bin override, then regenerates initramfs + bootloader
# config. Surgical and idempotent; takes effect after a reboot.
#
# Transactional: every file touched is snapshotted first; if ANY step fails (or you
# Ctrl-C), the system is rolled back to its exact prior state — nothing is changed,
# moved, or deleted unless the whole run succeeds. Destructive final cleanup (removing
# the now-empty edid dir and any leftover *.bak.120hz backups) runs only on success.
#
# Usage:  sudo ./uninstall.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
. "$HERE/txn.sh"

CONN_DIR="$(ls -d /sys/class/drm/*eDP*/ 2>/dev/null | head -1 || true)"
CONN="$(basename "${CONN_DIR%/}" 2>/dev/null | sed 's/^card[0-9]*-//')"
CONN="${CONN:-eDP-1}"
FW=/lib/firmware/edid/${CONN}-fixed.bin
PARAM="drm.edid_firmware=${CONN}:edid/${CONN}-fixed.bin"
esc() { printf '%s' "$1" | sed 's/[.[\*^$/]/\\&/g'; }
ESC_PARAM="$(esc "$PARAM")"; ESC_FW="$(esc "$FW")"
echo ">> removing override for $CONN ($PARAM)"

txn_begin   # from here on, all changes are atomic

# snapshot everything we may modify/remove/regenerate
if [ -e "$FW" ]; then txn_guard "$FW"; fi
if [ -f /etc/default/grub ]; then txn_guard /etc/default/grub; fi
if [ -f /etc/mkinitcpio.conf ]; then txn_guard /etc/mkinitcpio.conf; fi
if [ -f /etc/dracut.conf.d/edid-120hz.conf ]; then txn_guard /etc/dracut.conf.d/edid-120hz.conf; fi
if [ -f /boot/grub/grub.cfg ]; then txn_guard /boot/grub/grub.cfg; fi
if [ -d /boot/loader/entries ]; then
  for e in /boot/loader/entries/*.conf; do
    if [ -e "$e" ]; then txn_guard "$e"; fi
  done
fi
for img in /boot/initramfs-*.img; do
  if [ -e "$img" ]; then txn_guard "$img"; fi
done

# --- strip kernel parameter ---------------------------------------------------
if [ -f /etc/default/grub ]; then
  sed -i "s/ *${ESC_PARAM}//g" /etc/default/grub
  sed -i "/^GRUB_CMDLINE_LINUX/ s/  */ /g; /^GRUB_CMDLINE_LINUX/ s/ \([\"']\)/\1/g" /etc/default/grub
  echo ">> grub: $(grep ^GRUB_CMDLINE_LINUX_DEFAULT /etc/default/grub)"
fi
if [ -d /boot/loader/entries ]; then
  for e in /boot/loader/entries/*.conf; do
    if [ -e "$e" ]; then sed -i "s/ *${ESC_PARAM}//g" "$e"; fi
  done
fi

# --- strip initramfs FILES entry ----------------------------------------------
if [ -f /etc/mkinitcpio.conf ]; then
  sed -i "s#${ESC_FW}##g" /etc/mkinitcpio.conf
  sed -i "/^FILES=/ s/  */ /g; /^FILES=/ s/( /(/; /^FILES=/ s/ )/)/" /etc/mkinitcpio.conf
  echo ">> mkinitcpio: $(grep ^FILES= /etc/mkinitcpio.conf)"
fi
rm -f /etc/dracut.conf.d/edid-120hz.conf

# --- remove the override blob -------------------------------------------------
rm -f "$FW"

# --- regenerate ---------------------------------------------------------------
if [ -f /etc/mkinitcpio.conf ]; then
  mkinitcpio -P
elif command -v dracut >/dev/null; then
  dracut -f
fi
if [ -f /boot/grub/grub.cfg ]; then grub-mkconfig -o /boot/grub/grub.cfg; fi

# destructive tidy-up — only after everything above succeeded
txn_on_commit "rmdir '$(dirname "$FW")' 2>/dev/null || true"
txn_on_commit "rm -f /etc/default/grub.bak.120hz /etc/mkinitcpio.conf.bak.120hz"

txn_commit
echo
echo ">> DONE. Reboot to drop back to 60Hz; the override is fully removed."
