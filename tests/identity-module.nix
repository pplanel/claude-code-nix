# Evaluates the identity module as a config would (hosts.nix + identity.nix,
# with `instances` stubbed to the two fields identity sets), builds the
# plugin through it, and runs the setup that exports CLAUDE_AGENT_NAME as
# three hosts. tests/identity-plugin.nix builds the plugin directly, so it
# can't catch a module that fails to build it.
{
  lib,
  runCommand,
  pkgs,
}: let
  eval = lib.evalModules {
    modules = [
      ../modules/hosts.nix
      ../modules/identity.nix
      {
        options.assertions = lib.mkOption {
          type = lib.types.listOf lib.types.anything;
          default = [];
        };
        options.programs.claude-code-nix.instances = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule {
            options.plugins = lib.mkOption {
              type = lib.types.listOf lib.types.package;
              default = [];
            };
            options.extraSetup = lib.mkOption {
              type = lib.types.lines;
              default = "";
            };
          });
          default = {};
        };
        config = {
          _module.args = {inherit pkgs;};
          programs.claude-code-nix = {
            hosts = {
              alpha = {
                src = "/s";
                configDir = "/c";
                agentName = "Liet";
              };
              beta = {
                src = "/s";
                configDir = "/c";
              };
              "it's" = {
                src = "/s";
                configDir = "/c";
                agentName = "O'Brien";
              };
            };
            identity = {
              enable = true;
              githubOwner = "someone";
              instances = ["personal"];
            };
          };
        };
      }
    ];
  };
  instance = eval.config.programs.claude-code-nix.instances.personal;
  setup = builtins.toFile "agent-name-setup.sh" instance.extraSetup;
in
  runCommand "identity-module-test" {
    plugin = builtins.head instance.plugins;
  } ''
    failed=0
    # The setup as a given host: hostname replaced, then print the variable.
    as() { sed "s|/bin/hostname -s|printf %s \"$1\"|" ${setup} > run.sh
           echo 'echo "''${CLAUDE_AGENT_NAME-<unset>}"' >> run.sh; bash run.sh; }
    check() { got="$(as "$1")"
      if [ "$got" = "$2" ]; then echo "ok   $1 -> $got"; else echo "FAIL $1 -> $got, want $2"; failed=1; fi; }

    [ -d "$plugin/.claude-plugin" ] && echo "ok   plugin built through the module" ||
      { echo "FAIL plugin has no .claude-plugin"; failed=1; }
    check alpha Liet
    check beta "<unset>"
    check "it's" "O'Brien"
    [ "$failed" = 0 ] && touch $out
  ''
