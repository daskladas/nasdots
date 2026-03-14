# NixOS NAS on a Ugreen DXP4800 Plus

![NixOS](https://img.shields.io/badge/NixOS-25.11-5277C3?logo=nixos&logoColor=white)
![RAID](https://img.shields.io/badge/RAID5-3×8TB_IronWolf-4CAF50)
![btrfs](https://img.shields.io/badge/btrfs-zstd:1-orange)
![NFS](https://img.shields.io/badge/NFS-2_exports-blue)
![Fail2Ban](https://img.shields.io/badge/Fail2Ban-active-critical)
![License](https://img.shields.io/badge/License-MIT-yellow)

I wanted a NAS that I actually understand. No proprietary OS, no clicking through web UIs, no mystery services running in the background. Just a plain NixOS system where every single thing is declared in config files I can read, version, and rebuild from scratch in minutes.

This repo contains the complete NixOS configuration for my home NAS — a Ugreen DXP4800 Plus running three 8TB drives in RAID5 for storage and two 128GB NVMe drives in RAID1 for the OS.

<p align="center">
  <img src="screenshots/dashboard.png" alt="nixnas-status dashboard" width="750">
  <br>
  <em>sudo nixnas-status — live system dashboard over SSH</em>
</p>

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

The entire system is ~8 files. Here's what they set up:

**Storage** — disko handles partitioning declaratively. mdadm provides RAID1 (OS) and RAID5 (data). btrfs with zstd compression on the data drives, with a monthly scrub for integrity. The ESP gets synced to both the backup NVMe and the UGOS SSD on every rebuild.

**NFS** — Two shares with fixed ports for firewall compatibility: one read-write for Proxmox backups (no_root_squash), one read-only for Jellyfin media streaming.

**Health** — smartmontools runs short self-tests daily and long tests weekly, with temperature alerts at 45/55°C. hdparm puts drives to sleep after 20 min idle and enables quiet seek mode to reduce noise.

**Security** — Fail2Ban on SSH (5 attempts → 1h ban, escalating to 48h). Firewall open only for SSH and NFS.

**Fan Control** — The DXP4800 Plus uses an ITE IT8613E chip that the mainline kernel doesn't support yet. This config builds the out-of-tree it87 module from source, loads it with `force_id=0x8613`, and a systemd service sets all fans to automatic mode on boot. Quiet at idle, ramps up under load.

**UGOS Protection** — The DXP4800 Plus ships with Ugreen's proprietary OS on an internal NVMe SSD. I keep it intact for warranty. Four independent layers make sure it's never written to: excluded from disko, udev sets it read-only by serial, a systemd service re-applies on boot, and there are no mount entries. Restoring UGOS is just a BIOS boot order change.

## Dashboard

Building a full web interface for a NAS felt like overkill — and kind of against the whole point of running a minimal NixOS system. Instead there's `nixnas-status`, a ~350 line bash script that gives you a live overview of everything that matters, right in your terminal over SSH.

It shows system stats, network, storage with usage bars, RAID health, all drives with SMART status and temperatures, NFS share status, and all services at a glance. Updates every 5 seconds without flickering (cursor repositioning instead of clear). Runs as `sudo nixnas-status`.

The script is bundled into the NixOS config via `writeShellScriptBin` — no extra installation, it's just there after a rebuild.

## Files

```
flake.nix                   # nixpkgs 25.11 + disko
configuration.nix           # boot, network, users, packages, services
disko-config.nix            # NVMe RAID1 + HDD RAID5 layout
hardware-configuration.nix  # kernel modules, CPU, firmware
modules/nfs.nix             # NFS exports and fixed ports
modules/ugos-protection.nix # 4-layer UGOS SSD protection
modules/fan-control.nix     # ITE IT8613E out-of-tree driver + auto fan curve
scripts/nixnas-status        # live SSH dashboard
```

## Storage Layout

```
NVMe RAID1 (OS) ─ /dev/md127
├── nvme0n1p2  (Patriot P300 #1)
└── nvme1n1p2  (Patriot P300 #2)
→ Mountpoint: /  (ext4, 118 GB)

HDD RAID5 (Data) ─ /dev/md126
├── sda1  (IronWolf 8TB #1)
├── sdb1  (IronWolf 8TB #2)
└── sdc1  (IronWolf 8TB #3)
→ Mountpoint: /data  (btrfs, ~14.55 TiB, compress=zstd:1)

UGOS SSD ─ /dev/nvme2n1  (READ-ONLY)
→ Original Ugreen OS, protected for warranty
→ Shared ESP hosts NixOS + UGOS bootloaders
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
git clone https://github.com/daskladas/nasdots.git /mnt/etc/nixos

# 5. Build and install (two-step workaround for a known flake bug)
nix --experimental-features "nix-command flakes" build \
  .#nixosConfigurations.nixnas.config.system.build.toplevel --store /mnt
nixos-install --root /mnt --system ./result --no-root-passwd

# 6. Copy NixOS bootloader to the UGOS SSD ESP and create EFI entry
mount /dev/nvme2n1p1 /mnt/ugos-esp
rsync -a --exclude='EFI/debian' /mnt/boot/ /mnt/ugos-esp/
efibootmgr -c -d /dev/nvme2n1 -p 1 -L "NixOS" -l '\EFI\systemd\systemd-bootx64.efi'

# 7. Reboot, remove USB, NixOS should boot
# 8. After first login: change password, verify RAID sync with cat /proc/mdstat
```

After first boot, any future changes are just:

```bash
cd /etc/nixos && sudo nixos-rebuild switch --flake .#nixnas
```

## Known Quirks

- **Patriot P300 invisible in BIOS** — the DXP4800 Plus only shows its internal NVMe slot as bootable, so the bootloader has to live on the UGOS SSD ESP
- **WatchDog reboots** — BIOS sends a 180s watchdog expecting UGOS to respond; disable it in BIOS settings
- **nixos-install crash** — `nix flake build` + `nixos-install --flake` hits an assertion error; the two-step build-then-install workaround above avoids it
- **mdadm warning** — "Neither MAILADDR nor PROGRAM" shows up in builds; cosmetic only, no impact
- **IT8613E fan chip** — needs an out-of-tree `it87` kernel module; included in this config and built automatically

## License

MIT
