#!/usr/bin/env bash
# Writes the built image to an SD card, with guard rails and verification.
#
# Usage: ./flash.sh /dev/sdX [image] [--no-verify]
#
# - Writes with O_DIRECT so a flaky reader fails immediately instead of at the end.
# - Reads the card back (also uncached) and compares it with the image.
set -euo pipefail
cd "$(dirname "$0")"

die() { echo "ERROR: $*" >&2; exit 1; }

DEV=""
IMG="out/bpi-m5-nixos.img"
VERIFY=1
pos=0
for arg in "$@"; do
  case "$arg" in
    --no-verify) VERIFY=0 ;;
    -*) die "Unknown option: $arg" ;;
    *)
      pos=$((pos + 1))
      if [ "$pos" -eq 1 ]; then DEV="$arg"; else IMG="$arg"; fi
      ;;
  esac
done

if [ -z "$DEV" ]; then
  echo "Usage: $0 /dev/sdX [image] [--no-verify]"
  echo
  echo "Your disks right now (the SD card is the one with the right size):"
  lsblk -d -o NAME,SIZE,MODEL,TRAN,RM,MOUNTPOINTS
  exit 1
fi

[ -f "$IMG" ] || die "Image not found: $IMG  (run ./build.sh first)"
[ -b "$DEV" ] || die "$DEV is not a block device."
[ "$(lsblk -ndo TYPE "$DEV")" = "disk" ] \
  || die "$DEV is a partition. Give the whole disk, e.g. /dev/sdb, not /dev/sdb1."

img_size="$(stat -c%s "$IMG")"
dev_size="$(lsblk -bndo SIZE "$DEV")"

# A reader with no card (or a failing one) reports 0 bytes.
[ "${dev_size:-0}" -gt 0 ] \
  || die "$DEV reports 0 bytes. The reader can't see the card. Reseat it or try another reader/port."
[ "$dev_size" -ge "$img_size" ] \
  || die "$DEV is smaller ($dev_size bytes) than the image ($img_size bytes)."

# Refuse anything with mounted partitions. This also protects your system disk.
mounted="$(lsblk -nr -o MOUNTPOINT "$DEV" | grep -v '^$' || true)"
if [ -n "$mounted" ]; then
  echo "ERROR: $DEV has mounted partitions:" >&2
  echo "$mounted" >&2
  echo "If this really is your SD card, unmount them first:  sudo umount ${DEV}*" >&2
  echo "If it is NOT your SD card, good thing this check exists." >&2
  exit 1
fi

echo "About to ERASE EVERYTHING on this device:"
echo
lsblk -d -o NAME,SIZE,MODEL,TRAN,RM "$DEV"
if [ "$(lsblk -ndo RM "$DEV")" != "1" ]; then
  echo
  echo "WARNING: this device is not flagged as removable. Double-check it is your SD card."
fi
echo
echo "Image: $IMG ($(du -h "$IMG" | cut -f1))"
echo
read -r -p "Type the device path again to confirm ($DEV): " answer
[ "$answer" = "$DEV" ] || die "Confirmation did not match. Nothing was written."

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
  $SUDO -v  # ask for the password now, not in the middle of the flow
fi

echo
echo "==> Writing (direct, uncached: slower, but errors show up right away)..."
if ! $SUDO dd if="$IMG" of="$DEV" bs=4M oflag=direct conv=fsync status=progress; then
  echo >&2
  echo "ERROR: the write failed. The card now holds a partial image; do not boot it." >&2
  echo "Check 'sudo dmesg | tail -30'. A line like 'USB disconnect' means the reader" >&2
  echo "dropped out: try another USB port (direct on the PC, not a hub) or another reader." >&2
  exit 1
fi
sync
$SUDO blockdev --flushbufs "$DEV" || true

if [ "$VERIFY" -eq 1 ]; then
  echo
  echo "==> Verifying: reading the card back and comparing with the image..."
  if $SUDO dd if="$DEV" bs=4M iflag=direct,count_bytes count="$img_size" status=none \
       | cmp -n "$img_size" - "$IMG"; then
    echo "    MATCH - the card holds an exact copy of the image."
  else
    echo >&2
    echo "ERROR: verification FAILED. The card does not match the image." >&2
    echo "Do not boot it. Retry with another port/reader, or another card." >&2
    exit 1
  fi
fi

echo
echo "==> Done. You can remove the card now."
echo "    Put it in the BPI-M5, connect Ethernet, and power on."
echo "    The first boot expands the root partition, so give it a minute or two."
