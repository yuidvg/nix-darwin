{ pkgs }:

pkgs.buildNpmPackage rec {
  pname = "cosense-mcp-server";
  version = "0.4.0";

  src = pkgs.fetchurl {
    url = "https://registry.npmjs.org/@yosider/cosense-mcp-server/-/cosense-mcp-server-0.4.0.tgz";
    hash = "sha256-R7Xj/4hKDFeorIL1X0sidDHuJ8fHCXJOodT79+gUljQ=";
  };

  sourceRoot = "package";

  # Upstream tarball ships compiled JS in build/, so dependencies only.
  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  npmFlags = [
    "--ignore-scripts"
    "--omit=dev"
  ];
  dontNpmBuild = true;
  npmDepsHash = "sha256-Uq9BqxyaI+4YjiqXPr4rjWJsetnXwDy4OTPxfZezo24=";

  meta = {
    description = "MCP server for Cosense";
    homepage = "https://github.com/yosider/cosense-mcp-server";
    license = pkgs.lib.licenses.mit;
    mainProgram = "cosense-mcp-server";
  };
}
