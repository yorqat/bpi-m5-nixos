#!/usr/bin/env bash
# Builds the flashable NixOS SD image for the Banana Pi BPI-M5 into out/
set -euo pipefail
cd "$(dirname "$0")"

source scripts/common.sh

command -v nix >/dev/null 2>&1 || die "Nix is not installed. See README.md, 'Step 0'."

NIX_FLAGS=(--extra-experimental-features "nix-command flakes")

# The target is aarch64 and the signing tools are x86_64, so whichever one
# differs from the build host must be enabled as an emulated platform.
case "$(uname -m)" in
  x86_64) need="aarch64-linux" ;;
  aarch64) need="x86_64-linux" ;;
  *) die "Unsupported build host: $(uname -m) (need x86_64-linux or aarch64-linux)." ;;
esac

cfg="$(nix "${NIX_FLAGS[@]}" config show 2>/dev/null || nix show-config 2>/dev/null || true)"
if ! grep -Eq "^extra-platforms.*$need" <<<"$cfg"; then
  cat >&2 <<EOF
ERROR: Your Nix can't run $need programs yet.
  NixOS: boot.binfmt.emulatedSystems = [ "$need" ];
  Other distros: qemu-user-static + extra-platforms = $need.
  See README.md, 'Part 0', for the exact commands, then rerun this script.
EOF
  exit 1
fi

echo "==> Building the image."
echo "    First run downloads a lot and runs ARM code under emulation: expect 15-60+ minutes."
nix "${NIX_FLAGS[@]}" build .#sd-image -L --out-link result-image

img="$(find -L result-image/sd-image -maxdepth 1 -name '*.img' | head -n1)"
[ -n "$img" ] || die "Build finished but no .img was found in result-image/sd-image/"
img_name="$(basename "$img")"

mkdir -p out
out_img="out/$img_name"
cp --no-preserve=mode "$img" "$out_img"

echo
echo "==> Done: $(pwd)/$out_img"
ls -lh "$out_img"
sha256sum "$out_img"
echo
echo "Next: insert a microSD card and run   nix run .#flash -- /dev/sdX"
echo "(run 'lsblk' to find the right device - the flash app will also show you the list)"
