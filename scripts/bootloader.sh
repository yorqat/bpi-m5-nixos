# The on-disk bootloader layout, shared by the SD image builder and the eMMC
# installer: 440 bytes of boot code at offset 0, signed U-Boot from sector 1
# (up to 8191 sectors, leaving the rest of the first 8 MiB alone).
# Keep this the single source of truth for those numbers.

write_bootloader() {
  local src="$1" dst="$2"
  dd if="$src" of="$dst" bs=512 skip=1 seek=1 count=8191 conv=fsync,notrunc status=none
  dd if="$src" of="$dst" bs=1 count=440 conv=fsync,notrunc status=none
  blockdev --flushbufs "$src" "$dst" 2>/dev/null || true
}

verify_bootloader() {
  local src="$1" dst="$2"
  cmp <(dd if="$src" bs=512 skip=1 count=8191 iflag=direct status=none) \
      <(dd if="$dst" bs=512 skip=1 count=8191 iflag=direct status=none) \
    || return 1
  cmp -n 440 <(dd if="$src" bs=512 count=1 iflag=direct status=none) \
             <(dd if="$dst" bs=512 count=1 iflag=direct status=none) \
    || return 1
}
