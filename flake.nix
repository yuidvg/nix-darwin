{
  description = "yui's nix-darwin configuration";

  inputs.nix-darwin-upstream.url = "github:plural-reality/nix-darwin";

  outputs =
    { nix-darwin-upstream, ... }:
    {
      darwinConfigurations."Yuis-MacBook-Pro" = nix-darwin-upstream.lib.mkSystem {
        userConfig = {
          username = "yui";
          hostname = "Yuis-MacBook-Pro";
          gitName = "Yui Nishimura";
          gitEmail = "nisshi.yui79@gmail.com";
        };
        secretsFile = ./secrets.yaml;
        extraHomeModules = [
          ./personal.nix
        ];
      };
    };
}
