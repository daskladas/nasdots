# ================================================================
# NixNAS – Disko Configuration
# 2x NVMe RAID1 (root) + 3x HDD RAID5 (data)
#
# ⚠️ The internal UGOS SSD (nvme-YSO128GTLCW-...) is intentionally
#    NOT listed here. NEVER add it to this file!
# ================================================================
{ ... }:
{
  disko.devices = {
    disk = {
      # === NVMe 1 (Patriot P300 #1) ===
      nvme1 = {
        device = "/dev/disk/by-id/nvme-Patriot_M.2_P300_128GB_P300LCBA2508221667";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            root = {
              size = "100%";
              content = {
                type = "mdraid";
                name = "nixos";
              };
            };
          };
        };
      };

      # === NVMe 2 (Patriot P300 #2) ===
      nvme2 = {
        device = "/dev/disk/by-id/nvme-Patriot_M.2_P300_128GB_P300LCBA2508221720";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            "ESP-backup" = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
              };
            };
            root = {
              size = "100%";
              content = {
                type = "mdraid";
                name = "nixos";
              };
            };
          };
        };
      };

      # === HDD 1 (IronWolf 8TB) ===
      hdd1 = {
        device = "/dev/disk/by-id/ata-ST8000VN004-3CP101_WWZB8RV1";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            data = {
              size = "100%";
              content = {
                type = "mdraid";
                name = "data";
              };
            };
          };
        };
      };

      # === HDD 2 (IronWolf 8TB) ===
      hdd2 = {
        device = "/dev/disk/by-id/ata-ST8000VN004-3CP101_WWZB8303";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            data = {
              size = "100%";
              content = {
                type = "mdraid";
                name = "data";
              };
            };
          };
        };
      };

      # === HDD 3 (IronWolf 8TB) ===
      hdd3 = {
        device = "/dev/disk/by-id/ata-ST8000VN004-3CP101_WWZB9LV7";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            data = {
              size = "100%";
              content = {
                type = "mdraid";
                name = "data";
              };
            };
          };
        };
      };
    };

    # === RAID Arrays ===
    mdadm = {
      # NVMe RAID1 Mirror → NixOS root (ext4)
      nixos = {
        type = "mdadm";
        level = 1;
        metadata = "1.2";
        content = {
          type = "filesystem";
          format = "ext4";
          mountpoint = "/";
        };
      };

      # HDD RAID5 Array → Data (btrfs with compression)
      data = {
        type = "mdadm";
        level = 5;
        metadata = "1.2";
        content = {
          type = "filesystem";
          format = "btrfs";
          mountpoint = "/data";
          mountOptions = [ "defaults" "noatime" "compress=zstd:1" "commit=3600" ];
        };
      };
    };
  };
}
