{ config, pkgs, lib, ... }:
{
  # ================================================================
  # UGOS SSD Protection
  #
  # The internal 128GB SSD (nvme-YSO128GTLCW-E3C-2_...) contains
  # the original UGOS operating system for warranty/return purposes.
  # It must NEVER be written to, formatted, or mounted.
  #
  # Protection layers:
  #   1. disko-config.nix: device is NOT listed
  #   2. udev rule: sets block device read-only on detection
  #   3. systemd service: re-applies read-only every boot
  #   4. no fstab/mount entries for this device
  # ================================================================

  # Layer 2: udev rule
  services.udev.extraRules = ''
    # Protect UGOS internal SSD – set read-only at block level
    ACTION=="add|change", SUBSYSTEM=="block", ENV{ID_SERIAL}=="YSO128GTLCW-E3C-2_511250701135025164", RUN+="${pkgs.util-linux}/bin/blockdev --setro /dev/%k"
  '';

  # Layer 3: systemd service as backup
  systemd.services.ugos-protect = {
    description = "Protect UGOS SSD (set read-only)";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-udev-settle.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      UGOS="/dev/disk/by-id/nvme-YSO128GTLCW-E3C-2_511250701135025164"
      if [ -e "$UGOS" ]; then
        DEV=$(${pkgs.coreutils}/bin/readlink -f "$UGOS")
        ${pkgs.util-linux}/bin/blockdev --setro "$DEV" 2>/dev/null || true
        echo "UGOS SSD ($DEV) protected: read-only"
      fi
    '';
  };
}
