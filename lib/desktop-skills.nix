# Skills synced to the Claude Desktop account (Chat and Cowork).
#
# Names are directories in github:yuidvg/skills (`skills/<name>`). The list
# is independent of lib/enabled-skills.nix: a skill can live on the account
# without being installed for Claude Code, and the other way round.
# `nix run .#sync-desktop-skills` reconciles the account against this list.
# Every enabled account skill adds its description to each chat's context,
# so keep this list short.
[
  "carnegie-influence"
  "concern-extraction"
  "cosense"
  "frontend-design"
  "impeccable"
  "purchase-research"
  "yomiyasu"
]
