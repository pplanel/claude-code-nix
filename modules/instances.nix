# programs.claude-code-nix: named Claude Code commands, each with its own
# config dir, account, and nix-managed rules, skills, agents and commands.
# (home-manager's own programs.claude-code manages one config; this one runs
# several side by side.) Each kind of entry is a module in ./instance; only
# the entries are linked, so the config dir and its folders stay writable.
self: {
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.programs.claude-code-nix;
  home = config.home.homeDirectory;

  # A path (a file, or a skill's folder) or the text itself.
  entryType = types.either types.path types.lines;
  isText = v: builtins.isString v && (lib.hasInfix "\n" v || !lib.hasPrefix "/" v);

  # Paths from the consuming flake's source link to its checkout instead of
  # the store when `checkout` is set, so they can be edited in place.
  toSource = v: let
    s = toString v;
    rel = builtins.match "/nix/store/[^/]+-source/(.*)" s;
  in
    if cfg.checkout != null && rel != null && !lib.hasPrefix (toString self) s
    then config.lib.file.mkOutOfStoreSymlink "${cfg.checkout}/${builtins.head rel}"
    else v;

  fileOf = v:
    if isText v
    then {text = v;}
    else {source = toSource v;};

  claudeNix = isShared: {
    inherit isShared isText fileOf entryType home;
    top = cfg;
    shared = cfg.shared;
    entriesOption = description:
      mkOption {
        type = types.attrsOf (types.nullOr entryType);
        default = {};
        inherit description;
      };
    # An instance's entries of one kind on top of the shared ones (null drops
    # one), as home.file entries under its config dir.
    filesFor = instance: kind: pathOf:
      if isShared
      then {}
      else
        lib.mapAttrs' (name: v: lib.nameValuePair "${instance.dir}/${pathOf name v}" (fileOf v))
        (lib.filterAttrs (_: v: v != null) (cfg.shared.${kind} // instance.${kind}));
  };

  kinds = [
    ./instance/common.nix
    ./instance/memory.nix
    ./instance/rules.nix
    ./instance/skills.nix
    ./instance/agents.nix
    ./instance/commands.nix
  ];

  sharedType = types.submoduleWith {
    specialArgs.claudeNix = claudeNix true;
    modules = kinds;
  };

  instanceType = types.submoduleWith {
    specialArgs.claudeNix = claudeNix false;
    shorthandOnlyDefinesConfig = true;
    modules = kinds ++ [./instance/base.nix ./instance/self-management.nix];
  };

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
in {
  options.programs.claude-code-nix = {
    enable = lib.mkEnableOption "named Claude Code instances";
    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.claude-code;
      description = "The Claude Code build the instances run.";
    };
    checkout = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = lib.literalExpression ''"''${config.home.homeDirectory}/.config/nix-darwin"'';
      description = ''
        Absolute path of a checkout of the flake that defines this config.
        When set, entries given as paths inside that flake link into the
        checkout instead of the nix store, so Claude can edit them in place
        (and the edit shows up as a diff there). Only set it where the
        checkout exists.
      '';
    };
    selfManagement = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Give every instance the claude-code-nix rule and skill, which explain how it's managed.";
      };
      repo = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "~/.config/nix-darwin";
        description = "Where this machine's Claude setup is defined, as the rule and skill should name it.";
      };
      apply = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "commit and push; nix-sync rebuilds every Mac within 30 minutes";
        description = "How a change to that repo reaches this machine.";
      };
    };
    shared = mkOption {
      type = sharedType;
      default = {};
      description = "Memory, rules, skills, agents and commands every instance gets. An instance adds to them, overrides an entry, or drops one by setting it to null.";
    };
    instances = mkOption {
      type = types.attrsOf instanceType;
      default = {};
      example = lib.literalExpression ''
        {
          claude = {};
          claude-personal = {
            configDir = "src/''${config.home.username}/.claude";
            apiKeyEnv = "CLAUDE_PERSONAL_API_KEY";
            rules.machines = ./machines.md;
            skills.deploy = ./skills/deploy;
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
          configDir = "${home}/${i.dir}";
        })
        cfg.instances;
    }
    (lib.mkIf cfg.enable {
      home.packages = lib.mapAttrsToList wrapper cfg.instances;
      home.file = lib.mkMerge (lib.mapAttrsToList (_: i: i.files) cfg.instances);
    })
  ];
}
