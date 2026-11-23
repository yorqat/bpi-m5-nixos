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

      # Commands stay architecture-free: nix resolves .#name against the local
      # system, so define the same outputs for every Linux host we support.
      systems = [ "x86_64-linux" "aarch64-linux" ];
      eachSystem = f: lib.listToAttrs (map (s: { name = s; value = f s; }) systems);
      pkgsFor = s: nixpkgs.legacyPackages.${s};

      # Amlogic's signing tools are x86_64 binaries, so FIP packaging always
      # builds on an x86_64 builder. On an aarch64 host that needs x86_64
      # emulation (binfmt + extra-platforms) or a remote x86_64 builder.
      pkgsSign = pkgsFor "x86_64-linux";
      pkgsArm = pkgsFor "aarch64-linux";

      # ---- Bootloader (built on your PC) ------------------------------------

      # Mainline U-Boot, cross-compiled for the M5 (no signing yet).
      uboot-raw = pkgsSign.pkgsCross.aarch64-multiplatform.buildUBoot {
        defconfig = "bananapi-m5_defconfig";
        extraMeta.platforms = [ "aarch64-linux" ];
        filesToInstall = [ "u-boot.bin" ];
      };

      # U-Boot wrapped in Amlogic's signed boot package (FIP).
      uboot-fip = pkgsSign.stdenv.mkDerivation {
        pname = "uboot-bananapi-m5-fip";
        version = "git";
        src = amlogic-boot-fip;

        nativeBuildInputs = with pkgsSign; [ python3 gnumake patchelf util-linux ];

        dontConfigure = true;
        dontFixup = true;

        buildPhase = ''
          runHook preBuild

          # Make the repo's scripts runnable inside the Nix sandbox.
          patchShebangs .

          # Amlogic's signing tools are prebuilt x86_64 binaries; point them at
          # Nix's dynamic linker/libs so they can run.
          interp="$(cat $NIX_CC/nix-support/dynamic-linker)"
          rpath="${pkgsSign.lib.makeLibraryPath [ pkgsSign.stdenv.cc.cc.lib pkgsSign.zlib ]}"
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
      commonModule = { pkgs, ... }: {
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

        # mDNS (.local) resolution
        services.avahi = {
          enable = true;
          nssmdns4 = true;
          publish = {
            enable = true;
            addresses = true;
            userServices = true;
          };
        };

        # OOM protection
        services.earlyoom.enable = true;

        # Nix QoL
        nix.settings = {
          experimental-features = [ "nix-command" "flakes" ];
          auto-optimise-store = true;
        };
        nix.gc = {
          automatic = true;
          dates = "weekly";
          options = "--delete-older-than 30d";
        };

        # Direnv for per-project environments
        programs.direnv = {
          enable = true;
          nix-direnv.enable = true;
        };

        # Compressed swap in RAM to avoid OOMs on 4GB boards
        zramSwap = {
          enable = true;
          memoryPercent = 50;
        };

        # Firmware for USB WiFi/Bluetooth dongles
        hardware.enableRedistributableFirmware = true;

        # Networking (needed for USB WiFi dongles)
        networking.networkmanager.enable = true;

        # Bluetooth
        hardware.bluetooth = {
          enable = true;
          powerOnBoot = true;
        };
        services.blueman.enable = true;

        environment.systemPackages = with pkgs; [
          git
          vim
          neovim
          htop
          btop
          rsync
          fastfetch
          tmux
          ripgrep
          fd
          eza
          zoxide
          ncdu
          tree
          curl
          wget
          unzip
          jq
          lm_sensors
          ethtool
          pciutils
          usbutils
          smartmontools
          nh
          comma
          nil
          nixd
          alejandra
          just
          bluez
          bluez-tools
        ];

        system.stateVersion = "25.11";
      };

      # The live SD card image.
      sdModule = { pkgs, self, ... }: {
        imports = [
          "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
        ];

        # nixpkgs builds $out/sd-image/${image.baseName}.${image.extension};
        # image.fileName is only a derived option, so set the base name here.
        image.baseName = "bpi-m5-nixos";
        sdImage.compressImage = false; # plain .img you can dd directly

        # The layout lives in scripts/bootloader.sh, shared with the installer.
        sdImage.postBuildCommands = lib.mkAfter ''
          ${builtins.readFile ./scripts/bootloader.sh}
          write_bootloader "${uboot-fip}/u-boot.bin.sd.bin" "$img"
        '';

        environment.systemPackages = with pkgs; [
          (writeShellScriptBin "install-to-emmc" ''
            cd /bpi-m5-nixos
            exec sudo nix run .#install-to-emmc "$@"
          '')
        ];

        system.activationScripts.bpiM5Repo = lib.stringAfter [ "users" ] ''
          mkdir -p /bpi-m5-nixos
          cp -r ${self}/* /bpi-m5-nixos/ 2>/dev/null || true
          cp -r ${self}/.[!.]* /bpi-m5-nixos/ 2>/dev/null || true
          rm -rf /bpi-m5-nixos/.git /bpi-m5-nixos/.direnv /bpi-m5-nixos/out 2>/dev/null || true
          chmod -R u+w /bpi-m5-nixos 2>/dev/null || true
          chown -R ${userName}:${userName} /bpi-m5-nixos 2>/dev/null || true
        '';
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
          export USER_NAME="${userName}"
        ''
        + builtins.readFile ./scripts/common.sh
        + builtins.readFile ./scripts/bootloader.sh
        + builtins.readFile ./scripts/install-to-emmc.sh;
      };

      # The SD image is an aarch64 derivation, but store paths are global, so it
      # can be exposed as a normal package on any supported host system.
      sdImage = self.nixosConfigurations."${hostName}-sd".config.system.build.sdImage;

      # Host-side flashing app. The image is baked in so it works from any cwd.
      flashFor = s: (pkgsFor s).writeShellApplication {
        name = "flash";
        runtimeInputs = with (pkgsFor s); [ coreutils diffutils findutils gnugrep util-linux ];
        text = ''
          FLASH_IMAGE_DEFAULT="${sdImage}/sd-image"
        ''
        + builtins.readFile ./scripts/common.sh
        + builtins.readFile ./scripts/flash-body.sh;
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
        specialArgs = { inherit self; };
        modules = [ commonModule sdModule ];
      };

      # nix build .#sd-image  /  .#uboot-fip  (no system in the command)
      packages = eachSystem (s: {
        default = sdImage;
        sd-image = sdImage;
        flash = flashFor s;
        inherit uboot-raw uboot-fip install-to-emmc;
      });

      # nix run .#flash -- /dev/sdX  on any supported host;
      # nix run .#install-to-emmc  only runs on the board (aarch64).
      apps = eachSystem (s:
        {
          flash = {
            type = "app";
            program = "${flashFor s}/bin/flash";
            meta.description = "Write the SD image to a microSD card";
          };
        } // lib.optionalAttrs (s == "aarch64-linux") {
          install-to-emmc = {
            type = "app";
            program = "${install-to-emmc}/bin/install-to-emmc";
            meta.description = "Install NixOS from the SD card onto the eMMC";
          };
        });

      devShells = eachSystem (s: {
        default = (pkgsFor s).mkShell {
          packages = with (pkgsFor s); [
            git
            nixpkgs-fmt
            alejandra
            nil
            nixd
            just
            ssh-to-age
          ];
          shellHook = ''
            echo "bpi-m5-nixos dev shell"
            echo "  build image: ./build.sh or nix build .#sd-image"
            echo "  flash:       ./flash.sh /dev/sdX (or nix run .#flash -- /dev/sdX)"
          '';
        };
      });
    };
}
