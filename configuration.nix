{ config, pkgs, lib, ... }:
{
  # ============================================================
  # Boot
  # ============================================================
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.swraid.enable = true;

  # Sync boot files to backup ESP on second NVMe after each update
  boot.loader.systemd-boot.extraInstallCommands = ''
    # Sync to backup ESP (Patriot P300 #2)
    DEVICE="/dev/disk/by-id/nvme-Patriot_M.2_P300_128GB_P300LCBA2508221720"
    BACKUP_PART="''${DEVICE}-part1"
    ${pkgs.coreutils}/bin/mkdir -p /boot-backup
    ${pkgs.util-linux}/bin/mount "$BACKUP_PART" /boot-backup || true
    ${pkgs.rsync}/bin/rsync -a --delete /boot/ /boot-backup/ || true
    ${pkgs.util-linux}/bin/umount /boot-backup 2>/dev/null || true

    # Sync to UGOS ESP (BIOS boots from here)
    UGOS_DEV=$(${pkgs.coreutils}/bin/readlink -f /dev/disk/by-id/nvme-YSO128GTLCW-E3C-2_511250701135025164 2>/dev/null || true)
    if [ -n "$UGOS_DEV" ]; then
      ${pkgs.util-linux}/bin/blockdev --setrw "''${UGOS_DEV}" 2>/dev/null || true
      ${pkgs.util-linux}/bin/blockdev --setrw "''${UGOS_DEV}p1" 2>/dev/null || true
      ${pkgs.coreutils}/bin/mkdir -p /boot-ugos
      ${pkgs.util-linux}/bin/mount -o rw "''${UGOS_DEV}p1" /boot-ugos 2>/dev/null || true
      ${pkgs.rsync}/bin/rsync -a --delete --exclude='EFI/debian' --exclude='boot' /boot/ /boot-ugos/ 2>/dev/null || true
      ${pkgs.util-linux}/bin/umount /boot-ugos 2>/dev/null || true
      ${pkgs.util-linux}/bin/blockdev --setro "''${UGOS_DEV}p1" 2>/dev/null || true
      ${pkgs.util-linux}/bin/blockdev --setro "''${UGOS_DEV}" 2>/dev/null || true
    fi
  '';

  # ============================================================
  # Nix Settings
  # ============================================================
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  # ============================================================
  # Locale
  # ============================================================
  time.timeZone = "Europe/Berlin";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "de";

  # ============================================================
  # Network
  # ============================================================
  networking = {
    hostName = "nixnas";
    useDHCP = false;
    interfaces.enp3s0 = {
      ipv4.addresses = [{
        address = "192.168.60.3";
        prefixLength = 24;
      }];
    };
    defaultGateway = "192.168.60.1";
    nameservers = [ "192.168.60.2" "192.168.60.1" ];
    firewall = {
      enable = true;
      allowedTCPPorts = [
        22    # SSH
        2049  # NFS
      ];
      allowedUDPPorts = [
        2049  # NFS
      ];
    };
  };

  # ============================================================
  # User
  # ============================================================
  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    initialPassword = "changeme";
    # ⚠️ Change after first login: passwd
  };

  # ============================================================
  # SSH
  # ============================================================
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = true;
    };
  };

  # ============================================================
  # Terminal Environment
  # ============================================================
  environment.variables.TERM = "xterm-256color";

  # ============================================================
  # HDD Spindown & Acoustic Management
  # ============================================================
  powerManagement.powerUpCommands = ''
    # Spindown after 20 minutes idle (value 240 = 20min)
    ${pkgs.hdparm}/bin/hdparm -S 240 /dev/sda /dev/sdb /dev/sdc 2>/dev/null || true
    # Acoustic Management: 128 = quiet mode (range 128-254, lower = quieter)
    ${pkgs.hdparm}/bin/hdparm -M 128 /dev/sda /dev/sdb /dev/sdc 2>/dev/null || true
  '';

  # ============================================================
  # Fail2Ban – SSH brute-force protection
  # ============================================================
  services.fail2ban = {
    enable = true;
    maxretry = 5;
    bantime = "1h";
    bantime-increment = {
      enable = true;
      maxtime = "48h";
    };
    jails.sshd = {
      settings = {
        enabled = true;
        port = "ssh";
        filter = "sshd";
        maxretry = 5;
      };
    };
  };

  # ============================================================
  # Packages
  # ============================================================
  environment.systemPackages = with pkgs; [
    # Editors
    nano
    vim

    # System info & monitoring
    htop
    btop
    iotop
    fastfetch
    lsof
    pciutils       # lspci
    usbutils       # lsusb
    dmidecode      # hardware info
    lm_sensors

    # Disk & RAID tools
    smartmontools  # smartctl
    hdparm
    btrfs-progs
    mdadm
    parted
    gptfdisk       # gdisk, sgdisk
    nvme-cli       # nvme smart-log, etc.
    ncdu           # disk usage

    # Network tools
    ethtool        # NIC info
    iperf3         # bandwidth test
    dnsutils       # dig, nslookup

    # General utilities
    git
    tmux
    rsync
    wget
    curl
    tree
    file
    unzip
    jq
    bc
    efibootmgr

    # Dashboard tool
    (writeShellScriptBin "nixnas-status" (builtins.readFile ./scripts/nixnas-status))
  ];

  # ============================================================
  # SMART Monitoring
  # ============================================================
  services.smartd = {
    enable = true;
    autodetect = true;
    notifications.mail.enable = false;
    # Short self-test daily 04:00, long self-test Sunday 02:00
    # Temperature warning at 45°C, critical at 55°C
    defaults.monitored = "-a -o on -S on -n standby,q -s (S/../.././04|L/../../7/02) -W 4,45,55";
  };

  # ============================================================
  # btrfs Scrub – monthly data integrity check
  # ============================================================
  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/data" ];
  };

  # ============================================================
  # Data Directories
  # ============================================================
  systemd.tmpfiles.rules = [
    "d /data/backup 0755 admin users -"
    "d /data/backup/pve-lab 0755 admin users -"
    "d /data/backup/pve-proxway 0755 admin users -"
    "d /data/media 0755 admin users -"
    "d /data/media/Anime 0755 admin users -"
    "d /data/media/Filme 0755 admin users -"
    "d /data/media/Serien 0755 admin users -"
  ];

  # ============================================================
  # State Version – do NOT change after install!
  # ============================================================
  system.stateVersion = "25.11";
}
