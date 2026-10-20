# NixOS for the Banana Pi BPI-M5

Builds a flashable NixOS SD-card image (`out/bpi-m5-nixos.img`) for the BPI-M5
(Amlogic S905X3). It automates the manual steps from the
[NixOS wiki page](https://wiki.nixos.org/wiki/NixOS_on_ARM/Banana_Pi_BPI-M5):
build mainline U-Boot, sign it with Amlogic's tools, embed it in the NixOS image,
and switch the serial console to `ttyAML0`.

> **Status: untested.** I wrote this without a Nix machine to try it on, so expect
> to possibly fix a small thing on the first run. See "If the build fails".

## Files

| File | What it does |
| --- | --- |
| `flake.nix` | Defines U-Boot, the signing step, and the NixOS system/image |
| `build.sh` | Checks your setup, builds, copies the image to `out/` |
| `flash.sh` | Writes the image to an SD card with safety checks and verification |
| `scripts/install-to-emmc.sh` | The eMMC installer, wrapped by the flake as `nix run .#install-to-emmc` |

## Part 0: One-time setup on your x86_64 PC

**1. Install Nix and enable flakes** (skip on NixOS, which just needs flakes enabled):

```
sh <(curl -L https://nixos.org/nix/install) --daemon
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

Reopen your terminal afterwards.

**2. Let Nix run ARM programs.** The board is ARM and your PC isn't, so the build
runs ARM tools under emulation.

- NixOS: add `boot.binfmt.emulatedSystems = [ "aarch64-linux" ];` to your
  config and rebuild.
- Other distros: install QEMU user emulation, then tell Nix:
  ```
  sudo apt install qemu-user-static binfmt-support
  echo 'extra-platforms = aarch64-linux' | sudo tee -a /etc/nix/nix.conf
  sudo systemctl restart nix-daemon
  ```

## Part 1: Configure

Run `nix flake lock` once (the flake now has a `m5-open-boot` input; to develop that repo
alongside, add `--override-input m5-open-boot path:../m5-open-boot` to nix commands).

Open `flake.nix` and edit the block marked `EDIT ME`:

- Paste your SSH public key into `sshKeys` (recommended).
- Optionally change `hostName`, `userName` and the first-boot password (the default is `bpi`).
- `bootOverrides` selects open boot components; leave it empty for the all-vendor baseline.

If you put this folder in a git repo, `git add` every file first, because flakes
ignore untracked files.

## Part 2: Build

```
./build.sh
```

Expect 15 to 60+ minutes the first time. When it finishes you'll have
`out/bpi-m5-nixos.img`. Nix also creates a `flake.lock` file that pins exact
versions. Keep it if you want repeatable builds.

## Part 3: Flash to a microSD card

```
./flash.sh              # shows your disks
./flash.sh /dev/sdX     # replace sdX with the SD card
```

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

Do this once you've booted the SD card and can log in. The installer is a flake
app, so there's nothing to install on the board first.

**1. Copy the flake to the board** (from your PC, in the project folder; replace
`BOARD-IP`). Don't copy `out/`: it holds the 3.7 GB image.

```
ssh bpi@BOARD-IP 'mkdir -p ~/bpi-m5'
scp -r flake.nix flake.lock scripts bpi@BOARD-IP:bpi-m5/
```

Copy `flake.lock` too, so the board uses the same nixpkgs version as your PC.

**2. Run the installer on the board** (needs Ethernet; it downloads a lot):

```
ssh bpi@BOARD-IP
cd ~/bpi-m5
sudo nix run .#install-to-emmc
```

It finds the eMMC by itself, shows you the disk, and makes you retype the device
path before erasing anything. Everything on the eMMC (Android or any old Linux)
is wiped. It then:

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
- **Proprietary firmware:** Amlogic's boot blobs are fetched and packaged by the separate
  `m5-open-boot` repo (an input of this flake), which gets them from the LibreELEC
  `amlogic-boot-fip` repo (the one U-Boot's own docs point to). Open replacements are developed
  there and switched on here through `bootOverrides` in `flake.nix`. None exist yet.

## If the build fails

- **"Your Nix isn't set up to build aarch64"**: redo Part 0 step 2.
- **The `uboot-fip` step fails:** the signing tool is a statically linked x86_64 binary, so a
  missing library is not expected. Copy the exact error and send it to whoever is helping you.
- **`@AML marker missing`:** signing failed. Don't flash; share the log.
- **Which boot blobs went into an image?** Look at `MANIFEST.sha256` in `result/` of `nix build .#uboot-fip`.
- **Option/attribute errors from the NixOS module:** nixpkgs changes over time.
  Share the error text; the fix is usually one line in `flake.nix`.

To check the U-Boot half alone (quick, no emulation needed):

```
nix build .#uboot-fip -L
ls result/
```

## One thing worth verifying

The NixOS wiki writes U-Boot into the image with a single `dd` using `u-boot.bin`.
The upstream U-Boot docs for this board use `u-boot.bin.sd.bin` plus a second
440-byte write. This project follows the upstream U-Boot docs. If the board
doesn't boot, compare against the
[U-Boot BPI-M5 page](https://docs.u-boot.org/en/latest/board/amlogic/bananapi-m5.html)
and the wiki.
