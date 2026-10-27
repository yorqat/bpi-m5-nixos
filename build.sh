#!/usr/bin/env bash
# Builds a flashable NixOS image for the Banana Pi BPI-M5 -> out/bpi-m5-nixos.img
set -euo pipefail
cd "$(dirname "$0")"

die() { echo "ERROR: $*" >&2; exit 1; }

command -v nix >/dev/null 2>&1 || die "Nix is not installed. See README.md, 'Part 0'."

NIX_FLAGS=(--extra-experimental-features "nix-command flakes")

if [ "$(uname -m)" != "x86_64" ]; then
  die "This project expects an x86_64 build machine (Amlogic's signing tools are x86_64-only)."
fi

# We're building an aarch64 system on an x86_64 PC, so Nix needs to be able to
# run aarch64 programs (via QEMU emulation).
cfg="$(nix "${NIX_FLAGS[@]}" config show 2>/dev/null || nix show-config 2>/dev/null || true)"
if ! grep -Eq '^extra-platforms.*aarch64-linux' <<<"$cfg"; then
  cat >&2 <<'EOF'
ERROR: Your Nix isn't set up to build aarch64 (ARM) packages.

  On NixOS, add this to your configuration.nix and rebuild:
      boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  On other Linux distros:
      sudo apt install qemu-user-static binfmt-support     # (or your distro's equivalent)
      echo 'extra-platforms = aarch64-linux' | sudo tee -a /etc/nix/nix.conf
      sudo systemctl restart nix-daemon

See README.md, 'Part 0', then run this script again.
EOF
  exit 1
fi

echo "==> Building the image."
echo "    First run downloads a lot and runs ARM code under emulation: expect 15-60+ minutes."
nix "${NIX_FLAGS[@]}" build .#packages.aarch64-linux.image -L --out-link result-image

img="$(find -L result-image/sd-image -maxdepth 1 -name '*.img' | head -n1)"
[ -n "$img" ] || die "Build finished but no .img was found in result-image/sd-image/"

mkdir -p out
cp --no-preserve=mode "$img" out/bpi-m5-nixos.img

echo
echo "==> Done: $(pwd)/out/bpi-m5-nixos.img"
ls -lh out/bpi-m5-nixos.img
sha256sum out/bpi-m5-nixos.img
echo
echo "Next: insert a microSD card and run   ./flash.sh /dev/sdX"
echo "(run 'lsblk' to find the right device - flash.sh will also show you the list)"
