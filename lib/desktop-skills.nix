# Skills synced to the Claude Desktop account (Chat and Cowork).
#
# A subset of lib/enabled-skills.nix; the flake rejects names outside it.
# `nix run .#sync-desktop-skills` reconciles the account against this list.
# Every enabled account skill adds its description to each chat's context,
# so keep this list short.
[
  "carnegie-influence"
  "concern-extraction"
  "functional-swift"
  "impeccable"
  "shibaki"
]
