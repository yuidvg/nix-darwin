# Personal configuration: SOPS secrets, personal packages, zsh personal config
{
  config,
  pkgs,
  lib,
  ...
}:
let
  gemini-rag = pkgs.writeScriptBin "gemini-rag" ''
    #!/bin/sh
    if [ -z "$GEMINI_API_KEY" ] && [ -r "${config.sops.secrets.gemini_api_key.path}" ]; then
      export GEMINI_API_KEY="$(cat ${config.sops.secrets.gemini_api_key.path})"
    fi
    exec ${pkgs.deno}/bin/deno run --allow-all ${./scripts/gemini-rag.ts} "$@"
  '';

  # Official Beeper CLI — talks to the local Beeper Desktop API (localhost:23373).
  # The npm `beeper-cli` package is a launcher shim that downloads a bun-compiled
  # standalone binary into ~/.cache at first run (impure runtime fetch). We discard
  # the shim and pin the binary itself by content hash: shim(runtime) -> fetchurl(build).
  # Artifact metadata mirrors the upstream binaries.json for v0.6.2.
  beeper-cli =
    let
      version = "0.6.2";
      artifacts = {
        aarch64-darwin = {
          file = "beeper-cli-${version}-macos-arm64.zip";
          hash = "sha256-aIzN5+fQRNM5gM0GR0vxrnIVzPjKeZZyYvo7+4WiWJo=";
        };
        x86_64-darwin = {
          file = "beeper-cli-${version}-macos-x64.zip";
          hash = "sha256-QROhl5z714OfFHQxWOcMEu+pQTE6+3erKxGggwkZYYY=";
        };
        aarch64-linux = {
          file = "beeper-cli-${version}-linux-arm64.tar.gz";
          hash = "sha256-K9NwQ6TthjYh7cWeKKqmUugZPlWryg6Ud/Wurhxl1ik=";
        };
        x86_64-linux = {
          file = "beeper-cli-${version}-linux-x64.tar.gz";
          hash = "sha256-qIHh0ryR4xIYslFxZkTsX40WHVzLMOfqtmzyumQQUR0=";
        };
      };
      inherit (pkgs.stdenv.hostPlatform) system;
      artifact =
        artifacts.${system} or (throw "beeper-cli: unsupported system ${system}");
    in
    pkgs.stdenvNoCC.mkDerivation {
      pname = "beeper-cli";
      inherit version;
      src = pkgs.fetchurl {
        url = "https://github.com/beeper/cli/releases/download/v${version}/${artifact.file}";
        inherit (artifact) hash;
      };
      sourceRoot = ".";
      # The binary is a 117MB self-contained executable with data appended after the
      # Mach-O image and a hardened-runtime signature; stripping/patching corrupts both.
      dontStrip = true;
      nativeBuildInputs =
        [ pkgs.unzip ]
        ++ lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.autoPatchelfHook;
      buildInputs =
        lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.stdenv.cc.cc.lib ];
      installPhase = ''
        runHook preInstall
        install -Dm755 bin/beeper $out/bin/beeper
        runHook postInstall
      '';
      meta = {
        description = "Official Beeper CLI — one CLI for all your chats, via the local Beeper Desktop API";
        homepage = "https://github.com/beeper/cli";
        mainProgram = "beeper";
        platforms = builtins.attrNames artifacts;
      };
    };
in
{
  # SOPS secret definitions
  sops.secrets = {
    openrouter_api_key = { };
    gemini_api_key = { };
    anthropic_api_key = { };
    openai_api_key = { };
    # Google service-account JSON for the `gws` CLI. Decrypted by sops-nix to a
    # stable runtime path; GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE points at it.
    google_workspace_credentials = { };
  };

  # Codex CLI config is managed centrally by modules/claude-code.nix
  # (codexDefaults, tomlkit non-destructive merge). `model` is intentionally
  # left unmanaged — set it ad hoc via codex /model; rebuilds won't clobber it.

  # Personal packages
  home.packages = with pkgs; [
    hidden-bar
    utm
    transmission_4
    gemini-rag
    beeper-cli
  ];

  # NOTE: purchase-research skill is now auto-enumerated by modules/claude-code.nix
  # (single repo → prompt/claude-code/skills/ is the canonical source for all skills).

  # gws reads the service-account JSON from this path (sops-nix decrypts it there).
  # Pairs with GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND="file" set in modules/base.nix.
  home.sessionVariables = {
    GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE = config.sops.secrets.google_workspace_credentials.path;
  };

  home.sessionPath = [
    "/Applications/Docker.app/Contents/Resources/bin"
  ];

  programs.git.settings = {
    core.sshCommand = "ssh -o AddKeysToAgent=yes -o UseKeychain=yes -o IdentitiesOnly=yes -i $HOME/.ssh/github";
    url."git@github.com:".insteadOf = "https://github.com/";
  };

  # Personal zsh config (secrets loading)
  programs.zsh.initContent = lib.mkOrder 1100 ''
    # Load secrets from sops-nix
    [[ -r "${config.sops.secrets.openrouter_api_key.path}" ]] && \
      export OPENROUTER_API_KEY="$(cat ${config.sops.secrets.openrouter_api_key.path})"
    [[ -r "${config.sops.secrets.gemini_api_key.path}" ]] && \
      export GEMINI_API_KEY="$(cat ${config.sops.secrets.gemini_api_key.path})"
    [[ -r "${config.sops.secrets.openai_api_key.path}" ]] && \
      export OPENAI_API_KEY="$(cat ${config.sops.secrets.openai_api_key.path})"
  '';
}
