{
  description = "NixOS for the Banana Pi BPI-M5 (Amlogic S905X3): SD image + eMMC installer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Amlogic's boot firmware blobs + signing tools. This is the same repo the
    # official U-Boot docs for this board tell you to use.
    amlogic-boot-fip = {
      url = "github:LibreELEC/amlogic-boot-fip";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, amlogic-boot-fip, ... }:
    let
      # ---------------------------- EDIT ME ----------------------------
      hostName = "bpi-m5";

      # Paste your public SSH key(s) here, e.g. the contents of ~/.ssh/id_ed25519.pub
      # If you list at least one key, SSH password login is turned off.
      sshKeys = [
        # "ssh-ed25519 AAAAC3... you@yourpc"
      ];

      # Console/SSH login. CHANGE THE PASSWORD after logging in (run `passwd`).
      userName = "bpi";
      userInitialPassword = "bpi";
      # ------------------------------------------------------------------

      lib = nixpkgs.lib;

      # The machine you build on. The Amlogic signing tools are x86_64-only binaries.
      buildHost = "x86_64-linux";
      pkgsHost = nixpkgs.legacyPackages.${buildHost};
      pkgsArm = nixpkgs.legacyPackages.aarch64-linux;

      # ---- Bootloader (built on your PC) ------------------------------------

      # Mainline U-Boot, cross-compiled for the M5 (no signing yet).
      uboot-raw = pkgsHost.pkgsCross.aarch64-multiplatform.buildUBoot {
        defconfig = "bananapi-m5_defconfig";
        extraMeta.platforms = [ "aarch64-linux" ];
        filesToInstall = [ "u-boot.bin" ];
      };

      # U-Boot wrapped in Amlogic's signed boot package (FIP).
      uboot-fip = pkgsHost.stdenv.mkDerivation {
        pname = "uboot-bananapi-m5-fip";
        version = "git";
        src = amlogic-boot-fip;

        nativeBuildInputs = with pkgsHost; [ python3 gnumake patchelf util-linux ];

        dontConfigure = true;
        dontFixup = true;

        buildPhase = ''
          runHook preBuild

          # Make the repo's scripts runnable inside the Nix sandbox.
          patchShebangs .

          # Amlogic's signing tools are prebuilt x86_64 binaries; point them at
          # Nix's dynamic linker/libs so they can run.
          interp="$(cat $NIX_CC/nix-support/dynamic-linker)"
          rpath="${pkgsHost.lib.makeLibraryPath [ pkgsHost.stdenv.cc.cc.lib pkgsHost.zlib ]}"
          for f in $(find . -type f -name 'aml_encrypt_*'); do
            chmod +x "$f"
            patchelf --set-interpreter "$interp" --set-rpath "$rpath" "$f" \
              || echo "note: could not patch $f (already static?)"
          done

          mkdir -p out
          ./build-fip.sh bananapi-m5 ${uboot-raw}/u-boot.bin out

          test -s out/u-boot.bin
          test -s out/u-boot.bin.sd.bin

          # Sanity check from the wiki: the signed file must contain "@AML".
          hexdump -C -n 32 out/u-boot.bin | grep -q "40 41 4d 4c" \
            || { echo "ERROR: @AML marker missing - FIP signing failed"; exit 1; }

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp out/u-boot.bin* $out/
          runHook postInstall
        '';
      };

      # ---- NixOS modules ----------------------------------------------------

      # Settings shared by the SD image and the installed (eMMC) system.
      commonModule = { lib, pkgs, ... }: {
        # Serial console on the M5 is ttyAML0 (the stock image uses ttyAMA0).
        boot.kernelParams = lib.mkForce [ "console=ttyAML0,115200n8" "console=tty0" ];

        networking.hostName = hostName;

        users.users.${userName} = {
          isNormalUser = true;
          extraGroups = [ "wheel" "networkmanager" ];
          initialPassword = userInitialPassword;
          openssh.authorizedKeys.keys = sshKeys;
        };
        security.sudo.wheelNeedsPassword = false;

        services.openssh = {
          enable = true;
          settings.PasswordAuthentication = sshKeys == [ ];
        };

        nix.settings.experimental-features = [ "nix-command" "flakes" ];
        environment.systemPackages = with pkgs; [ git vim htop rsync ];

        system.stateVersion = "25.11";
      };

      # The live SD card image.
      sdModule = { config, lib, pkgs, ... }: {
        imports = [
          "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
        ];

        sdImage = {
          imageName = "bpi-m5-nixos.img";
          compressImage = false; # plain .img you can dd directly

          # Write the signed U-Boot into the image, as the upstream U-Boot docs
          # describe (sectors 1+, plus 440 bytes of boot code at the very start
          # that leaves the partition table alone).
          postBuildCommands = lib.mkAfter ''
            dd if=${uboot-fip}/u-boot.bin.sd.bin of=$img conv=fsync,notrunc bs=512 skip=1 seek=1
            dd if=${uboot-fip}/u-boot.bin.sd.bin of=$img conv=fsync,notrunc bs=1 count=440
          '';
        };
      };

      # The system that gets installed onto the eMMC. The bootloader itself is not
      # part of this: install-to-emmc copies it from the SD card you booted from.
      emmcModule = { ... }: {
        fileSystems."/" = {
          device = "/dev/disk/by-label/nixos";
          fsType = "ext4";
          options = [ "noatime" ];
        };

        boot.loader.grub.enable = false;
        boot.loader.generic-extlinux-compatible.enable = true;

        zramSwap.enable = true;
      };

      # ---- The installer, as a flake app ------------------------------------

      install-to-emmc = pkgsArm.writeShellApplication {
        name = "install-to-emmc";
        runtimeInputs = with pkgsArm; [
          coreutils
          diffutils
          e2fsprogs
          findutils
          getent
          gnugrep
          nixos-install-tools
          util-linux
        ];
        text = ''
          export FLAKE_REF="${self}"
          export HOST_NAME="${hostName}"
          ${builtins.readFile ./scripts/install-to-emmc.sh}
        '';
      };
    in
    {
      # The system to install on the eMMC (also what you `nixos-rebuild switch`).
      nixosConfigurations.${hostName} = lib.nixosSystem {
        system = "aarch64-linux";
        modules = [ commonModule emmcModule ];
      };

      # The live SD card system.
      nixosConfigurations."${hostName}-sd" = lib.nixosSystem {
        system = "aarch64-linux";
        modules = [ commonModule sdModule ];
      };

      # Built on your PC:  nix build .#uboot-fip
      packages.${buildHost} = {
        inherit uboot-raw uboot-fip;
        default = uboot-fip;
      };

      packages.aarch64-linux = {
        # The SD image:  nix build .#packages.aarch64-linux.image
        image = self.nixosConfigurations."${hostName}-sd".config.system.build.sdImage;
        inherit install-to-emmc;
      };

      # Run on the board:  sudo nix run .#install-to-emmc
      apps.aarch64-linux.install-to-emmc = {
        type = "app";
        program = "${install-to-emmc}/bin/install-to-emmc";
      };
    };
}
