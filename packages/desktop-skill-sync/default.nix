# `sync-desktop-skills`: reconcile the Claude Desktop account's skills
# against `skillZips` (a directory of <skill>.zip, from packages/desktop-skills).
#
# `apply` sends Apple Events to Safari (/usr/bin/osascript) and uploads from
# a claude.ai tab there. Safari must allow it: Settings › Developer ›
# "Allow JavaScript from Apple Events".
{
  pkgs,
  skillZips,
}:
pkgs.writeShellApplication {
  name = "sync-desktop-skills";
  text = ''
    export DESKTOP_SKILLS_DIR="''${DESKTOP_SKILLS_DIR:-${skillZips}}"
    exec ${pkgs.python3}/bin/python ${./sync.py} "$@"
  '';
}
