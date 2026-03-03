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
      ];
    };
}
