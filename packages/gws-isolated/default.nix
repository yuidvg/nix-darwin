{ pkgs }:
assert pkgs.gws.version == "0.22.5";
pkgs.gws.overrideAttrs (old: {
  pname = "gws-isolated";
  patches = (old.patches or [ ]) ++ [ ./isolation.patch ];
})
