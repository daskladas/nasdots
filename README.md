# NixOS NAS on a Ugreen DXP4800 Plus

I wanted a NAS that I actually understand. No proprietary OS, no clicking through web UIs, no mystery services running in the background. Just a plain NixOS system where every single thing is declared in config files I can read, version, and rebuild from scratch in minutes.

This repo contains the complete NixOS configuration for my home NAS — a Ugreen DXP4800 Plus running three 8TB drives in RAID5 for storage and two 128GB NVMe drives in RAID1 for the OS.

## Hardware

| | |
|-|-|
| **Device** | Ugreen DXP4800 Plus (4-Bay, Bay 4 free for expansion) |
| **CPU** | Intel Pentium Gold 8505 (5C/6T) |
| **RAM** | 8 GB DDR5 |
| **OS** | 2× Patriot P300 128GB NVMe → mdadm RAID1, ext4, 118 GB |
| **Data** | 3× Seagate IronWolf 8TB → mdadm RAID5, btrfs + zstd:1, ~14.55 TiB |
| **Network** | 2.5GbE (+ unused 10GbE) |

## What's In Here

The entire system is ~7 files. Here's what they set up:

**Storage** — disko handles partitioning declaratively. mdadm provides RAID1 (OS) and RAID5 (data). btrfs with zstd compression on the data drives, with a monthly scrub for integrity. The ESP gets synced to the backup NVMe via rsync on every rebuild.

**NFS** — Two shares with fixed ports for firewall compatibility: one read-write for Proxmox backups (no_root_squash), one read-only for Jellyfin media.

**Health** — smartmontools runs short self-tests daily and long tests weekly, with temperature alerts at 45/55°C. hdparm puts drives to sleep after 20 min idle and enables quiet seek mode.

**Security** — Fail2Ban on SSH (5 attempts → 1h ban, escalating to 48h). Firewall open only for SSH and NFS.

**UGOS protection** — The DXP4800 Plus ships with Ugreen's proprietary OS on an internal NVMe SSD. I keep it intact for warranty. Four independent layers make sure it's never written to: excluded from disko, udev sets it read-only by serial, a systemd service re-applies on boot, and there are no mount entries. Restoring UGOS is just a BIOS boot order change.

**Monitoring** — A custom bash dashboard (`sudo nixnas-status`) shows RAID status, drive health, temperatures, NFS share status, and active services over SSH.

## Files

```
flake.nix                  # nixpkgs 25.11 + disko
configuration.nix          # boot, network, users, packages, services
disko-config.nix           # NVMe RAID1 + HDD RAID5 layout
hardware-configuration.nix # kernel modules, CPU, firmware
modules/nfs.nix            # NFS exports and fixed ports
modules/ugos-protection.nix # 4-layer UGOS SSD protection
scripts/nixnas-status       # live SSH dashboard
```

## Reproducing This

You'll need a Ugreen DXP4800 Plus (or similar x86 NAS) with NVMe + HDD drives. The DXP4800 Plus has a quirk: it only boots from its internal NVMe slot. So the NixOS bootloader lives on the UGOS SSD's ESP partition alongside the vendor bootloader, while NixOS itself runs from the Patriot P300 RAID1.

```bash
# 1. Boot NixOS minimal ISO from USB (use LTS kernel)
#    Disable WatchDog in BIOS first (it reboots after 180s expecting UGOS)

# 2. Set the UGOS SSD read-only before touching anything
blockdev --setro /dev/nvme2n1

# 3. Partition drives with disko
nix --experimental-features "nix-command flakes" run github:nix-community/disko -- \
  --mode disko ./disko-config.nix

# 4. Clone this repo into /mnt/etc/nixos
git clone https://github.com/YOUR_USER/nixnas.git /mnt/etc/nixos

# 5. Build and install (two-step workaround for a known flake bug)
nix --experimental-features "nix-command flakes" build \
  .#nixosConfigurations.nixnas.config.system.build.toplevel --store /mnt
nixos-install --root /mnt --system ./result --no-root-passwd

# 6. Copy NixOS bootloader to the UGOS SSD ESP and create EFI entry
#    (the internal NVMe is the only slot the BIOS can boot from)
mount /dev/nvme2n1p1 /mnt/ugos-esp
cp -r /mnt/boot/EFI/* /mnt/ugos-esp/EFI/
efibootmgr -c -d /dev/nvme2n1 -p 1 -L "NixOS" -l '\EFI\systemd\systemd-bootx64.efi'

# 7. Reboot, remove USB, NixOS should boot
# 8. After first login: change password, verify RAID sync with cat /proc/mdstat
```

After first boot, any future changes are just:

```bash
cd /etc/nixos && sudo nixos-rebuild switch --flake .#nixnas
```

## Known Issues

- **Patriot P300 invisible in BIOS** — the DXP4800 Plus only shows its internal NVMe slot as bootable, so the bootloader has to live on the UGOS SSD ESP
- **WatchDog reboots** — BIOS sends a 180s watchdog expecting UGOS to respond; disable it in BIOS settings
- **nixos-install crash** — `nix flake build` + `nixos-install --flake` hits an assertion error; the two-step build-then-install workaround above avoids it
- **mdadm warning** — "Neither MAILADDR nor PROGRAM" shows up in builds; cosmetic only, no impact
- **IT8613E fan controller** — the ITE chip needs an out-of-tree `it87` kernel module for fan speed control; not yet integrated into this config

## License

MIT
