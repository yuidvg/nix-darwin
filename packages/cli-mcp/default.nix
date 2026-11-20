# MCP bridge that passes argv straight to local CLIs, for Claude Desktop chat,
# which has no shell. Claude Code and Codex already run CLIs directly.
# No guards: permission is the calling client's job.
{ pkgs, path }:
pkgs.writeShellScript "cli-mcp" ''
  export PATH=${pkgs.lib.escapeShellArg (pkgs.lib.concatStringsSep ":" path)}
  exec ${pkgs.python3}/bin/python3 -I ${./server.py}
''
