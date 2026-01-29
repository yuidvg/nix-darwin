{
  description = "Example nix-darwin system flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:nix-darwin/nix-darwin/master";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    # home manager
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # mac app util
    mac-app-util.url = "github:hraban/mac-app-util";

    # sops-nix for secrets management
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    inputs@{
      self,
      nix-darwin,
      nixpkgs,
      home-manager,
      mac-app-util,
      sops-nix,
    }:
    let
      configuration =
        { pkgs, lib, ... }:
        {
          # List packages installed in system profile. To search by name, run:
          # $ nix-env -qaP | grep wget
          environment.systemPackages = [ pkgs.vim ];

          # Necessary for using flakes on this system.
          nix = {
            settings = {
              experimental-features = "nix-command flakes";
              trusted-users = [
                "root"
                "yui"
              ];
              builders-use-substitutes = true;
              accept-flake-config = true;
            };
            linux-builder = {
              enable = true;
              ephemeral = true;
              maxJobs = 4;
              config = {
                virtualisation = {
                  darwin-builder = {
                    diskSize = 40 * 1024;
                    memorySize = 8 * 1024;
                  };
                  cores = 6;
                };
              };
            };
          };

          # Enable alternative shell support in nix-darwin.
          # programs.fish.enable = true;

          # Set Git commit hash for darwin-version.
          system.configurationRevision = self.rev or self.dirtyRev or null;

          # Used for backwards compatibility, please read the changelog before changing.
          # $ darwin-rebuild changelog
          system.stateVersion = 6;

          # The platform the configuration will be used on.
          nixpkgs.hostPlatform = "aarch64-darwin";

          ## Darwin Configurations
          # Allow unfree packages
          nixpkgs.config.allowUnfreePredicate =
            pkg:
            builtins.elem (lib.getName pkg) [
              "claude-code"
            ];

          # Define the user for home-manager
          users.users.yui = {
            name = "yui";
            home = "/Users/yui";
            shell = pkgs.zsh;
          };
          # Set primary user for homebrew and other user-specific options
          system.primaryUser = "yui";
          # System defaults configuration
          system.defaults = {
            CustomSystemPreferences."com.apple.security"."com.apple.security.authorization.ignoreArd" = true;
          };
          security.pam.services.sudo_local.touchIdAuth = true;

          # Homebrew configuration
          homebrew = {
            enable = true;
            casks = [
              "blackhole-2ch"
            ];
          };
        };
    in
    {
      # Build darwin flake using:
      # $ darwin-rebuild build --flake .#Yuis-MacBook-Pro
      darwinConfigurations."Yuis-MacBook-Pro" = nix-darwin.lib.darwinSystem {
        modules = [
          configuration
          home-manager.darwinModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.backupFileExtension = "backup";
            home-manager.users.yui = {
              imports = [
                ./home.nix
                mac-app-util.homeManagerModules.default
                sops-nix.homeManagerModules.sops
              ];
            };
          }
        ];
      };
    };
}
