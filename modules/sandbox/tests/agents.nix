# Builds the module's wrappers outside nix-darwin, for tests/run.sh: two
# agents, one per workspace mode. The system options the module sets (users,
# launchd, …) are stubbed as plain attrs, since only the wrappers are needed.
{flake}: let
  self = builtins.getFlake flake;
  pkgs = import self.inputs.nixpkgs {
    system = "aarch64-darwin";
    config.allowUnfree = true;
  };
  inherit (pkgs) lib;
  stub = {
    options =
      lib.genAttrs ["users" "launchd" "system" "environment"] (_:
        lib.mkOption {type = lib.types.attrsOf lib.types.anything;});
  };
  eval = lib.evalModules {
    modules = [
      self.darwinModules.sandbox
      stub
      {
        _module.args = {inherit pkgs;};
        services.claude-sandbox = {
          enable = true;
          agents.clone = {
            uid = 601;
            proxy.port = 8801;
          };
          agents.inplace = {
            uid = 602;
            proxy.port = 8802;
            workspace.mode = "in-place";
            homeReadScope = "state-only";
          };
        };
      }
    ];
  };
in
  pkgs.symlinkJoin {
    name = "claude-sandbox-test-wrappers";
    # python3 runs net-probe.py, from the same nixpkgs as the wrappers.
    paths = eval.config.environment.systemPackages ++ [pkgs.python3];
  }
