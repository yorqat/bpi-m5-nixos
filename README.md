# NixOS for the Banana Pi BPI-M5

Builds a flashable NixOS SD-card image for the BPI-M5 (Amlogic S905X3) with
`nix build .#sd-image`, flashes it with `nix run .#flash -- /dev/sdX`, and
installs it to eMMC with `nix run .#install-to-emmc` on the board. It automates
the manual steps from the
[NixOS wiki page](https://wiki.nixos.org/wiki/NixOS_on_ARM/Banana_Pi_BPI-M5):
build mainline U-Boot, sign it with Amlogic's tools, embed it in the NixOS image,
and switch the serial console to `ttyAML0`. The shell scripts in this repo are
thin convenience wrappers around those flake commands.

> **Status: build verified, hardware untested.** `nix flake check --all-systems`
> passes and both the SD image and installer build on x86_64 Linux. Booting on a
> real BPI-M5 is still unverified. See "If the build fails".

## Files

| File | What it does |
| --- | --- |
| `flake.nix` | Defines U-Boot, the signing step, the NixOS systems, and the flake commands |
| `build.sh` | Convenience wrapper for `nix build .#sd-image`; copies the result to `out/` |
| `flash.sh`, `scripts/flash-body.sh` | Convenience wrapper and shared body for `nix run .#flash` |
| `scripts/install-to-emmc.sh` | Backs `nix run .#install-to-emmc` |
| `scripts/common.sh`, `scripts/bootloader.sh` | Shared disk guards and the single bootloader layout definition |
| `tests/` | Pre-flight and image-layout checks; see "Testing" |

## Step 0: Install Nix and enable flakes

Skip the install on NixOS, which only needs flakes enabled in `configuration.nix`:

```
sh <(curl -L https://nixos.org/nix/install) --daemon
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

Reopen your terminal afterwards.

## Part 0: One-time setup on your Linux PC

The signing tools are x86_64 binaries, so the normal build host is x86_64 Linux.
An aarch64 Linux host also works if it can run x86_64 binaries (binfmt +
`extra-platforms = x86_64-linux`, or a remote x86_64 builder). macOS needs an
x86_64 Linux VM — the commands are the same on any supported host.

**1. Let Nix run other-architecture programs.** The image is aarch64, and the
Amlogic signing tools are x86_64, so at least one of those runs under emulation.

- On x86_64 Linux, enable aarch64 emulation:
  - NixOS: add `boot.binfmt.emulatedSystems = [ "aarch64-linux" ];` to your
    config and rebuild.
  - Other distros: install QEMU user emulation, then tell Nix:
    ```
    sudo apt install qemu-user-static binfmt-support
    echo 'extra-platforms = aarch64-linux' | sudo tee -a /etc/nix/nix.conf
    sudo systemctl restart nix-daemon
    ```
- On aarch64 Linux, enable x86_64 emulation instead (`extra-platforms =
  x86_64-linux`, or point Nix at a remote x86_64 builder) for the signing step.

## Part 1: Configure

Open `flake.nix` and edit the block marked `EDIT ME`:

- Paste your SSH public key into `sshKeys` (recommended).
- Optionally change `hostName`, `userName` and the first-boot password (the default is `bpi`).

## Part 2: Build

```
nix build .#sd-image -L
```

The image is at `result/sd-image/bpi-m5-nixos.img`. Expect 15 to 60+ minutes the
first time. `flake.lock` is committed and pins exact dependency versions; keep it
in sync with flake changes for repeatable builds.

No architecture appears in the command: the flake defines the same outputs on
every supported Linux host. `nix flake check --all-systems` validates them all.
If you prefer a copy in `out/bpi-m5-nixos.img`, run `./build.sh` instead — it
calls the same build.

## Part 3: Flash to a microSD card

```
nix run .#flash --              # shows your disks
nix run .#flash -- /dev/sdX     # replace sdX with the SD card
```

The app uses the image built by the flake (building it first if needed), so it
works from any directory and you don't need a local `out/` copy. `./flash.sh
/dev/sdX` is a wrapper for the same tool if you prefer the raw script.

It refuses mounted disks and makes you retype the device path before writing.
Prefer **microSD, not the board's eMMC**, for the first attempt: pulling the card
gets you back to the original eMMC system.

## Part 4: First boot

- Insert the card, connect Ethernet (and HDMI or a 3.3V USB serial adapter at
  115200 baud), power on. The first boot expands the root partition.
- Log in as `bpi` (password `bpi` unless you changed it), or SSH in using the
  IP address from your router. Change the password with `passwd`.
- The SD card is a live system. To make NixOS permanent, install it to the eMMC
  (Part 5).

## Part 5: Install from the SD card to the eMMC

Do this once you've booted the SD card and can log in. The flake that built the
image is already on the card at `/bpi-m5-nixos`, so there's nothing to install or
copy to the board first.

**1. Log in to the board** (from your PC; replace `BOARD-IP`):

```
ssh bpi@BOARD-IP
```

**2. Run the installer on the board** (needs Ethernet; it downloads a lot):

```
cd /bpi-m5-nixos
sudo nix run .#install-to-emmc
```

The SD image also installs an `install-to-emmc` shortcut that does this for you,
including the `sudo`. The installer finds the eMMC by itself, shows you the disk,
and makes you retype the device path before erasing anything. Everything on the
eMMC (Android or any old Linux) is wiped. It then:

1. Partitions and formats the eMMC (one ext4 partition labelled `nixos`).
2. Copies the working bootloader from the SD card you booted from, and verifies
   the copy byte for byte.
3. Runs `nixos-install` with this flake (`bpi-m5` config), with a temporary 2 GB
   swapfile because the board only has 4 GB of RAM. Expect 10 to 40+ minutes.
4. Leaves a copy of the flake on the new system at `/etc/bpi-m5-nixos`.

If the board has more than one eMMC-like device, or you want to be explicit:
`sudo nix run .#install-to-emmc -- /dev/mmcblk0`

**3. Switch over:** `sudo poweroff`, take the **SD card out**, and power the board
on again. The chip's boot ROM prefers eMMC over SD, so it boots NixOS from the
eMMC.

**Later changes** (on the board, after editing `/etc/bpi-m5-nixos/flake.nix`):

```
sudo nixos-rebuild switch --flake /etc/bpi-m5-nixos#bpi-m5
```

(`bpi-m5` is the default `hostName` in `flake.nix`; use yours if you changed it.)

If the board won't boot from the eMMC, put the SD card back in. Then check that the
installer printed no errors, and tell whoever is helping you what the board does
on boot. A leftover vendor bootloader in the eMMC's hardware boot partitions
(`mmcblk0boot0`/`boot1`) is a possible cause I couldn't rule out.

## Known limitations

- **Hardware video decode** is only partly supported in mainline Linux. Don't
  expect it to be a good media box.
- **Warm reboot may hang** on S905X3 boards with an SD card (seen on the Odroid HC4,
  which uses the same SoC; not confirmed on the M5). If it happens, power-cycle
  instead of rebooting.
- **U-Boot isn't managed by `nixos-rebuild`.** It lives outside the NixOS
  partitions, so updating NixOS won't update it. To change it, rebuild the SD image
  and rerun the installer from that card.
- **Proprietary firmware:** Amlogic's boot blobs come from the LibreELEC
  `amlogic-boot-fip` repo (the one U-Boot's own docs point to).

## Testing

Booting from eMMC is the final acceptance test, but not a good *only* test: it
exercises the whole chain at once and can't tell you whether a failure came from
the signing step, the image layout, the NixOS config, or the installer. Run the
cheap layers first.

Host-side, no hardware:

```
nix flake check --all-systems
./tests/check.sh                                      # syntax, config assertions, light builds
nix build .#sd-image -L
./tests/check-image.sh result/sd-image/bpi-m5-nixos.img
```

`check-image.sh` compares the image's first 440 bytes and sector-1 payload with
the built `u-boot.bin.sd.bin`, then checks the MBR signature, the partition start
(sector 16384) and the `@AML` marker. It doesn't touch a card.

Hardware checklist:

1. Boot from the SD card. Confirm the serial console on `ttyAML0` at 115200 baud
   (or HDMI) and log in as `bpi` / `bpi`. Change the password.
2. Confirm the hostname is `bpi-m5` and `/` is on the SD card, not eMMC.
3. Run the installer with the device spelled out:
   `sudo nix run .#install-to-emmc -- /dev/mmcblkX`.
4. `sudo poweroff`, remove the SD card, power on. Repeat steps 1–2 and confirm
   `/` is now labelled `nixos` on eMMC.
5. Note the warm-reboot caveat in "Known limitations"; power-cycle if it hangs.

## If the build fails

- **"Nix is not installed"**: redo Step 0.
- **"Your Nix isn't set up to build aarch64"**: redo Part 0 step 1.
- **The `uboot-fip` step fails:** the build already points Amlogic's prebuilt
  signing tools at Nix's linker and libs. If one still won't run, copy the exact
  error and send it to whoever is helping you.
- **`@AML marker missing`:** signing failed. Don't flash; share the log.
- **Option/attribute errors from the NixOS module:** nixpkgs changes over time.
  Share the error text; the fix is usually one line in `flake.nix`.

To check the U-Boot half alone (quick, no emulation needed):

```
nix build .#uboot-fip -L
ls result/
```

## One thing worth verifying

This project writes U-Boot the way the upstream docs describe (signed
`u-boot.bin.sd.bin` at sector 1 plus 440 bytes at the start), not the single-`dd`
approach on the NixOS wiki. If the board doesn't boot, compare the
[U-Boot BPI-M5 page](https://docs.u-boot.org/en/latest/board/amlogic/bananapi-m5.html)
with the wiki.
