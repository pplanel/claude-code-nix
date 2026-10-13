# programs.claude-code-nix.mesh: claude-mesh (github.com/pplanel/claude-mesh)
# as a launchd agent. It keeps each host's Claude config dir
# (programs.claude-code-nix.hosts.<host>.configDir) the same on every host: sessions, memory,
# plans, todos and prompt history, merged rather than copied. Peers are
# reached over airshell: `serve` registers its `<host>-claudesync` service
# with airshell-proxy through its control socket and dials the others with
# airshell-connect, so authentication is airshell's (paired Macs only).
self: {
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.programs.claude-code-nix.mesh;
  hosts = config.programs.claude-code-nix.hosts;
  system = pkgs.stdenv.hostPlatform.system;
  home = config.home.homeDirectory;

  # claude-mesh's layout table, from programs.claude-code-nix.hosts.
  layout = pkgs.writeText "claude-mesh-hosts.json" (builtins.toJSON (lib.mapAttrs (_: h: {
      inherit (h) src;
      config = h.configDir;
    })
    hosts));
in {
  options.programs.claude-code-nix.mesh = {
    enable = lib.mkEnableOption "claude-mesh, which keeps the hosts' Claude config dirs in sync over airshell";
    package = mkOption {
      type = types.package;
      default = self.inputs.claude-mesh.packages.${system}.claude-mesh;
      defaultText = lib.literalExpression "claude-mesh.packages.\${system}.claude-mesh";
      description = "The claude-mesh package.";
    };
    executable = mkOption {
      type = types.str;
      default = lib.getExe cfg.package;
      defaultText = lib.literalExpression "lib.getExe cfg.package";
      example = "/usr/local/libexec/claude-mesh/claude-mesh";
      description = ''
        The binary the agent runs. macOS remembers the Local Network grant by
        path and signature, and a store path changes with every build, so a
        system that copies and signs the binary at a stable path (as
        nix-darwin does for airshell) points this there to be asked only once.
      '';
    };
    airshellConnect = mkOption {
      type = types.str;
      default = "airshell-connect";
      description = "The airshell-connect that dials peers: a command on the agent's PATH, or an absolute path.";
    };
    interval = mkOption {
      type = types.ints.positive;
      default = 30;
      description = "Seconds between pull rounds.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isDarwin;
        message = "programs.claude-code-nix.mesh: claude-mesh runs over airshell, which is macOS-only.";
      }
      {
        assertion = builtins.length (builtins.attrNames hosts) >= 2;
        message = "programs.claude-code-nix.mesh: needs at least two hosts in programs.claude-code-nix.hosts.";
      }
    ];

    home.packages = [cfg.package];

    # A user agent: airshell-connect needs the logged-in user's Local Network
    # grant, which a root daemon or a process started over ssh doesn't get.
    launchd.agents.claude-mesh = {
      enable = true;
      config = {
        ProgramArguments = [cfg.executable "serve" "--interval" (toString cfg.interval)];
        RunAtLoad = true;
        KeepAlive = true;
        ThrottleInterval = 30;
        StandardOutPath = "${home}/Library/Logs/claude-mesh.log";
        StandardErrorPath = "${home}/Library/Logs/claude-mesh.log";
        EnvironmentVariables = {
          CLAUDE_MESH_LAYOUT = "${layout}";
          CLAUDE_MESH_AIRSHELL_CONNECT = cfg.airshellConnect;
          PATH = lib.concatStringsSep ":" [
            "/etc/profiles/per-user/${config.home.username}/bin"
            "/run/current-system/sw/bin"
            "/usr/bin"
            "/bin"
          ];
        };
      };
    };
  };
}
