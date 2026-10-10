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

  jsonType = (pkgs.formats.json {}).type;

  # Keys in settings.permissions that are combined rather than replaced.
  permissionLists = ["allow" "deny" "ask" "additionalDirectories"];

  # Shared settings, then the instance's on top; permission lists combined.
  mergeSettings = a: b: let
    pa = a.permissions or {};
    pb = b.permissions or {};
    lists = builtins.filter (k: pa ? ${k} || pb ? ${k}) permissionLists;
  in
    lib.recursiveUpdate a b
    // lib.optionalAttrs (pa != {} || pb != {}) {
      permissions = lib.recursiveUpdate pa pb // lib.genAttrs lists (k: lib.unique ((pa.${k} or []) ++ (pb.${k} or [])));
    };

  # Merges an instance's managed settings into its settings.json (see the
  # file; flake check tests it).
  mergeScript = ./settings-merge.jq;

  claudeNix = isShared: {
    inherit isShared isText fileOf entryType home jsonType;
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
    ./instance/settings.nix
    ./instance/plugins.nix
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

  # Shared plugins, then the instance's, each loaded with --plugin-dir.
  pluginArgs = i:
    lib.concatMap (p: ["--plugin-dir" "${p}"]) (lib.unique (cfg.shared.plugins ++ i.plugins));

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
      ''}${lib.concatStrings (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}\n") i.extraEnv)}exec ${lib.getExe cfg.package} ${lib.escapeShellArgs (pluginArgs i ++ i.extraArgs)} "$@"
    '';
in {
  imports = [./handoff.nix];

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
      permissions = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Add the permission rules nix-managed entries need. Allow Read on the
          managed folders and on /nix/store, since every path along a symlink
          must be allowed. Allow Read on `checkout` when it is set. Deny Edit
          on /nix/**, which also blocks Write.
        '';
      };
      allowCheckoutEdits = mkOption {
        type = types.bool;
        default = false;
        description = "Also allow Edit on `checkout` without a prompt. Claude edits checkout-linked entries at their real path there.";
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

      home.activation.claudeCodeNixSettings = lib.hm.dag.entryAfter ["writeBoundary"] (lib.concatStrings (lib.mapAttrsToList (name: i: let
          dir = "${home}/${i.dir}";
          managed = pkgs.writeText "claude-code-nix-${name}-settings.json" (builtins.toJSON (mergeSettings cfg.shared.settings i.settings));
        in ''
          f=${lib.escapeShellArg "${dir}/settings.json"}
          prev=${lib.escapeShellArg "${dir}/.claude-code-nix/settings.json"}
          if [ -L "$f" ]; then
            warnEcho "claude-code-nix: $f is a symlink, not merging ${name}'s settings into it"
          elif [ -v DRY_RUN ]; then
            verboseEcho "claude-code-nix: would merge ${managed} into $f"
          else
            mkdir -p "$(dirname "$prev")"
            [ -s "$f" ] || echo "{}" > "$f"
            [ -s "$prev" ] || echo "{}" > "$prev"
            tmp=$(mktemp)
            if ${lib.getExe pkgs.jq} --slurpfile prev "$prev" --slurpfile new ${managed} -f ${mergeScript} "$f" > "$tmp"; then
              cat "$tmp" > "$f"
              cp ${managed} "$prev"
              chmod 644 "$prev"
            else
              warnEcho "claude-code-nix: couldn't merge settings into $f; left it unchanged"
            fi
            rm -f "$tmp"
          fi
        '')
        cfg.instances));
    })
  ];
}
