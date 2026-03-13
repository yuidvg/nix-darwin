{
  description = "yui's nix-darwin configuration";

  inputs.nix-darwin-upstream.url = "github:plural-reality/nix-darwin";

  outputs =
    { nix-darwin-upstream, ... }:
    nix-darwin-upstream.lib.mkDownstreamFlake {
      userConfig = {
        username = "yui";
        hostname = "Yuis-MacBook-Pro";
        gitName = "Yui Nishimura";
        gitEmail = "nisshi.yui79@gmail.com";
      };
      secretsFile = ./secrets.yaml;
      modules = [
        (
          { userConfig, ... }:
          {
            home-manager.users.${userConfig.username}.imports = [ ./personal.nix ];
          }
        )
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
            # Claude Code reads this as policySettings, so /voice no longer needs
            # to mutate the Home Manager-managed ~/.claude/settings.json symlink.
            system.activationScripts.postActivation.text = lib.mkAfter ''
              ${pkgs.coreutils}/bin/install -d -m 755 "/Library/Application Support/ClaudeCode"
              ${pkgs.coreutils}/bin/install -m 644 "${claudeManagedSettings}" "/Library/Application Support/ClaudeCode/managed-settings.json"
            '';
          }
        )
      ];
    };
}
