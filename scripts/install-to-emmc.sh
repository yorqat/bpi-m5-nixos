# install-to-emmc: install this flake's NixOS onto the BPI-M5's eMMC.
# Run it on the board while it is booted from the SD card:
#
#     sudo nix run .#install-to-emmc              # auto-detects the eMMC
#     sudo nix run .#install-to-emmc -- /dev/mmcblk0   # or name it yourself
#
# The flake wraps this file (flake.nix, 'install-to-emmc') and provides the tools
# plus FLAKE_REF and HOST_NAME. It is not meant to be executed directly.

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root:  sudo nix run .#install-to-emmc"
: "${FLAKE_REF:?}" "${HOST_NAME:?}"

ROOT=/mnt/emmc-install
SWAPFILE="$ROOT/.install-swapfile"

# Real eMMC chips report type "MMC"; SD cards report "SD". Skip the hardware
# boot/rpmb partitions that show up as separate mmcblkNbootM devices.
find_emmc() {
  local dev name
  for dev in /sys/block/mmcblk*; do
    [ -e "$dev/device/type" ] || continue
    name="${dev##*/}"
    case "$name" in *boot* | *rpmb) continue ;; esac
    if [ "$(cat "$dev/device/type")" = "MMC" ]; then
      echo "/dev/$name"
    fi
  done
}

# ---- 1. Work out where we are and where we're going -------------------------
if [ $# -ge 1 ]; then
  EMMC="$1"
else
  mapfile -t found < <(find_emmc)
  if [ "${#found[@]}" -ne 1 ]; then
    lsblk -d -o NAME,SIZE,MODEL,TRAN,RM
    die "Found ${#found[@]} eMMC devices, need exactly 1. Pass it explicitly:  sudo nix run .#install-to-emmc -- /dev/mmcblkX"
  fi
  EMMC="${found[0]}"
fi

[ -b "$EMMC" ] || die "$EMMC is not a block device."
[ "$(lsblk -ndo TYPE "$EMMC")" = "disk" ] || die "$EMMC is a partition; give the whole disk."

root_src="$(findmnt -no SOURCE /)" || die "Can't tell what / is mounted from."
[ -b "$root_src" ] || die "Can't tell which device the running system is on (got: $root_src)."
pk="$(lsblk -no PKNAME "$root_src" | head -n1)"
[ -n "$pk" ] || die "Can't find the disk that holds $root_src."
BOOT_DEV="/dev/$pk"

[ "$BOOT_DEV" != "$EMMC" ] || die "You are running from $EMMC itself. Boot from the SD card to install onto the eMMC."

if lsblk -nr -o MOUNTPOINT "$EMMC" | grep -q .; then
  die "$EMMC has mounted partitions. Unmount them first."
fi

getent hosts cache.nixos.org >/dev/null || die "No network (can't resolve cache.nixos.org). Plug in Ethernet and try again."

echo "Running from : $BOOT_DEV"
echo "Installing to: $EMMC"
echo
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL "$EMMC"
echo
echo "Everything on $EMMC will be ERASED (any Android/Linux already there included)."
read -r -p "Type the device path to confirm ($EMMC): " answer
[ "$answer" = "$EMMC" ] || die "Confirmation did not match. Nothing was changed."

# ---- 2. Partition and format the eMMC ---------------------------------------
echo
echo "==> Partitioning $EMMC"
wipefs -a "$EMMC" >/dev/null
# Clear the first 8 MiB (old bootloader etc.). Our partition starts right after.
dd if=/dev/zero of="$EMMC" bs=1M count=8 conv=fsync status=none
printf 'label: dos\nstart=16384, type=83, bootable\n' | sfdisk --quiet "$EMMC"
udevadm settle || true

case "$EMMC" in
  *[0-9]) PART="${EMMC}p1" ;;
  *) PART="${EMMC}1" ;;
esac
for _ in $(seq 1 20); do
  [ -b "$PART" ] && break
  sleep 0.5
done
[ -b "$PART" ] || die "Partition $PART did not appear."

wipefs -a "$PART" >/dev/null
mkfs.ext4 -q -F -L nixos "$PART"

# ---- 3. Copy the bootloader from the SD card we booted from -----------------
# Same layout the image uses: 440 bytes of boot code at the very start, and the
# signed U-Boot from sector 1. Done AFTER partitioning so the table is kept.
echo "==> Copying the bootloader from $BOOT_DEV to $EMMC"
dd if="$BOOT_DEV" of="$EMMC" bs=512 skip=1 seek=1 count=8191 conv=fsync,notrunc status=none
dd if="$BOOT_DEV" of="$EMMC" bs=1 count=440 conv=fsync,notrunc status=none
blockdev --flushbufs "$BOOT_DEV" "$EMMC" || true

echo "==> Verifying the bootloader copy"
cmp <(dd if="$BOOT_DEV" bs=512 skip=1 count=8191 iflag=direct status=none) \
    <(dd if="$EMMC" bs=512 skip=1 count=8191 iflag=direct status=none) \
  || die "Bootloader verification failed (sectors 1+). Do not reboot into the eMMC; rerun this."
cmp -n 440 <(dd if="$BOOT_DEV" bs=512 count=1 iflag=direct status=none) \
           <(dd if="$EMMC" bs=512 count=1 iflag=direct status=none) \
  || die "Bootloader verification failed (boot code). Do not reboot into the eMMC; rerun this."

# ---- 4. Install NixOS from the flake ----------------------------------------
mkdir -p "$ROOT"
mount "$PART" "$ROOT"

cleanup() {
  swapoff "$SWAPFILE" 2>/dev/null || true
  rm -f "$SWAPFILE"
}
trap cleanup EXIT

# The board only has 4 GB of RAM; give Nix some temporary swap on the new disk.
if fallocate -l 2G "$SWAPFILE" && chmod 600 "$SWAPFILE" && mkswap "$SWAPFILE" >/dev/null && swapon "$SWAPFILE"; then
  echo "==> Temporary 2 GB swap enabled"
else
  echo "==> Could not enable temporary swap; continuing without it"
fi

echo "==> Installing NixOS (downloads a lot; expect 10-40+ minutes)"
nixos-install --root "$ROOT" --flake "$FLAKE_REF#$HOST_NAME" --no-root-passwd

# Keep a copy of the flake on the new system so you can rebuild from the board.
mkdir -p "$ROOT/etc/bpi-m5-nixos"
cp -rT --no-preserve=mode,ownership "$FLAKE_REF" "$ROOT/etc/bpi-m5-nixos"

# ---- 5. Finish --------------------------------------------------------------
cleanup
sync
umount -R "$ROOT"

echo
echo "==> Done. NixOS is installed on $EMMC."
echo "    1. Power off:  sudo poweroff"
echo "    2. Take the SD card OUT."
echo "    3. Power the board on again. It should boot from the eMMC."
echo "    To change the system later, on the board:"
echo "        sudo nixos-rebuild switch --flake /etc/bpi-m5-nixos#$HOST_NAME"
