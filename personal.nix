# Personal configuration: SOPS secrets, personal packages, zsh personal config
{
  config,
  pkgs,
  lib,
  ...
}:
let
  # Identity names are independent of the CLI consuming the key.
  googleServiceAccounts = {
    agent = {
      secret = "google_service_account_agent";
      email = "agent-0@agent-499711.iam.gserviceaccount.com";
      project = "agent-499711";
    };
    inventory = {
      secret = "google_service_account_inventory_viewer";
      email = "viewer@inventory-project-0.iam.gserviceaccount.com";
      project = "inventory-project-0";
    };
  };
  googleCredentials = name: config.sops.secrets.${googleServiceAccounts.${name}.secret}.path;
  # Contains only public metadata and paths, never key contents.
  googleProfiles = lib.mapAttrs (
    name: account:
    pkgs.writeText "google-${name}.env" ''
      # Explicit token/account overrides must not select another identity.
      unset GOOGLE_WORKSPACE_CLI_TOKEN GOOGLE_WORKSPACE_CLI_ACCOUNT
      unset CLOUDSDK_AUTH_ACCESS_TOKEN CLOUDSDK_AUTH_ACCESS_TOKEN_FILE
      unset CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT CLOUDSDK_ACTIVE_CONFIG_NAME
      export GOOGLE_APPLICATION_CREDENTIALS=${lib.escapeShellArg (googleCredentials name)}
      export GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE="$GOOGLE_APPLICATION_CREDENTIALS"
      export CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE="$GOOGLE_APPLICATION_CREDENTIALS"
      export GOOGLE_CLOUD_PROJECT=${lib.escapeShellArg account.project}
      export GOOGLE_WORKSPACE_PROJECT_ID="$GOOGLE_CLOUD_PROJECT"
      export CLOUDSDK_CORE_PROJECT="$GOOGLE_CLOUD_PROJECT"
      export CLOUDSDK_CORE_ACCOUNT=${lib.escapeShellArg account.email}
      # Keep cached tokens and mutable CLI settings separate for each identity.
      export CLOUDSDK_CONFIG=${lib.escapeShellArg "${config.home.homeDirectory}/.config/gcloud-service-accounts/${name}"}
      export GOOGLE_WORKSPACE_CLI_CONFIG_DIR=${lib.escapeShellArg "${config.home.homeDirectory}/.config/gws-service-accounts/${name}"}
      export GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file
    ''
  ) googleServiceAccounts;
  withGoogleAccount =
    name: _:
    pkgs.writeShellApplication {
      name = "with-google-${name}";
      extraShellCheckFlags = [ "-x" ];
      text = ''
        if [ "$#" -eq 0 ]; then
          echo "Usage: with-google-${name} COMMAND [ARGS...]" >&2
          exit 2
        fi
        if [ ! -r ${lib.escapeShellArg (googleCredentials name)} ]; then
          echo "Google credentials for ${name} are unavailable; activate nix-darwin first." >&2
          exit 1
        fi
        source ${googleProfiles.${name}}
        umask 077
        exec "$@"
      '';
    };
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
      artifact = artifacts.${system} or (throw "beeper-cli: unsupported system ${system}");
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
      nativeBuildInputs = [
        pkgs.unzip
      ]
      ++ lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.autoPatchelfHook;
      buildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.stdenv.cc.cc.lib ];
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
    cosense_pat = {
      mode = "0600";
    };
    # Compatibility path for existing MYODAI scripts; same encrypted agent key.
    google_workspace_credentials = {
      key = googleServiceAccounts.agent.secret;
      mode = "0600";
    };
  }
  // lib.mapAttrs' (
    _: account: lib.nameValuePair account.secret { mode = "0600"; }
  ) googleServiceAccounts;

  # Codex CLI config is managed centrally by modules/claude-code.nix
  # (codexDefaults, tomlkit non-destructive merge). `model` is intentionally
  # left unmanaged — set it ad hoc via codex /model; rebuilds won't clobber it.

  # Personal packages
  home.packages =
    (with pkgs; [
      hidden-bar
      utm
      transmission_4
      zed-editor
      google-cloud-sdk
      gemini-rag
      beeper-cli
    ])
    ++ lib.mapAttrsToList withGoogleAccount googleServiceAccounts;

  # NOTE: purchase-research skill is now auto-enumerated by modules/claude-code.nix
  # (single repo → prompt/skills/ is the canonical source for all skills).

  # Stable interface for devShells; wrappers source these same store files.
  xdg.configFile = lib.mapAttrs' (
    name: profile: lib.nameValuePair "google-service-accounts/${name}.env" { source = profile; }
  ) googleProfiles;

  # Preserve the existing gws default; projects can select their own profile.
  home.sessionVariables = {
    GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE = googleCredentials "agent";
    GOOGLE_AGENT_CREDENTIALS_FILE = googleCredentials "agent";
    GOOGLE_INVENTORY_CREDENTIALS_FILE = googleCredentials "inventory";
  };

  home.sessionPath = [
    "/Applications/Docker.app/Contents/Resources/bin"
    "/Applications/Orca.app/Contents/Resources/bin"
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
    if [[ -z "''${COSENSE_PAT-}" && -r "${config.sops.secrets.cosense_pat.path}" ]]; then
      export COSENSE_PAT="$(${pkgs.coreutils}/bin/tr -d '\r\n' < "${config.sops.secrets.cosense_pat.path}")"
    fi
  '';

  programs.fish.interactiveShellInit = lib.mkAfter ''
    if test -z "$COSENSE_PAT"; and test -r "${config.sops.secrets.cosense_pat.path}"
      set -gx COSENSE_PAT (${pkgs.coreutils}/bin/tr -d '\r\n' < "${config.sops.secrets.cosense_pat.path}")
    end
  '';
}
