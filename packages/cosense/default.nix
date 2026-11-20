# `cosense` CLI that loads the managed PAT at runtime.
# Agents and the Desktop MCP bridge may start it without the interactive
# shell's environment; an explicit COSENSE_PAT still wins.
{ pkgs, patFile }:
let
  cli = import ../cosense-cli { inherit pkgs; };
in
pkgs.writeShellScriptBin "cosense" ''
  set -eu
  if [ -z "''${COSENSE_PAT:-}" ] && [ -r "${patFile}" ]; then
    COSENSE_PAT="$(${pkgs.coreutils}/bin/tr -d '\r\n' < "${patFile}")"
    export COSENSE_PAT
  fi
  exec ${cli}/bin/cosense "$@"
''
