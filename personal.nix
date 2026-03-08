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

  # Codex CLI config (merge-apply: dasel put is idempotent, preserves user-added keys like [projects.*])
  home.activation.codexConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p "$HOME/.codex"
    touch "$HOME/.codex/config.toml"
    ${pkgs.dasel}/bin/dasel put -f "$HOME/.codex/config.toml" -t string -v 'gpt-5.3-codex' '.model'
    ${pkgs.dasel}/bin/dasel put -f "$HOME/.codex/config.toml" -t string -v 'xhigh' '.model_reasoning_effort'
    ${pkgs.dasel}/bin/dasel put -f "$HOME/.codex/config.toml" -t string -v 'fast' '.service_tier'
    ${pkgs.dasel}/bin/dasel put -f "$HOME/.codex/config.toml" -t string -v 'openai' '.model_provider'
    ${pkgs.dasel}/bin/dasel put -f "$HOME/.codex/config.toml" -t bool -v 'true' '.features.multi_agent'
    ${pkgs.dasel}/bin/dasel put -f "$HOME/.codex/config.toml" -t string -v 'chatgpt' '.preferred_auth_method'
    ${pkgs.dasel}/bin/dasel delete -f "$HOME/.codex/config.toml" '.model_providers.openai-env' 2>/dev/null || true
  '';

  # Personal packages
  home.packages = with pkgs; [
    hidden-bar
    utm
    transmission_4
    gemini-rag
  ];

  # Personal zsh config (ssh-agent, secrets loading)
  programs.zsh.initContent = lib.mkOrder 1100 ''
    # ssh agent
    ssh-add >/dev/null 2>/dev/null
    ssh-add --apple-use-keychain ~/.ssh/github >/dev/null 2>/dev/null

    # Load secrets from sops-nix
    [[ -r "${config.sops.secrets.openrouter_api_key.path}" ]] && \
      export OPENROUTER_API_KEY="$(cat ${config.sops.secrets.openrouter_api_key.path})"
    [[ -r "${config.sops.secrets.gemini_api_key.path}" ]] && \
      export GEMINI_API_KEY="$(cat ${config.sops.secrets.gemini_api_key.path})"
    [[ -r "${config.sops.secrets.openai_api_key.path}" ]] && \
      export OPENAI_API_KEY="$(cat ${config.sops.secrets.openai_api_key.path})"
  '';
}
