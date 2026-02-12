# setup.sh — Team member bootstrap for nix-darwin
# Packaged via writeShellApplication (set -euo pipefail is implicit)

# --- Helper ---
prompt_with_default() {
  local prompt_text="$1"
  local default="$2"
  local result
  if [[ -n "$default" ]]; then
    printf '%s [%s]: ' "$prompt_text" "$default" >&2
  else
    printf '%s: ' "$prompt_text" >&2
  fi
  read -r result
  echo "${result:-$default}"
}

# --- 1. Gather user info ---
echo "=== nix-darwin team setup ==="
echo ""

default_username="$(whoami)"
default_hostname="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
default_git_name="$(git config --global user.name 2>/dev/null || echo '')"
default_git_email="$(git config --global user.email 2>/dev/null || echo '')"

username="$(prompt_with_default 'Username' "$default_username")"
hostname_val="$(prompt_with_default 'Hostname' "$default_hostname")"
git_name="$(prompt_with_default 'Git name' "$default_git_name")"
git_email="$(prompt_with_default 'Git email' "$default_git_email")"
target_dir="$(prompt_with_default 'Target directory' "/private/etc/nix-darwin")"

# --- 2. Age key ---
age_key_dir="$HOME/.config/sops/age"
age_key_file="$age_key_dir/keys.txt"

if [[ ! -f "$age_key_file" ]]; then
  echo ""
  echo "Generating age key pair..."
  mkdir -p "$age_key_dir"
  age-keygen -o "$age_key_file"
fi

age_public_key="$(age-keygen -y "$age_key_file")"
echo ""
echo "Age public key: $age_public_key"

# --- 3. API keys (optional) ---
echo ""
echo "Enter API keys (leave blank to skip):"
openrouter_key="$(prompt_with_default 'OpenRouter API key' '')"
gemini_key="$(prompt_with_default 'Gemini API key' '')"
anthropic_key="$(prompt_with_default 'Anthropic API key' '')"

# --- 4. Guard against overwriting ---
if [[ -d "$target_dir/.git" ]]; then
  echo ""
  echo "Error: $target_dir already contains a git repository." >&2
  echo "Remove it or choose a different directory." >&2
  exit 1
fi

# --- 5. Generate files ---
# /private/etc requires root; create dir and hand ownership to current user
if [[ ! -d "$target_dir" ]]; then
  sudo mkdir -p "$target_dir"
  sudo chown "$(whoami)" "$target_dir"
fi

# flake.nix
cat > "$target_dir/flake.nix" << FLAKE
{
  description = "${username}'s nix-darwin configuration";
  inputs.nix-darwin-upstream.url = "github:yuidvg/nix-darwin";
  outputs = { nix-darwin-upstream, ... }: {
    darwinConfigurations."${hostname_val}" = nix-darwin-upstream.lib.mkSystem {
      userConfig = {
        username = "${username}";
        hostname = "${hostname_val}";
        gitName = "${git_name}";
        gitEmail = "${git_email}";
      };
      secretsFile = ./secrets.yaml;
      # extraHomeModules = [];
      # extraDarwinModules = [];
    };
  };
}
FLAKE

# .sops.yaml
cat > "$target_dir/.sops.yaml" << SOPS
creation_rules:
  - path_regex: secrets\\.yaml\$
    age: >-
      ${age_public_key}
SOPS

# secrets.yaml (plaintext → encrypt)
cat > "$target_dir/secrets.yaml" << SECRETS
openrouter_api_key: "${openrouter_key}"
gemini_api_key: "${gemini_key}"
anthropic_api_key: "${anthropic_key}"
SECRETS

SOPS_AGE_KEY_FILE="$age_key_file" sops --encrypt --in-place "$target_dir/secrets.yaml"

# .gitignore
cat > "$target_dir/.gitignore" << 'GITIGNORE'
result
result-*
secrets.yaml.plain
.DS_Store
GITIGNORE

# apply
cat > "$target_dir/apply" << 'APPLY'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
nix flake update
sudo darwin-rebuild switch --flake .
APPLY
chmod +x "$target_dir/apply"

# --- 6. Git init ---
git -C "$target_dir" init
git -C "$target_dir" add -A
git -C "$target_dir" commit -m "Initial nix-darwin configuration"

echo ""
echo "=== Setup complete ==="
echo "Directory: $target_dir"
echo ""
echo "Next steps:"
echo "  cd $target_dir"
echo "  ./apply"
