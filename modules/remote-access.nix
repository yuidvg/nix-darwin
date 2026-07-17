# Remote access: key-only SSH + mosh over Tailscale.
#
# Reached from the iPhone Moshi app via Tailscale (MagicDNS) into the OS sshd
# (Tailscale SSH stays off). The Moshi public key is declared here; nix-darwin
# writes it to /etc/ssh/nix_authorized_keys.d/<user> and wires sshd to read it
# via AuthorizedKeysCommand (sshd_config.d/101-authorized-keys.conf), so this is
# independent of ~/.ssh/authorized_keys.
#
# mosh/tmux go in environment.systemPackages (not home.packages) so they land in
# /run/current-system/sw/bin, which is reliably on the PATH of the non-login,
# non-interactive shell sshd spawns to exec mosh-server — even when USER is unset
# and the /etc/profiles/per-user/<name> path can't resolve.
{
  pkgs,
  userConfig,
  ...
}:
{
  # 1. Declare the Moshi (iPhone) public key. Private key lives only on the phone.
  users.users.${userConfig.username}.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGCXlOqHZjy5BOsXiD586MSJDZaBuec+5OZna8Gt0Hwj moshi"
  ];

  # 2. mosh (roaming/UDP) + tmux (persistent sessions).
  environment.systemPackages = [
    pkgs.mosh
    pkgs.tmux
  ];

  # 3. sshd hardening: key auth only. Numbered 200 so it is read after the
  #    nix-darwin/macOS defaults (099/100/101); for any given key sshd keeps the
  #    first value it reads, and none of those earlier files set these keys.
  environment.etc."ssh/sshd_config.d/200-moshi-hardening.conf".text = ''
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PermitRootLogin no
  '';
}
