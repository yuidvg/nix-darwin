{
  config,
  pkgs,
  lib,
  mac-app-util,
  ...
}:
let
  # 1. 必要なライブラリを含んだPython環境を定義
  #    ※ python313Packages があるなら明示的に python313 を使うのが安全です
  markthesedownPythonEnv = pkgs.python313.withPackages (ps: [
    ps.markitdown
    ps.openai
    ps.openpyxl
    ps.python-pptx
    ps.youtube-transcript-api
    ps.speechrecognition
    ps.pydub
    ps.requests
    ps.pandas
    ps.beautifulsoup4
  ]);

  # 2. Pythonファイルの中身を読み込んで、実行可能なスクリプトとしてパッケージ化
  #    ./scripts/markthesedown.py はこの home.nix からの相対パスです
  markthesedown = pkgs.writeScriptBin "markthesedown" ''
    #!${markthesedownPythonEnv}/bin/python
    ${builtins.readFile ./scripts/markthesedown.py}
  '';

  # スクレイピング・URL収集用環境
  webScrapingPythonEnv = pkgs.python313.withPackages (ps: [
    ps.requests
    ps.beautifulsoup4
    ps.trafilatura
    ps.slack-sdk
  ]);

  urls-under = pkgs.writeScriptBin "urls-under" ''
    #!${webScrapingPythonEnv}/bin/python
    ${builtins.readFile ./scripts/urls-under.py}
  '';

  urls2contents = pkgs.writeScriptBin "urls2contents" ''
    #!${webScrapingPythonEnv}/bin/python
    ${builtins.readFile ./scripts/urls2contents.py}
  '';

  download-slack-channel-files = pkgs.writeScriptBin "download-slack-channel-files" ''
    #!${webScrapingPythonEnv}/bin/python
    ${builtins.readFile ./scripts/download-slack-channel-files.py}
  '';
in
{
  # ========================================
  # SOPS: Secrets Management
  # ========================================
  sops = {
    # Age 秘密鍵のパス (手動で設置済み)
    age.keyFile = "${config.home.homeDirectory}/.config/sops/age/keys.txt";

    # 暗号化された secrets ファイル
    defaultSopsFile = ./secrets.yaml;

    # 復号されたシークレットの定義
    secrets = {
      openrouter_api_key = { };
    };
  };

  # sops-nix launchd service needs PATH to find getconf
  launchd.agents.sops-nix.config.EnvironmentVariables.PATH =
    lib.mkForce "/usr/bin:/bin:/usr/sbin:/sbin";

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
    nixfmt-rfc-style
    nil

    nixos-generators

    # Development tools
    nodejs # Node.js runtime (was: node)
    bun # Fast JavaScript runtime and package manager
    # haskell-language-server
    # ghc
    # hlint
    # cabal-install
    # zlib
    # haskellPackages.zlib
    # pkg-config

    # Media processing tools
    ffmpeg # Video/audio processing (was: ffmpeg)
    imagemagick # Image manipulation (was: imagemagick)
    poppler # PDF utilities (was: poppler)
    python313Packages.markitdown
    markthesedown
    urls-under
    urls2contents
    download-slack-channel-files

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
    zsh =
      let
        gitPromptScript = ./scripts/git-prompt.sh;
      in
      {
        enable = true;
        enableCompletion = true;
        autosuggestion.enable = true;
        autosuggestion.strategy = [
          "history"
          "completion"
          "match_prev_cmd"
        ];
        syntaxHighlighting.enable = true;
        autocd = true;
        shellAliases = {
          ll = "ls -l";
          la = "ls -la";
          lt = "tree";
          remake = "make -j clean && make -j";
        };
        initContent =
          let
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

              # Load secrets from sops-nix (Layer 2: Wiring)
              # File -> Environment Variable conversion
              [[ -r "${config.sops.secrets.openrouter_api_key.path}" ]] && \
                export OPENROUTER_API_KEY="$(cat ${config.sops.secrets.openrouter_api_key.path})"
            '';
          in
          lib.mkMerge [
            initExtraBeforeCompInit
            initExtra
          ];
      };

    direnv = {
      enable = true;
      enableZshIntegration = true;
      nix-direnv.enable = true;
    };

    gh = {
      enable = true;
    };
  };

  services.ollama.enable = true;

  # Environment variables
  home.sessionVariables = {
    MANPATH = ":/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/share/man";
    SHELL = "zsh";
    EDITOR = "nvim";
    VISUAL = "nvim";
    PAGER = "less";
    LESS = "-R";
  };
  home.sessionPath = [
    "${config.home.homeDirectory}/.local/bin"
  ];

  #Settings
  targets.darwin.defaults."com.apple.dock".autohide = true;
  targets.darwin.defaults."com.apple.dock".orientation = "bottom";
  targets.darwin.defaults.NSGlobalDomain.AppleShowAllExtensions = true;
  targets.darwin.defaults."com.apple.finder" = {
    FXPreferredViewStyle = "clmv";
    _FXShowPosixPathInTitle = true;
  };
}
