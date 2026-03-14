{ config, pkgs, lib, ... }:
{
  # ============================================================
  # Fan Control – ITE IT8613E via out-of-tree it87 module
  #
  # The DXP4800 Plus uses an ITE IT8613E Super I/O chip for fan
  # control. The mainline kernel doesn't support it yet, so we
  # build the community it87 module from GitHub.
  # ============================================================

  boot.extraModulePackages = [
    (config.boot.kernelPackages.callPackage ({ stdenv, fetchFromGitHub, kernel }: stdenv.mkDerivation {
      pname = "it87";
      version = "unstable";

      src = fetchFromGitHub {
        owner = "frankcrawford";
        repo = "it87";
        rev = "master";
        sha256 = "sha256-iWyOctK+TFhVCOw2LiV4NiNFEAqNXOpSdGY//VwO8Ko=";
      };

      nativeBuildInputs = kernel.moduleBuildDependencies;

      makeFlags = [
        "TARGET=${kernel.modDirVersion}"
        "KERNEL_BUILD=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
        "INSTALL_MOD_PATH=$(out)"
      ];

      installPhase = ''
        install -D it87.ko $out/lib/modules/${kernel.modDirVersion}/extra/it87.ko
      '';
    }) {})
  ];

  boot.extraModprobeConfig = ''
    options it87 force_id=0x8613
  '';

  boot.kernelModules = [ "it87" ];

  # Set pwm4/pwm5 to auto mode after module loads
  systemd.services.fan-control = {
    description = "Set NAS fans to automatic mode";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      sleep 2
      for hwmon in /sys/class/hwmon/hwmon*; do
        if [ "$(cat $hwmon/name 2>/dev/null)" = "it8613" ]; then
          echo 2 > $hwmon/pwm4_enable 2>/dev/null || true
          echo 2 > $hwmon/pwm5_enable 2>/dev/null || true
          echo "Fan control: pwm4/pwm5 set to auto on $hwmon"
          break
        fi
      done
    '';
  };
}
