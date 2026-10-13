# programs.claude-code-nix.hosts: the machines that share a Claude setup, by
# `hostname -s`, and where each keeps its sources and its Claude config dir.
# claude-mesh syncs those config dirs, and the identity plugin gives each
# machine's agent its own identity; both take the machines from here, so
# they agree.
{lib, ...}: let
  inherit (lib) mkOption types;

  host = types.submodule {
    options = {
      src = mkOption {
        type = types.str;
        description = "Absolute path of the sources dir on that host.";
      };
      configDir = mkOption {
        type = types.str;
        description = "Absolute path of the Claude config dir there (the personal instance's).";
      };
    };
  };
in {
  options.programs.claude-code-nix.hosts = mkOption {
    type = types.attrsOf host;
    default = {};
    example = lib.literalExpression ''
      {
        caladan = { src = "/Users/me/src"; configDir = "/Users/me/.claude"; };
        imperium = { src = "/Users/me/src"; configDir = "/Users/me/.claude"; };
      }
    '';
    description = "Every machine in the setup, by `hostname -s`, including this one.";
  };
}
