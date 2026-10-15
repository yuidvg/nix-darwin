{ pkgs }:
assert pkgs.gws.version == "0.22.5";
pkgs.gws.overrideAttrs (old: {
  pname = "gws-isolated";
  # Upstream's ADC/fallback tests describe behavior intentionally removed here.
  doCheck = true;
  cargoTestFlags = [ "isolated_" ];
  patches = (old.patches or [ ]) ++ [ ./isolation.patch ];
})
