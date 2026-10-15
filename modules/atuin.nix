# programs.claude-code-nix.atuin: the atuin plugin (pkgs/atuin-plugin),
# loaded by the chosen instances: every Bash command Claude runs goes into
# atuin's history, authored "<agent>/<session title>". The agent's name comes
# from CLAUDE_AGENT_NAME (identity instances, hosts.<host>.agentName), else
# the host's. It runs the atuin home-manager installs (programs.atuin), so
# the hooks and the shell share one atuin and one history.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.programs.claude-code-nix.atuin;
  plugin = pkgs.callPackage ../pkgs/atuin-plugin {atuin = cfg.package;};
in {
  options.programs.claude-code-nix.atuin = {
    enable = mkOption {
      type = types.bool;
      default = config.programs.atuin.enable;
      defaultText = lib.literalExpression "config.programs.atuin.enable";
      description = "Load the atuin plugin in `instances`. On when home-manager's atuin is.";
    };
    instances = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Instances that load the plugin, e.g. only the personal ones.";
    };
    package = mkOption {
      type = types.package;
      default = config.programs.atuin.package;
      defaultText = lib.literalExpression "config.programs.atuin.package";
      description = "The atuin the hooks run. It must read ATUIN_HISTORY_AUTHOR for the author to show.";
    };
  };

  config = lib.mkIf (cfg.enable && cfg.instances != []) {
    programs.claude-code-nix.instances = lib.genAttrs cfg.instances (_: {
      plugins = [plugin];
    });
  };
}
