#!/usr/bin/env bash
# Cheap pre-flight checks: syntax, flake outputs, config assertions, light builds.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/common.sh

NIX_FLAGS=(--extra-experimental-features "nix-command flakes" --no-write-lock-file)

expect_eq() {
  local label="$1" got="$2" want="$3"
  [ "$got" = "$want" ] || die "$label: expected '$want', got '$got'"
}

# Keep the assertions valid even after the EDIT ME block is changed.
host="$(sed -n 's/^[[:space:]]*hostName = "\([^"]*\)";/\1/p' flake.nix | head -n1)"
user="$(sed -n 's/^[[:space:]]*userName = "\([^"]*\)";/\1/p' flake.nix | head -n1)"
password="$(sed -n 's/^[[:space:]]*userInitialPassword = "\([^"]*\)";/\1/p' flake.nix | head -n1)"
ssh_key_count="$(sed -n '/sshKeys = \[/,/\];/p' flake.nix | grep -c '^[[:space:]]*"ssh-' || true)"

echo "==> shell syntax"
for f in build.sh flash.sh scripts/*.sh tests/*.sh; do bash -n "$f"; done

echo "==> nix syntax"
nix-instantiate --parse flake.nix >/dev/null

echo "==> flake check"
nix flake check --all-systems "${NIX_FLAGS[@]}"

echo "==> config assertions"
# nix eval --raw only stringifies strings; lists and booleans need an explicit
# coercion, otherwise the failed command substitution makes this script exit
# silently under `set -e`.
eval_raw() {
  local out
  out="$(nix eval --raw "${NIX_FLAGS[@]}" "$1" 2>/dev/null)" || die "nix eval failed: $1"
  printf '%s' "$out"
}
eval_list() {
  local out
  out="$(nix eval --raw "${NIX_FLAGS[@]}" --apply 'x: builtins.concatStringsSep " " x' "$1" 2>/dev/null)" || die "nix eval failed: $1"
  printf '%s' "$out"
}
eval_bool() {
  local out
  out="$(nix eval --raw "${NIX_FLAGS[@]}" --apply 'x: if x then "true" else "false"' "$1" 2>/dev/null)" || die "nix eval failed: $1"
  printf '%s' "$out"
}
expect_eq "image name" \
  "$(eval_raw ".#nixosConfigurations.${host}-sd.config.image.fileName")" \
  "bpi-m5-nixos.img"
expect_eq "host name" \
  "$(eval_raw ".#nixosConfigurations.${host}.config.networking.hostName")" \
  "$host"
expect_eq "initial password" \
  "$(eval_raw ".#nixosConfigurations.${host}.config.users.users.${user}.initialPassword")" \
  "$password"
console="$(eval_list ".#nixosConfigurations.${host}.config.boot.kernelParams")"
case "$console" in
  *console=ttyAML0,115200n8*) ;;
  *) die "serial console missing from boot.kernelParams: $console" ;;
esac
if [ "$ssh_key_count" -gt 0 ]; then want=false; else want=true; fi
expect_eq "PasswordAuthentication" \
  "$(eval_bool ".#nixosConfigurations.${host}.config.services.openssh.settings.PasswordAuthentication")" \
  "$want"

echo "==> light builds"
nix build --no-link "${NIX_FLAGS[@]}" .#uboot-fip .#install-to-emmc

echo
echo "==> All quick checks passed. Next: nix build .#sd-image and ./tests/check-image.sh"
