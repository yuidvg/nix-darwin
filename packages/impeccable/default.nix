{ pkgs }:
let
  version = "0.1.16";
  platform =
    {
      aarch64-darwin = {
        asset = "darwin-arm64";
        hash = "sha256:5c00c3130b961f3aa1066f04ed0e1f58e87808ad153efa00f1c44184800084f2";
      };
      x86_64-darwin = {
        asset = "darwin-x64";
        hash = "sha256:278b028848348b4dc21a20ee0a0bb33f09a8d14c5484b1a2f554df32e1d44f43";
      };
    }
    .${pkgs.stdenv.hostPlatform.system};
  src = pkgs.fetchurl {
    url = "https://github.com/pbakaus/impeccable/releases/download/engine-v${version}/impeccable-${platform.asset}";
    inherit (platform) hash;
  };
in
pkgs.runCommand "impeccable-${version}"
  {
    meta.platforms = [
      "aarch64-darwin"
      "x86_64-darwin"
    ];
  }
  ''
    mkdir -p "$out/bin"
    install -m755 ${src} "$out/bin/impeccable"
  ''
