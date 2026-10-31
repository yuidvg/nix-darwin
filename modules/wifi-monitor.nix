{
  config,
  lib,
  ...
}:
let
  cfg = config.services.wifi-monitor;
in
{
  options.services.wifi-monitor = {
    enable = lib.mkEnableOption "rolling 30-day Wi-Fi diagnostics";
    package = lib.mkOption { type = lib.types.package; };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];
    launchd.agents.wifi-monitor = {
      enable = true;
      config = {
        ProgramArguments = [ "${cfg.package}/bin/wifi-monitor" ];
        RunAtLoad = true;
        StartInterval = 15;
        ProcessType = "Background";
        LowPriorityIO = true;
      };
    };
  };
}
