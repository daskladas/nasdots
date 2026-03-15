{ config, pkgs, lib, ... }:
{
  # ============================================================
  # Fan Control – ITE IT8613E via out-of-tree it87 module
  #
  # The DXP4800 Plus uses an ITE IT8613E Super I/O chip for fan
  # control. The mainline kernel doesn't support it yet, so we
  # build the community it87 module from GitHub.
  #
  # Required workarounds for this chip:
  #   1. acpi_enforce_resources=lax  → ACPI reserves the I/O ports
  #      (0x0a00-0x0a3f) and blocks the driver without this
  #   2. force_id=0x8613             → chip not in mainline ID table
  #   3. ignore_resource_conflict=1  → driver-level ACPI override
  #
  # The out-of-tree module installs to extra/ which depmod
  # prioritises over the in-tree version in kernel/drivers/hwmon/.
  # ============================================================

  # Kernel parameter: allow hwmon drivers to access ACPI-reserved I/O ports
  boot.kernelParams = [ "acpi_enforce_resources=lax" ];

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
    options it87 force_id=0x8613 ignore_resource_conflict=1
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
      # Wait for hwmon devices to settle, retry up to 10 seconds
      for attempt in $(seq 1 10); do
        for hwmon in /sys/class/hwmon/hwmon*; do
          if [ "$(cat $hwmon/name 2>/dev/null)" = "it8613" ]; then
            echo 2 > $hwmon/pwm4_enable 2>/dev/null || true
            echo 2 > $hwmon/pwm5_enable 2>/dev/null || true
            echo "Fan control: pwm4/pwm5 set to auto on $hwmon (attempt $attempt)"
            exit 0
          fi
        done
        sleep 1
      done
      echo "ERROR: it8613 hwmon device not found after 10 attempts!" >&2
      exit 1
    '';
  };
}
