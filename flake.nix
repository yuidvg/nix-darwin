{
  description = "yui's nix-darwin configuration";

  inputs = {
    nixpkgs.url = "github:numtide/nixpkgs-unfree?ref=nixos-unstable";
    nix-darwin.url = "github:nix-darwin/nix-darwin/master";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager/master";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    mac-app-util.url = "github:hraban/mac-app-util";

    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    # Rust nightly toolchain (required by screenpipe's edition2024 dependency)
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";

    # Screenpipe: raw source (no flake.nix upstream)
    screenpipe-src.url = "github:screenpipe/screenpipe/v0.3.135";
    screenpipe-src.flake = false;

    # Kimi Code CLI agent
    kimi-cli.url = "github:MoonshotAI/kimi-cli";

    # AI coding agents: Claude Code, Codex, etc. (daily auto-updated overlay)
    llm-agents.url = "github:numtide/llm-agents.nix";

    # Haskell Dev Environment
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
      system = "aarch64-darwin";

      # Single tenant: this flake configures exactly one machine (yui's).
      # No mkSystem/mkDownstreamFlake indirection — the config is inlined below.
      userConfig = {
        username = "yui";
        hostname = "Yuis-MacBook-Pro";
        gitName = "Yui Nishimura";
        gitEmail = "nisshi.yui79@gmail.com";
      };
      secretsFile = ./secrets.yaml;
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

          # XcodeBuildMCP: hermetic MCP server (no npx)
          packages.xcodebuildmcp = import ./packages/xcodebuildmcp { inherit pkgs; };

          # CodeLayer: AI coding agent (macOS .app + CLI)
          packages.codelayer = import ./packages/codelayer { inherit pkgs; };

          # Screenpipe: standalone build via `nix build .#screenpipe`
          packages.screenpipe =
            let
              pkgsWithRust = pkgs.extend inputs.rust-overlay.overlays.default;
            in
            import ./packages/screenpipe {
              pkgs = pkgsWithRust;
              screenpipe-src = inputs.screenpipe-src;
            };

          # Claude Code skills → Claude Desktop uploadable ZIPs
          packages.desktop-skills = import ./packages/desktop-skills {
            inherit pkgs;
            skillsDir = ./prompt/claude-code/skills;
          };

          # Copy skill ZIPs to ~/Desktop (or custom dir)
          # Usage: nix run .#zip-skills [-- /path/to/output]
          packages.zip-skills = pkgs.writeShellApplication {
            name = "zip-skills";
            text = ''
              OUTDIR="''${1:-$HOME/Desktop}/claude-skills"
              mkdir -p "$OUTDIR"

              echo "Copying skill ZIPs to $OUTDIR ..."

              copied=()
              for zip in "${self'.packages.desktop-skills}"/*.zip; do
                name=$(basename "$zip")
                cp -f "$zip" "$OUTDIR/$name"
                copied+=("$name")
                echo "  $name"
              done

              echo ""
              echo "=== ''${#copied[@]} skill ZIPs exported to $OUTDIR ==="
            '';
          };

          apps.zip-skills = {
            type = "app";
            program = "${self'.packages.zip-skills}/bin/zip-skills";
          };

          # Formatter for the flake itself
          formatter = pkgs.nixfmt;
        };

      flake.darwinConfigurations.${userConfig.hostname} = nix-darwin.lib.darwinSystem {
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
              nix = {
                settings = {
                  experimental-features = "nix-command flakes";
                  trusted-users = [
                    "root"
                    userConfig.username
                  ];
                  builders-use-substitutes = true;
                  accept-flake-config = true;
                  extra-substituters = [
                    "https://cache.numtide.com"
                    "https://devenv.cachix.org"
                  ];
                  extra-trusted-public-keys = [
                    "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
                    "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
                  ];
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

              system.configurationRevision = self.rev or self.dirtyRev or null;
              system.stateVersion = 6;
              nixpkgs.hostPlatform = system;

              nixpkgs.overlays = [
                inputs.llm-agents.overlays.default
                # onnxruntime 1.23.2 test code fails with -Werror on macOS (nodiscard warning in graph_test.cc)
                (final: prev: {
                  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
                    (pyFinal: pyPrev: {
                      onnxruntime = pyPrev.onnxruntime.overrideAttrs (_: {
                        doCheck = false;
                      });
                      # pydub only needs ffmpeg/ffplay/ffprobe. Avoid ffmpeg-full's
                      # kvazaar check path on Darwin while preserving pydub behavior.
                      pydub = pyPrev.pydub.override { ffmpeg-full = final.ffmpeg; };
                      # speechrecognition's test closure builds optional whisper backends;
                      # openai-whisper's audio test fails under the Darwin sandbox.
                      speechrecognition = pyPrev.speechrecognition.overridePythonAttrs (_: {
                        doCheck = false;
                      });
                    })
                  ];
                })
              ];
              nixpkgs.config.allowUnfreePredicate =
                pkg:
                builtins.elem (lib.getName pkg) [
                  "claude"
                  "claude-code"
                ];

              users.users.${userConfig.username} = {
                name = userConfig.username;
                home = "/Users/${userConfig.username}";
                shell = pkgs.zsh;
              };
              system.primaryUser = userConfig.username;
              system.defaults = {
                CustomSystemPreferences."com.apple.security"."com.apple.security.authorization.ignoreArd" = true;
              };
              security.pam.services.sudo_local.touchIdAuth = true;

              homebrew = {
                enable = true;
              };
            }
          )

          inputs.home-manager.darwinModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.backupFileExtension = "backup";
            home-manager.extraSpecialArgs = {
              inherit userConfig secretsFile;
            };
            home-manager.users.${userConfig.username} =
              {
                config,
                lib,
                pkgs,
                ...
              }:
              {
                home.packages = [
                  inputs.kimi-cli.packages.${system}.default
                  (import ./packages/codelayer { inherit pkgs; })
                ];

                imports = [
                  inputs.mac-app-util.homeManagerModules.default
                  ./modules/base.nix
                  ./modules/claude-code.nix
                  ./modules/shared-scripts.nix
                  ./personal.nix
                ]
                ++ (nixpkgs.lib.optional (secretsFile != null) inputs.sops-nix.homeManagerModules.sops);

                programs.home-manager.enable = true;
                home.username = userConfig.username;
                home.homeDirectory = "/Users/${userConfig.username}";
                home.stateVersion = "24.05";

                sops = lib.mkIf (secretsFile != null) {
                  age.keyFile = "${config.home.homeDirectory}/.config/sops/age/keys.txt";
                  defaultSopsFile = secretsFile;
                };
                launchd.agents.sops-nix.config.EnvironmentVariables.PATH = lib.mkIf (secretsFile != null) (
                  lib.mkForce "/usr/bin:/bin:/usr/sbin:/sbin"
                );
              };
          }

          # Claude Code reads this as policySettings, so /voice no longer needs
          # to mutate the Home Manager-managed ~/.claude/settings.json symlink.
          (
            { pkgs, lib, ... }:
            let
              claudeManagedSettings = pkgs.writeText "claude-managed-settings.json" (
                builtins.toJSON {
                  voiceEnabled = true;
                }
              );
            in
            {
              system.activationScripts.postActivation.text = lib.mkAfter ''
                ${pkgs.coreutils}/bin/install -d -m 755 "/Library/Application Support/ClaudeCode"
                ${pkgs.coreutils}/bin/install -m 644 "${claudeManagedSettings}" "/Library/Application Support/ClaudeCode/managed-settings.json"
              '';
            }
          )
        ];
      };
    };
}
