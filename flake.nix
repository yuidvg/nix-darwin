{
  description = "Example nix-darwin system flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nix-darwin.url = "github:nix-darwin/nix-darwin/nix-darwin-25.11";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager/release-25.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    mac-app-util.url = "github:hraban/mac-app-util";

    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    # New inputs for Haskell Dev Environment
    flake-parts.url = "github:hercules-ci/flake-parts";
    haskell-flake.url = "github:srid/haskell-flake";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      nix-darwin,
      flake-parts,
      haskell-flake,
      ...
    }:
    let
      # ==========================================
      # 🛠️ USER CONFIGURATION (Single Source of Truth)
      # ==========================================
      userConfig = {
        username = "yui"; # ユーザー名 (whoami)
        hostname = "Yuis-MacBook-Pro"; # ホスト名 (scutil --get LocalHostName)
        gitName = "Yui Nishimura"; # Git Name
        gitEmail = "nisshi.yui79@gmail.com"; # Git Email
        # identityFile = "/Users/yui/.ssh/id_ed25519"; # (Optional: Future use)
      };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      imports = [ inputs.haskell-flake.flakeModule ];

      perSystem =
        {
          self',
          pkgs,
          config,
          ...
        }:
        {
          # Haskell Configuration via haskell-flake
          haskellProjects.default = {
            # The scripts directory containing the .cabal file
            projectRoot = ./scripts;

            devShell = {
              enable = true;
              tools = hp: {
                haskell-language-server = hp.haskell-language-server;
                fourmolu = hp.fourmolu;
                cabal-gild = pkgs.haskellPackages.cabal-gild;
              };
              hlsCheck.enable = true;
              hoogle = false;
            };
          };

          # Default devShell
          # devShells.default is automatically defined by haskell-flake

          # Formatter for the flake itself
          formatter = pkgs.nixfmt;
        };

      flake = {
        # Darwin configurations
        darwinConfigurations."${userConfig.hostname}" = nix-darwin.lib.darwinSystem {
          # Inject userConfig into all modules (Darwin & Home Manager)
          specialArgs = {
            inherit userConfig;
          };

          modules = [
            (
              {
                pkgs,
                lib,
                userConfig,
                ...
              }:
              {
                # List packages installed in system profile.
                environment.systemPackages = [ pkgs.vim ];

                # Necessary for using flakes on this system.
                nix = {
                  settings = {
                    experimental-features = "nix-command flakes";
                    trusted-users = [
                      "root"
                      userConfig.username
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

                # Set Git commit hash for darwin-version.
                system.configurationRevision = self.rev or self.dirtyRev or null;

                # Used for backwards compatibility
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
                users.users.${userConfig.username} = {
                  name = userConfig.username;
                  home = "/Users/${userConfig.username}";
                  shell = pkgs.zsh;
                };
                # Set primary user for homebrew and other user-specific options
                system.primaryUser = userConfig.username;
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
              }
            )

            inputs.home-manager.darwinModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.backupFileExtension = "backup";
              # Explicitly inject userConfig into Home Manager modules
              home-manager.extraSpecialArgs = {
                inherit userConfig;
              };
              home-manager.users.${userConfig.username} = {
                imports = [
                  ./home.nix
                  inputs.mac-app-util.homeManagerModules.default
                  inputs.sops-nix.homeManagerModules.sops
                ];
              };
            }
          ];
        };
      };
    };
}
