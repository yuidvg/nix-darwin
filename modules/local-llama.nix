{
  config,
  lib,
  pkgs,
  ...
}:
let
  providers = pkgs.writeText "local-llama-providers.json" (
    builtins.toJSON {
      pi.local-llama = {
        baseUrl = "http://127.0.0.1:8080/v1";
        api = "openai-completions";
        apiKey = "local-only-unused";
        models = [
          {
            id = "local-qwen";
            name = "Local Qwen (16K; capabilities pending verification)";
            reasoning = false;
            input = [ "text" ];
            contextWindow = 16384;
            maxTokens = 4096;
            cost = {
              input = 0;
              output = 0;
              cacheRead = 0;
              cacheWrite = 0;
            };
          }
        ];
      };
      kilo.local-llama = {
        npm = "@ai-sdk/openai-compatible";
        name = "Local llama.cpp";
        options = {
          baseURL = "http://127.0.0.1:8080/v1";
          apiKey = "local-only-unused";
        };
        models.local-qwen = {
          name = "Local Qwen (16K; capabilities pending verification)";
          limit = {
            context = 16384;
            output = 4096;
          };
          modalities = {
            input = [ "text" ];
            output = [ "text" ];
          };
          reasoning = false;
          tool_call = false;
          attachment = false;
        };
      };
    }
  );
in
{
  home.packages = [
    pkgs.llama-cpp
    (import ../packages/local-llama-server.nix { inherit pkgs; })
  ];
  # These files are mutable client state. Add only our provider after approval
  # and activation; never capture existing config/auth in a store derivation.
  home.activation.localLlamaProviders = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${pkgs.python3}/bin/python3 ${../scripts/add-local-llama-provider.py} ${lib.escapeShellArg config.home.homeDirectory} ${providers}
  '';
}
