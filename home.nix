{ config, pkgs, lib, mac-app-util, ... }:
{
  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  # Home Manager needs a bit of information about you and the
  # paths it should manage.
  home.username = "yui";
  home.homeDirectory = "/Users/yui";

  # This value determines the Home Manager release that your
  # configuration is compatible with. This helps avoid breakage
  # when a new Home Manager release introduces backwards
  # incompatible changes.
  home.stateVersion = "24.05";

  # Packages that should be installed to the user profile.
  home.packages = with pkgs; [
    # nix tools
    nixfmt-classic

    # Development tools
    nodejs # Node.js runtime (was: node)
    bun # Fast JavaScript runtime and package manager

    # Media processing tools
    ffmpeg # Video/audio processing (was: ffmpeg)
    imagemagick # Image manipulation (was: imagemagick)
    poppler # PDF utilities (was: poppler)

    # System utilities
    fdupes # Find duplicate files (was: fdupes)
    yt-dlp # YouTube downloader (was: yt-dlp)
    openvpn

    # former node packages
    claude-code
    codex

    # gui apps
    hidden-bar
    utm
    transmission_4
    discord
  ];

  # Programs configuration
  programs = {
    # Enable and configure git
    git = {
      enable = true;
      userName = "Yui Nishimura";
      userEmail = "nisshi.yui79@gmail.com";
      extraConfig = {
        init.defaultBranch = "master";
        pull.rebase = true;
        filter.lfs = {
          process = "git-lfs filter-process";
          required = true;
          clean = "git-lfs clean -- %f";
          smudge = "git-lfs smudge -- %f";
        };
      };
    };

    # Enable and configure zsh
    zsh = let gitPromptScript = ./script/git-prompt.sh;
    in {
      enable = true;
      enableCompletion = true;
      autosuggestion.enable = true;
      autosuggestion.strategy = [ "history" "completion" "match_prev_cmd" ];
      syntaxHighlighting.enable = true;
      autocd = true;
      shellAliases = {
        ll = "ls -l";
        la = "ls -la";
        lt = "tree";
        remake = "make -j clean && make -j";
      };
      initContent = let
        initExtraBeforeCompInit = lib.mkOrder 550 ''
          # Add completion to fpath
          fpath=(/Users/yui/.docker/completions $fpath)
        '';

        initExtra = lib.mkOrder 1000 ''
          # Source git prompt script
          source ${gitPromptScript}
          GIT_PS1_SHOWUPSTREAM="verbose"
          precmd () { __git_ps1 "%F{cyan}%~%f%F{blue}" "%s %f" }

          # ssh agent
          ssh-add >/dev/null 2>/dev/null
          ssh-add --apple-use-keychain ~/.ssh/github >/dev/null 2>/dev/null
        '';
      in lib.mkMerge [ initExtraBeforeCompInit initExtra ];
    };

    gh = { enable = true; };

    vscode.enable = true;
  };

  services.ollama.enable = true;

  # Environment variables
  home.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
    PAGER = "less";
    LESS = "-R";
  };

  #Settings
  targets.darwin.defaults."com.apple.dock".autohide = true;
  targets.darwin.defaults."com.apple.dock".orientation = "bottom";
  targets.darwin.defaults.NSGlobalDomain.AppleShowAllExtensions = true;
  targets.darwin.defaults."com.apple.finder" = {
    FXPreferredViewStyle = "clmv";
    _FXShowPosixPathInTitle = true;
  };
}
