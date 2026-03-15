{ config, pkgs, ... }:
{
  services.nfs.server = {
    enable = true;
    exports = ''
      /data/backup  192.168.60.0/24(rw,sync,no_subtree_check,no_root_squash)
      /data/media   192.168.60.0/24(ro,sync,no_subtree_check,root_squash) 192.168.50.0/24(ro,sync,no_subtree_check,root_squash)
    '';
    # backup: rw + no_root_squash (Proxmox needs root write access)
    # media:  ro + root_squash   (read-only, safe)
    #
    # All clients use NFSv4 – no lockdPort/mountdPort/statdPort needed.
    # For HDD spindown, mount with actimeo=3600 on the client side.
  };
}
