# programs.claude-code-nix.handoff: the handoff plugin (pkgs/handoff-plugin),
# built with these hosts and loaded by the chosen instances, plus their
# status line, which feeds the plugin's quota hook.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.programs.claude-code-nix.handoff;

  plugin = pkgs.callPackage ../pkgs/handoff-plugin {
    inherit (cfg) githubOwner;
    hosts = lib.mapAttrs (_: h: {inherit (h) src configDir command defaultTarget;}) cfg.hosts;
  };

  host = types.submodule {
    options = {
      src = mkOption {
        type = types.str;
        description = "Absolute path of the sources dir on that host.";
      };
      configDir = mkOption {
        type = types.str;
        description = "Absolute path of the Claude config dir a handoff lands in there.";
      };
      command = mkOption {
        type = types.str;
        default = "claude";
        description = "The command that starts that Claude instance there.";
      };
      defaultTarget = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Where sessions on that host go when the quota hook hands off. null: no automatic handoff from it.";
      };
    };
  };
in {
  options.programs.claude-code-nix.handoff = {
    enable = lib.mkEnableOption "the handoff plugin";
    hosts = mkOption {
      type = types.attrsOf host;
      default = {};
      description = "Every machine a session can move between, by `hostname -s`, including this one.";
    };
    githubOwner = mkOption {
      type = types.str;
      description = "Only repos on github.com/<githubOwner> are handed off (pushed here, cloned there).";
    };
    instances = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Instances that load the plugin and get its status line.";
    };
    package = mkOption {
      type = types.package;
      readOnly = true;
      default = plugin;
      description = "The built plugin.";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.claude-code-nix.instances = lib.genAttrs cfg.instances (_: {
      plugins = [plugin];
      settings.statusLine = {
        type = "command";
        command = "${plugin}/scripts/statusline.sh";
        refreshInterval = 60;
      };
    });
  };
}
