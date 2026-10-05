{
  config,
  lib,
  pkgs,
  ...
}:
let
  modelPath = "${config.home.homeDirectory}/.local/share/llama.cpp/active.gguf";
  label = "org.nix-community.home.local-llama";
  settings = {
    host = "127.0.0.1";
    port = 43127;
    context = 16384;
  };
  baseUrl = "http://${settings.host}:${toString settings.port}/v1";
  controlConfig = pkgs.writeText "llama-control.json" (
    builtins.toJSON (settings // { inherit modelPath label; })
  );
  control = pkgs.writeScriptBin "llama-control" ''
    #!${pkgs.python3}/bin/python3
    # <xbar.title>Local llama.cpp</xbar.title>
    # <xbar.desc>Local inference status and launchd ON/OFF</xbar.desc>
    # <swiftbar.runInBash>false</swiftbar.runInBash>
    # <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
    # <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>
    CONFIG_PATH = ${builtins.toJSON (toString controlConfig)}
    ${builtins.readFile ../scripts/llama-control.py}
  '';
  providers = pkgs.writeText "local-llama-providers.json" (
    builtins.toJSON {
      pi.local-llama = {
        inherit baseUrl;
        api = "openai-completions";
        apiKey = "local-only-unused";
        models = [
          {
            id = "local-qwen";
            name = "Local Qwen (16K; capabilities pending verification)";
            reasoning = false;
            input = [ "text" ];
            contextWindow = 16384;
            maxTokens = 4096;
            cost = {
              input = 0;
              output = 0;
              cacheRead = 0;
              cacheWrite = 0;
            };
          }
        ];
      };
      kilo.local-llama = {
        npm = "@ai-sdk/openai-compatible";
        name = "Local llama.cpp";
        options = {
          baseURL = baseUrl;
          apiKey = "local-only-unused";
        };
        models.local-qwen = {
          name = "Local Qwen (16K; capabilities pending verification)";
          limit = {
            context = 16384;
            output = 4096;
          };
          modalities = {
            input = [ "text" ];
            output = [ "text" ];
          };
          reasoning = false;
          tool_call = false;
          attachment = false;
        };
      };
    }
  );
in
{
  home.packages = [
    pkgs.llama-cpp
    control
    pkgs.swiftbar
  ];
  home.file.".config/swiftbar/local-llama.5s.py" = {
    source = "${control}/bin/llama-control";
    executable = true;
  };
  targets.darwin.defaults."com.ameba.SwiftBar" = {
    PluginDirectory = "${config.home.homeDirectory}/.config/swiftbar";
    MakePluginExecutable = false;
    SUEnableAutomaticChecks = false;
    SUAutomaticallyUpdate = false;
    CollectCrashReports = false;
  };
  # Apply preferences/plugin files before starting the lightweight UI. The
  # inference job itself keeps RunAtLoad=false below.
  home.activation.localLlamaMenuPreferences =
    lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "linkGeneration" "setDarwinDefaults" ]
      "";
  launchd.agents.local-llama-menubar = {
    enable = true;
    config = {
      ProgramArguments = [ "${pkgs.swiftbar}/bin/SwiftBar" ];
      RunAtLoad = true;
      KeepAlive = false;
      StandardOutPath = "/dev/null";
      StandardErrorPath = "/dev/null";
    };
  };
  home.sessionVariables.LLAMA_CACHE = "${config.home.homeDirectory}/.cache/llama.cpp";
  programs.zsh.shellAliases = {
    llama-on = "llama-control on";
    llama-off = "llama-control off";
    llama-status = "llama-control status";
  };
  programs.fish.shellAliases = {
    llama-on = "llama-control on";
    llama-off = "llama-control off";
    llama-status = "llama-control status";
  };

  # launchd owns the official server directly. ON/OFF controls only this job;
  # no inference launcher, automatic restart or login-time model loading.
  launchd.agents.local-llama = {
    enable = true;
    config = {
      Label = label;
      ProgramArguments = [
        "${pkgs.llama-cpp}/bin/llama-server"
        "--model"
        modelPath
        "--offline"
        "--alias"
        "local-qwen"
        "--host"
        settings.host
        "--port"
        (toString settings.port)
        "--gpu-layers"
        "all"
        "--ctx-size"
        (toString settings.context)
        "--parallel"
        "1"
        "--jinja"
        "--flash-attn"
        "auto"
        "--sleep-idle-seconds"
        "-1"
        "--log-verbosity"
        "3"
        "--no-agent"
      ];
      EnvironmentVariables = {
        HOME = config.home.homeDirectory;
        LLAMA_CACHE = "${config.home.homeDirectory}/.cache/llama.cpp";
      };
      RunAtLoad = false;
      KeepAlive = false;
      StandardOutPath = "/dev/null";
      StandardErrorPath = "/dev/null";
    };
  };
  home.activation.localLlamaModelDirectory = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run mkdir -p ${lib.escapeShellArg (builtins.dirOf modelPath)}
  '';
  # These files are mutable client state. Add only our provider after approval
  # and activation; never capture existing config/auth in a store derivation.
  home.activation.localLlamaProviders = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${pkgs.python3}/bin/python3 ${../scripts/add-local-llama-provider.py} ${lib.escapeShellArg config.home.homeDirectory} ${providers}
  '';
}
