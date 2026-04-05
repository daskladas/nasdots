{
  description = "NixNAS – NixOS NAS Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, ... }: {
    nixosConfigurations.nixnas = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        disko.nixosModules.disko
        ./disko-config.nix
        ./configuration.nix
        ./hardware-configuration.nix
        ./modules/nfs.nix
        ./modules/ugos-protection.nix
        ./modules/fan-control.nix
        ./modules/hdd-fan-control.nix
      ];
    };
  };
}
