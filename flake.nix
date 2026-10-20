{
  description = "NixOS for the Banana Pi BPI-M5 (Amlogic S905X3): SD image + eMMC installer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Boot-stage components (vendor blobs today, open replacements over time) and the
    # FIP packaging live in their own repo. For local development of that repo:
    #   nix build ... --override-input m5-open-boot path:../m5-open-boot
    m5-open-boot = {
      url = "github:yorqat/m5-open-boot"; # TODO: point at wherever you publish it
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, m5-open-boot, ... }:
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

      # Boot components to replace with open versions from m5-open-boot. Empty = all
      # vendor blobs. Names are listed in m5-open-boot's nix/components.nix, e.g.
      #   bootOverrides = { bl30 = "${m5-open-boot.packages.x86_64-linux.bl30-open}/bl30.bin"; };
      bootOverrides = { };
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

      # U-Boot wrapped in Amlogic's signed boot package (FIP), built by m5-open-boot.
      # The output includes MANIFEST.sha256: keep it with your boot logs.
      uboot-fip = m5-open-boot.lib.mkFip {
        pkgs = pkgsHost;
        board = "bananapi-m5";
        bl33 = "${uboot-raw}/u-boot.bin";
        overrides = bootOverrides;
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
