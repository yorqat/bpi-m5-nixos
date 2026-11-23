#!/usr/bin/env bash
# Verify the bootloader layout of a built SD image without flashing anything.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/common.sh

NIX_FLAGS=(--extra-experimental-features "nix-command flakes" --no-write-lock-file)

IMG="${1:-}"
if [ -z "$IMG" ]; then
  if [ -f result/sd-image/bpi-m5-nixos.img ]; then
    IMG=result/sd-image/bpi-m5-nixos.img
  else
    mapfile -t imgs < <(find out -maxdepth 1 -type f -name '*.img' 2>/dev/null | sort)
    [ "${#imgs[@]}" -eq 1 ] || die "Pass the image path, or build it with 'nix build .#sd-image'."
    IMG="${imgs[0]}"
  fi
fi
[ -f "$IMG" ] || die "Image not found: $IMG"

echo "==> Checking image name"
want="$(nix eval --raw "${NIX_FLAGS[@]}" '.#nixosConfigurations.bpi-m5-sd.config.image.fileName' 2>/dev/null)"
got="$(basename "$IMG")"
[ "$got" = "$want" ] || die "Image is named '$got', but the flake config expects '$want'"

echo "==> Locating signed U-Boot"
fip="$(nix build --no-link --print-out-paths "${NIX_FLAGS[@]}" .#uboot-fip 2>/dev/null | tail -n1)"
[ -n "$fip" ] || die "Could not build .#uboot-fip"
src="$fip/u-boot.bin.sd.bin"
[ -f "$src" ] || die "Missing $src"

src_size="$(stat -c%s "$src")"
[ "$src_size" -gt 512 ] || die "Signed U-Boot is unexpectedly small: $src_size bytes"

echo "==> Checking 440-byte boot code"
cmp -n 440 \
  <(dd if="$src" bs=1 count=440 status=none) \
  <(dd if="$IMG" bs=1 count=440 status=none) \
  || die "Boot code at offset 0 does not match the signed U-Boot"

echo "==> Checking signed U-Boot from sector 1"
cmp -n "$((src_size - 512))" \
  <(dd if="$src" bs=512 skip=1 status=none) \
  <(dd if="$IMG" bs=512 skip=1 status=none) \
  || die "U-Boot payload from sector 1 does not match"

echo "==> Checking partition table"
mbr="$(od -An -tx1 -j 510 -N 2 "$IMG" | tr -d ' \n')"
[ "$mbr" = "55aa" ] || die "Missing MBR signature (got '$mbr')"
lba="$(od -An -tu4 -j 454 -N 4 "$IMG" | tr -d ' \n')"
[ "$lba" = "16384" ] || die "First partition starts at sector $lba, expected 16384"

echo "==> Checking @AML marker"
grep -aq '@AML' "$fip/u-boot.bin" || die "@AML marker missing from signed U-Boot"

echo
echo "==> $IMG layout OK"
