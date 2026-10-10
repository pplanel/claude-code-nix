# What makes an instance a command: its config dir, account and environment.
{
  config,
  lib,
  ...
}: let
  inherit (lib) mkOption types;
in {
  options = {
    configDir = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = lib.literalExpression ''"src/''${config.home.username}/.claude"'';
      description = "Config dir relative to $HOME, exported as CLAUDE_CONFIG_DIR. null keeps Claude's default ~/.claude.";
    };
    apiKeyEnv = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "CLAUDE_PERSONAL_API_KEY";
      description = "When set, ANTHROPIC_API_KEY comes from this variable, or is unset when it's empty, so the instance logs in with its own account. null leaves ANTHROPIC_API_KEY alone.";
    };
    extraEnv = mkOption {
      type = types.attrsOf types.str;
      default = {};
    };
    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [];
    };
    dir = mkOption {
      type = types.str;
      internal = true;
      readOnly = true;
      description = "The config dir relative to $HOME, with the default filled in.";
    };
  };

  config.dir =
    if config.configDir == null
    then ".claude"
    else config.configDir;
}
