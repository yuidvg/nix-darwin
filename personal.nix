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

  # Codex CLI config (merge-apply: grep out managed keys, prepend canonical values, preserve user-added keys)
  home.activation.codexConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    CODEX_CONFIG="$HOME/.codex/config.toml"
    mkdir -p "$HOME/.codex"
    touch "$CODEX_CONFIG"

    # Strip managed keys + empty [model_providers.openai-env] section, keep everything else
    ${pkgs.gnugrep}/bin/grep -v -E '^(model|model_reasoning_effort|service_tier|model_provider|preferred_auth_method)[[:space:]]*=' "$CODEX_CONFIG" \
      | ${pkgs.gnugrep}/bin/grep -v -E '^\[model_providers\.openai-env\]' \
      > "$CODEX_CONFIG.body" || true

    {
      echo 'model = "gpt-5.3-codex"'
      echo 'model_reasoning_effort = "xhigh"'
      echo 'service_tier = "fast"'
      echo 'model_provider = "openai"'
      echo 'preferred_auth_method = "chatgpt"'
      echo
      cat "$CODEX_CONFIG.body"
    } > "$CODEX_CONFIG.tmp"
    mv "$CODEX_CONFIG.tmp" "$CODEX_CONFIG"
    rm -f "$CODEX_CONFIG.body"

    # Ensure [features] section with multi_agent
    if ! ${pkgs.gnugrep}/bin/grep -q '^\[features\]' "$CODEX_CONFIG"; then
      printf '\n[features]\nmulti_agent = true\n' >> "$CODEX_CONFIG"
    fi
  '';

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
