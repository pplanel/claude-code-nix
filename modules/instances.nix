# programs.claude-code-nix: named Claude Code commands, each with its own
# config dir, API key and rules. (home-manager's own programs.claude-code
# manages one config; this one runs several side by side.)
self: {
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.programs.claude-code-nix;
  home = config.home.homeDirectory;

  instance = types.submodule ({name, ...}: {
    options = {
      configDir = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "src/pplanel/.claude";
        description = "Config dir relative to $HOME, exported as CLAUDE_CONFIG_DIR. null keeps Claude's default ~/.claude.";
      };
      apiKeyEnv = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "CLAUDE_PERSONAL_API_KEY";
        description = "When set, ANTHROPIC_API_KEY comes from this variable, or is unset when it's empty, so the instance logs in with its own account. null leaves ANTHROPIC_API_KEY alone.";
      };
      rules = mkOption {
        type = types.attrsOf (types.either types.path types.lines);
        default = {};
        description = "Rules deployed as <configDir>/rules/<name>.md; they load in every session of this instance.";
      };
      extraEnv = mkOption {
        type = types.attrsOf types.str;
        default = {};
      };
      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [];
      };
    };
  });

  dirOf = i:
    if i.configDir == null
    then ".claude"
    else i.configDir;

  wrapper = name: i:
    pkgs.writeShellScriptBin name ''
      ${lib.optionalString (i.configDir != null) ''
        export CLAUDE_CONFIG_DIR="''${CLAUDE_CONFIG_DIR:-$HOME/${i.configDir}}"
        mkdir -p "$CLAUDE_CONFIG_DIR"
      ''}${lib.optionalString (i.apiKeyEnv != null) ''
        if [ -n "''${${i.apiKeyEnv}:-}" ]; then
          export ANTHROPIC_API_KEY="''$${i.apiKeyEnv}"
        else
          unset ANTHROPIC_API_KEY
        fi
      ''}${lib.concatStrings (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}\n") i.extraEnv)}exec ${lib.getExe cfg.package} ${lib.escapeShellArgs i.extraArgs} "$@"
    '';

  ruleFiles = name: i:
    lib.mapAttrs' (rule: src:
      lib.nameValuePair "${dirOf i}/rules/${rule}.md" (
        if builtins.isPath src || lib.isStorePath src
        then {source = src;}
        else {text = src;}
      ))
    i.rules;
in {
  options.programs.claude-code-nix = {
    enable = lib.mkEnableOption "named Claude Code instances";
    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.claude-code;
      description = "The Claude Code build the instances run.";
    };
    instances = mkOption {
      type = types.attrsOf instance;
      default = {};
      example = lib.literalExpression ''
        {
          claude = {};
          claude-personal = {
            configDir = "src/pplanel/.claude";
            apiKeyEnv = "CLAUDE_PERSONAL_API_KEY";
            rules.machines = ./machines.md;
          };
        }
      '';
    };
    layout = mkOption {
      type = types.attrsOf (types.attrsOf types.str);
      readOnly = true;
      description = "Per instance: the command and its absolute config dir, for tools such as claude-handoff.";
    };
  };

  config = lib.mkMerge [
    {
      programs.claude-code-nix.layout =
        lib.mapAttrs (name: i: {
          command = name;
          configDir = "${home}/${dirOf i}";
        })
        cfg.instances;
    }
    (lib.mkIf cfg.enable {
      home.packages = lib.mapAttrsToList wrapper cfg.instances;
      home.file = lib.mkMerge (lib.mapAttrsToList ruleFiles cfg.instances);
    })
  ];
}
