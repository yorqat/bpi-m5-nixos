# Shared shell helpers for the host scripts and the flake-wrapped installer.
# build.sh and flash.sh source this file; flake.nix prepends it to
# scripts/install-to-emmc.sh.

die() { echo "ERROR: $*" >&2; exit 1; }

# Require a whole, unmounted block device before touching it.
require_disk() {
  local dev="$1" mounted
  [ -b "$dev" ] || die "$dev is not a block device."
  [ "$(lsblk -ndo TYPE "$dev")" = "disk" ] \
    || die "$dev is a partition. Give the whole disk (e.g. /dev/sdb, not /dev/sdb1)."
  mounted="$(lsblk -nr -o MOUNTPOINT "$dev" | grep -v '^$' || true)"
  [ -z "$mounted" ] || die "$dev has mounted partitions; unmount them first:
$mounted"
}

# Make the user retype the device path before anything destructive happens.
confirm_disk() {
  local dev="$1" answer
  read -r -p "Type the device path to confirm ($dev): " answer
  [ "$answer" = "$dev" ] || die "Confirmation did not match. Nothing was changed."
}
