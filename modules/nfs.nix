{ config, pkgs, ... }:
{
  services.nfs.server = {
    enable = true;
    # Fixed ports so firewall can allow them (NFSv3 needs these)
    lockdPort = 4001;
    mountdPort = 4002;
    statdPort = 4000;
    exports = ''
      /data/backup  192.168.60.0/24(rw,sync,no_subtree_check,no_root_squash)
      /data/media   192.168.60.0/24(ro,sync,no_subtree_check,root_squash) 192.168.50.0/24(ro,sync,no_subtree_check,root_squash)
    '';
    # backup: rw + no_root_squash (Proxmox needs root write access)
    # media:  ro + root_squash   (read-only, safe)
  };
}
