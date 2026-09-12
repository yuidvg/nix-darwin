{ pkgs }:
let
  asearch = pkgs.buildRubyGem {
    gemName = "asearch";
    version = "0.1.0";
    source.sha256 = "e904a01630e0d54cd7fcd12f09c7d0b02753429e9ae7c96aefe3134a35e00079";
  };
  reExpand = pkgs.buildRubyGem {
    gemName = "re_expand";
    version = "0.1.3";
    source.sha256 = "a733b050fec27703773d127f003efa9cc7deb8baee1cc29001d58e825c096952";
    gemPath = [ asearch ];
  };
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "scrapbox-cli";
  version = "0-unstable-2026-03-23";
  src = pkgs.fetchFromGitHub {
    owner = "masui";
    repo = "ScrapboxCLI";
    rev = "08dad947940620a0fdb7c3b8213cf52fc59cc511";
    hash = "sha256-A/wHcup9likQpGwFq+fAcUFOshvm/mPLLRiFzksGh5A=";
  };

  nativeBuildInputs = [ pkgs.makeWrapper ];
  buildInputs = [ pkgs.ruby ];
  dontBuild = true;

  # Upstream assumes a case-insensitive Ruby load path.
  postPatch = ''
    substituteInPlace sbexport --replace-fail "require 'JSON'" "require 'json'"
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/libexec"
    install -m755 sb* "$out/bin/"
    patchShebangs "$out/bin"

    # Upstream's external `sid` helper is not included in its repository.
    # Read the existing runtime environment; never put a cookie in the store.
    cat > "$out/libexec/sid" <<'EOF'
    #!${pkgs.runtimeShell}
    if [ -z "''${SCRAPBOX_SID-}" ]; then
      exit 0
    fi
    sid="''${SCRAPBOX_SID}"
    ${pkgs.ruby}/bin/ruby -r uri -e 'print URI.decode_www_form_component(ARGV[0])' "$sid"
    printf '\n'
    EOF
    chmod +x "$out/libexec/sid"

    for program in "$out/bin/"*; do
      wrapProgram "$program" \
        --prefix PATH : "$out/libexec:$out/bin:${
          pkgs.lib.makeBinPath [
            pkgs.wget
            pkgs.jq
            pkgs.coreutils
          ]
        }" \
        --set GEM_PATH "${reExpand}/${pkgs.ruby.gemPath}:${asearch}/${pkgs.ruby.gemPath}"
    done
    runHook postInstall
  '';

  meta = {
    description = "Command-line tools for Scrapbox";
    homepage = "https://github.com/masui/ScrapboxCLI";
    platforms = pkgs.lib.platforms.unix;
  };
}
