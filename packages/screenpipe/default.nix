# Screenpipe: 24/7 Screen & Audio Recording with AI
# Requires rust-overlay applied to pkgs (for pkgs.rust-bin.nightly)
{ pkgs, screenpipe-src }:
let
  rustToolchain = pkgs.rust-bin.nightly.latest.default;
  rustPlatform = pkgs.makeRustPlatform {
    cargo = rustToolchain;
    rustc = rustToolchain;
  };
in
rustPlatform.buildRustPackage {
  pname = "screenpipe";
  version = "0.3.135";
  src = screenpipe-src;

  # cpal-0.15.3 exists both on crates.io (via rodio) and as a screenpipe
  # git fork. Nix vendor dirs can't hold two dirs with the same name-version.
  # This patch unifies both on the git fork before vendoring.
  cargoPatches = [ ./patches/deduplicate-cpal.patch ];

  useFetchCargoVendor = true;
  cargoHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

  nativeBuildInputs = with pkgs; [
    makeWrapper
    pkg-config
    protobuf
    perl
    cmake
    clang
    xcbuild
  ];

  buildInputs =
    with pkgs;
    [
      openssl
      sqlite
      ffmpeg
      bun
    ]
    ++ lib.optionals stdenv.isDarwin [
      pkgs.apple-sdk_15
    ];

  doCheck = false;

  postInstall = ''
    wrapProgram $out/bin/screenpipe \
      --prefix PATH : ${
        pkgs.lib.makeBinPath [
          pkgs.ffmpeg
          pkgs.bun
        ]
      }
  '';

  meta = with pkgs.lib; {
    description = "24/7 Screen & Audio Recording with AI";
    homepage = "https://github.com/screenpipe/screenpipe";
    license = licenses.mit;
  };
}
