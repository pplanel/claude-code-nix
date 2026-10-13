# programs.claude-code-nix.identity: the identity plugin (pkgs/identity-plugin),
# built with the machines in programs.claude-code-nix.hosts and loaded by the
# chosen instances: each machine's agent starts knowing which machine it is
# and who it is there, and tags its replies.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.programs.claude-code-nix.identity;

  plugin = pkgs.callPackage ../pkgs/identity-plugin {
    inherit (cfg) githubOwner;
    inherit (config.programs.claude-code-nix) hosts;
  };
in {
  options.programs.claude-code-nix.identity = {
    enable = lib.mkEnableOption "the identity plugin";
    githubOwner = mkOption {
      type = types.str;
      description = "The plugin's author, github.com/<githubOwner>.";
    };
    instances = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Instances that load the plugin.";
    };
    package = mkOption {
      type = types.package;
      readOnly = true;
      default = plugin;
      description = "The built plugin.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.programs.claude-code-nix.hosts != {};
        message = "programs.claude-code-nix.identity: needs the machines in programs.claude-code-nix.hosts.";
      }
    ];
    programs.claude-code-nix.instances = lib.genAttrs cfg.instances (_: {
      plugins = [plugin];
    });
  };
}
