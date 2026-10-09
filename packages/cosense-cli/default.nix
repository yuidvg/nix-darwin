{ pkgs }:

(pkgs.buildNpmPackage.override { nodejs = pkgs.nodejs_24; }) rec {
  pname = "cosense-cli";
  version = "1.16.1";

  src = pkgs.fetchurl {
    url = "https://registry.npmjs.org/@helpfeel/cosense-cli/-/cosense-cli-${version}.tgz";
    hash = "sha256-gGtsUl4jBq38iB7ZAbKZur56pI0LWcFlJNHx/sULBWc=";
  };

  sourceRoot = "package";

  # Published sources run through tsx; the matching upstream lockfile pins
  # tsx, esbuild, and its platform binaries without runtime npm downloads.
  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  npmFlags = [
    "--ignore-scripts"
    "--omit=dev"
  ];
  dontNpmBuild = true;
  npmDepsHash = "sha256-m5dAqcFp/0mZ48XekZjP7jTb1GFuZdepFveF6aHhPmY=";

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    "$out/bin/cosense" --version
    "$out/bin/cosense" --help > /dev/null
    runHook postInstallCheck
  '';

  meta = {
    description = "Official Cosense CLI and agent skill harness";
    homepage = "https://github.com/helpfeel/cosense-cli";
    license = pkgs.lib.licenses.mit;
    mainProgram = "cosense";
    platforms = pkgs.lib.platforms.unix;
  };
}
