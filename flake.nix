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

      # Optional onboard RTL8822CS Wi-Fi mezzanine (BPI-RT8822CS). Setting this
      # to true only enables the SDIO controller in the device tree; the driver
      # and firmware are already in the stock kernel/image. It does NOT enable
      # Bluetooth on that module (that needs a custom kernel). The -wifi flake
      # variants below enable it without editing this line.
      enableRtl8822csWifi = false;
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

      # Opt-in support for the RTL8822CS Wi-Fi mezzanine. Mainline leaves the
      # SDIO controller (and its UART, used by Bluetooth) disabled on the M5.
      # Enabling just the SDIO side needs only a device-tree overlay: no custom
      # kernel build. Bluetooth needs CONFIG_BT_HCIUART_RTL, which is off in the
      # stock kernel, so it is deliberately not touched here.
      #
      # dtc cannot turn standalone &{/path} phandle references into overlay
      # fixups, so the phandle numbers are read from the pinned kernel's DTB
      # when this overlay is built. A kernel update therefore can't silently
      # point at the wrong nodes. Built with the aarch64 toolchain so it also
      # works natively on the board (no x86_64 emulation needed). This mirrors
      # mainline's Bananapi SDIO setup: 1.8 V signaling, a power-sequence node
      # with the module reset line and a 32 kHz ext_clock, and the PWM that
      # generates that clock. No custom kernel build is involved.
      rtl8822csDtbo = pkgsArm.runCommand "rtl8822cs-wifi-dtbo" {
        nativeBuildInputs = with pkgsArm; [ dtc ];
      } ''
        dtb="${self.nixosConfigurations."${hostName}".config.boot.kernelPackages.kernel}/dtbs/amlogic/meson-sm1-bananapi-m5.dtb"

        ph() { ${pkgsArm.dtc}/bin/fdtget -t x "$dtb" "$1" phandle; }
        p_sdio=$(ph /soc/bus@ff600000/bus@34400/pinctrl@40/sdio)
        p_gate=$(ph /soc/bus@ff600000/bus@34400/pinctrl@40/sdio_clk_gate)
        p_pwm_e=$(ph /soc/bus@ff600000/bus@34400/pinctrl@40/pwm-e)
        p_gpio=$(ph /soc/bus@ff600000/bus@34400/pinctrl@40/bank@40)
        p_pwm=$(ph /soc/bus@ffd00000/pwm@19000)
        p_3v3=$(ph /regulator-vddao-3v3)
        p_1v8=$(ph /regulator-vddao-1v8)
        for p in "$p_sdio" "$p_gate" "$p_pwm_e" "$p_gpio" "$p_pwm" "$p_3v3" "$p_1v8"; do
          [ -n "$p" ] || { echo "ERROR: missing phandle in $dtb"; exit 1; }
        done

        cat > overlay.dts <<EOF
        /dts-v1/;
        /plugin/;

        / {
          compatible = "bananapi,bpi-m5";
        };

        &{/} {
          sdio_pwrseq: sdio-pwrseq {
            compatible = "mmc-pwrseq-simple";
            reset-gpios = <0x$p_gpio 71 1>; /* GPIOX_6, active low */
            clocks = <&wifi32k>;
            clock-names = "ext_clock";
          };

          wifi32k: wifi32k {
            compatible = "pwm-clock";
            #clock-cells = <0>;
            clock-frequency = <32768>;
            pwms = <0x$p_pwm 0 30518 0>; /* PWM_E */
          };
        };

        &{/soc/bus@ffd00000/pwm@19000} {
          status = "okay";
          pinctrl-0 = <0x$p_pwm_e>;
          pinctrl-names = "default";
        };

        &{/soc/mmc@ffe03000} {
          status = "okay";
          pinctrl-names = "default", "clk-gate";
          pinctrl-0 = <0x$p_sdio>;
          pinctrl-1 = <0x$p_gate>;
          #address-cells = <1>;
          #size-cells = <0>;

          bus-width = <4>;
          /* The M5 base DT clocks SDIO at 24 MHz; 50 MHz (from the M4 DT)
           * makes rtw88 firmware downloads time out on this module. */
          max-frequency = <25000000>;
          non-removable;
          disable-wp;
          keep-power-in-suspend;

          mmc-pwrseq = <&sdio_pwrseq>;
          vmmc-supply = <0x$p_3v3>;
          vqmmc-supply = <0x$p_1v8>;

          wifi@1 {
            reg = <1>;
          };
        };
        EOF

        dtc -I dts -O dtb -@ -o "$out" overlay.dts
      '';

      rtl8822csWifiModule = { lib, config, ... }: {
        options.bpiM5.enableRtl8822csWifi = lib.mkEnableOption
          "onboard RTL8822CS Wi-Fi (SDIO) mezzanine";

        config = lib.mkIf config.bpiM5.enableRtl8822csWifi {
          hardware.deviceTree.enable = true;
          hardware.deviceTree.overlays = [
            {
              name = "rtl8822cs-wifi";
              filter = "meson-sm1-bananapi-m5.dtb";
              dtboFile = rtl8822csDtbo;
            }
          ];
        };
      };

      # Settings shared by the SD image and the installed (eMMC) system.
      commonModule = { pkgs, ... }: {
        imports = [ rtl8822csWifiModule ];
        bpiM5.enableRtl8822csWifi = enableRtl8822csWifi;
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
          openFirewall = true;
          settings.publish = {
            disable-publishing = false;
            publish-domain = true;
            publish-addresses = true;
            disable-user-service-publishing = false;
          };
        };

        # OOM protection
        services.earlyoom.enable = true;

        # eMMC/flash hygiene
        services.fstrim.enable = true;
        services.journald.extraConfig = ''
          SystemMaxUse=100M
          RuntimeMaxUse=50M
        '';
        boot.loader.generic-extlinux-compatible.configurationLimit = 10;
        boot.zfs.forceImportRoot = false;

        # Audio (BT/HDMI)
        services.pipewire = {
          enable = true;
          alsa.enable = true;
          pulse.enable = true;
        };
        security.rtkit.enable = true;

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

        # Firmware for USB dongles and for the optional onboard RTL8822CS Wi-Fi
        # (rtw88-firmware / linux-firmware are already shipped here).
        hardware.enableRedistributableFirmware = true;

        # Networking (needed for Wi-Fi and USB dongles)
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
        sdImage.expandOnBoot = true;

        environment.systemPackages = with pkgs; [
          (writeShellScriptBin "install-to-emmc" ''
            cd /bpi-m5-nixos
            exec sudo nix run .#install-to-emmc "$@"
          '')
        ];

        system.activationScripts.bpiM5Repo = lib.stringAfter [ "users" ] ''
          mkdir -p /bpi-m5-nixos /home/${userName}/bpi-m5-nixos
          cp -r ${self}/* /bpi-m5-nixos/ 2>/dev/null || true
          cp -r ${self}/.[!.]* /bpi-m5-nixos/ 2>/dev/null || true
          rm -rf /bpi-m5-nixos/.git /bpi-m5-nixos/.direnv /bpi-m5-nixos/out 2>/dev/null || true
          chmod -R u+w /bpi-m5-nixos 2>/dev/null || true
          chown -R ${userName}:users /bpi-m5-nixos 2>/dev/null || true

          cp -r ${self}/* /home/${userName}/bpi-m5-nixos/ 2>/dev/null || true
          cp -r ${self}/.[!.]* /home/${userName}/bpi-m5-nixos/ 2>/dev/null || true
          rm -rf /home/${userName}/bpi-m5-nixos/.git /home/${userName}/bpi-m5-nixos/.direnv /home/${userName}/bpi-m5-nixos/out 2>/dev/null || true
          chmod -R u+w /home/${userName}/bpi-m5-nixos 2>/dev/null || true
          chown -R ${userName}:users /home/${userName}/bpi-m5-nixos 2>/dev/null || true
        '';
      };

      # The system that gets installed onto the eMMC. The bootloader itself is not
      # part of this: install-to-emmc copies it from the SD card you booted from.
      emmcModule = { ... }: {
        fileSystems."/" = {
          device = "/dev/disk/by-label/nixos";
          fsType = "ext4";
          options = [ "noatime" ];
          autoResize = true;
        };

        boot.loader.grub.enable = false;
        boot.loader.generic-extlinux-compatible.enable = true;
        boot.growPartition = true;
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

      # Same image with the SDIO overlay applied, so users can try the onboard
      # Wi-Fi without editing the ENABLE ME switch in flake.nix.
      sdImageWifi = self.nixosConfigurations."${hostName}-sd-wifi".config.system.build.sdImage;

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

      # Opt-in variants with the RTL8822CS Wi-Fi overlay enabled. Useful for
      # testing without editing the switch in flake.nix.
      nixosConfigurations."${hostName}-wifi" = lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          commonModule
          emmcModule
          { bpiM5.enableRtl8822csWifi = lib.mkForce true; }
        ];
      };
      nixosConfigurations."${hostName}-sd-wifi" = lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = { inherit self; };
        modules = [
          commonModule
          sdModule
          { bpiM5.enableRtl8822csWifi = lib.mkForce true; }
        ];
      };

      # nix build .#sd-image  /  .#uboot-fip  (no system in the command)
      packages = eachSystem (s: {
        default = sdImage;
        sd-image = sdImage;
        sd-image-wifi = sdImageWifi;
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
            if [ -t 1 ]; then
              echo "bpi-m5-nixos dev shell"
              echo "  build image: nix build .#sd-image -L"
              echo "  onboard Wi-Fi: nix build .#sd-image-wifi --out-link result-wifi -L"
              echo "  flash: nix run .#flash -- /dev/sdX"
            fi
          '';
        };
      });
    };
}
