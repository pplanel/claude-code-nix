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

  inherit (config.programs.claude-code-nix) hosts;

  plugin = pkgs.callPackage ../pkgs/identity-plugin {
    inherit (cfg) githubOwner hosts;
  };

  # The same config runs on every host, so the command picks this host's
  # agent name when it starts, by `hostname -s`, like the plugin does.
  named = lib.filterAttrs (_: h: h.agentName != null) hosts;
  agentNameSetup = lib.optionalString (named != {}) ''
    case "$(/bin/hostname -s)" in
    ${lib.concatStrings (lib.mapAttrsToList (host: h: "  ${lib.escapeShellArg host}) export CLAUDE_AGENT_NAME=${lib.escapeShellArg h.agentName} ;;\n") named)}esac
  '';
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
      extraSetup = agentNameSetup;
    });
  };
}
