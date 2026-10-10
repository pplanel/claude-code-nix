# Teaches each instance how it's managed: a short rule that always loads,
# and a skill with the procedures. Either can be dropped per instance by
# setting it to null.
{
  config,
  lib,
  claudeNix,
  ...
}: let
  inherit (claudeNix) top;
  ctx = {
    # Every instance on this machine, so the rule and skill read the same in
    # each config dir: one config's rules can load in another's sessions
    # (~/.claude is an ancestor of the other dirs under $HOME).
    instances = lib.mapAttrsToList (_: l: {inherit (l) command configDir;}) top.layout;
    version = top.package.version;
    inherit (top.selfManagement) repo apply;
    inherit (top) checkout;
  };
  # Reading managed entries goes through /nix/store; every path along a link
  # must be allowed (tested), and nothing may write under /nix. Checkout
  # files are edited at their real path, never through the config-dir link
  # (that's under .claude/, which always prompts).
  sm = top.selfManagement;
  managed = map (kind: "Read(/${claudeNix.home}/${config.dir}/${kind}/**)") ["rules" "skills" "agents" "commands"];
in {
  config = lib.mkIf sm.enable (lib.mkMerge [
    {
      rules.claude-code-nix = lib.mkDefault (import ../self/rule.nix ctx);
      skills.claude-code-nix = lib.mkDefault (import ../self/skill.nix ctx);
    }
    (lib.mkIf sm.permissions {
      settings.permissions = {
        allow =
          managed
          ++ ["Read(//nix/store/**)"]
          ++ lib.optional (top.checkout != null) "Read(/${top.checkout}/**)"
          ++ lib.optional (top.checkout != null && sm.allowCheckoutEdits) "Edit(/${top.checkout}/**)";
        deny = ["Edit(//nix/**)"];
      };
    })
  ]);
}
