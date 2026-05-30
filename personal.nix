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
in
{
  # SOPS secret definitions
  sops.secrets = {
    openrouter_api_key = { };
    gemini_api_key = { };
    anthropic_api_key = { };
    openai_api_key = { };
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
  ];

  # NOTE: purchase-research skill is now auto-enumerated by modules/claude-code.nix
  # (single repo → prompt/claude-code/skills/ is the canonical source for all skills).

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
