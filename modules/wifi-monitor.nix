{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.wifi-monitor;
  monitor = pkgs.writeScriptBin "wifi-monitor" ''
    #!${pkgs.python3}/bin/python3
    ${builtins.readFile ../scripts/wifi-monitor.py}
  '';
in
{
  options.services.wifi-monitor.enable = lib.mkEnableOption "rolling 30-day Wi-Fi diagnostics";

  config = lib.mkIf cfg.enable {
    home.packages = [ monitor ];
    launchd.agents.wifi-monitor = {
      enable = true;
      config = {
        ProgramArguments = [ "${monitor}/bin/wifi-monitor" ];
        RunAtLoad = true;
        StartInterval = 60;
        ProcessType = "Background";
        LowPriorityIO = true;
      };
    };
  };
}
