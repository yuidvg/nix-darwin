{ pkgs }:
let
  llama = pkgs.llama-cpp.override {
    cudaSupport = false;
    metalSupport = pkgs.stdenv.hostPlatform.isDarwin;
  };
in
pkgs.writeShellApplication {
  name = "local-llama-server";
  text = ''
    exec ${pkgs.python3}/bin/python3 ${../scripts/local-llama-server.py} ${llama}/bin/llama-server "$@"
  '';
}
