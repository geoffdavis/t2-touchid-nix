{
  description = "Nix package and NixOS module for KaiT2en's Apple T2 Touch ID bridge (t2-touchid)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {
    self,
    nixpkgs,
  }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    packages.${system} = {
      t2-touchid = pkgs.callPackage ./package.nix {};
      default = self.packages.${system}.t2-touchid;
    };

    overlays.default = final: _prev: {
      t2-touchid = final.callPackage ./package.nix {};
    };

    nixosModules = {
      t2-touchid = import ./module.nix {inherit self;};
      default = self.nixosModules.t2-touchid;
    };

    checks.${system} = {
      package = self.packages.${system}.t2-touchid;
      # Evaluates the module against a minimal system and builds the unit
      # files, catching option and unit-generation errors without hardware.
      module =
        (nixpkgs.lib.nixosSystem {
          modules = [
            self.nixosModules.default
            {
              nixpkgs.hostPlatform = system;
              boot.loader.grub.enable = false;
              fileSystems."/" = {
                device = "none";
                fsType = "tmpfs";
              };
              system.stateVersion = "26.05";
              users.users.alice.isNormalUser = true;
              services.t2-touchid = {
                enable = true;
                bindUser = "alice";
              };
            }
          ];
        })
        .config
        .system
        .build
        .etc;
    };

    formatter.${system} = pkgs.alejandra;
  };
}
