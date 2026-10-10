# Teaches each instance how it's managed: a short rule that always loads,
# and a skill with the procedures. Either can be dropped per instance by
# setting it to null.
{
  config,
  lib,
  name,
  claudeNix,
  ...
}: let
  top = claudeNix.top;
  ctx = {
    inherit name;
    dir = "${claudeNix.home}/${config.dir}";
    version = top.package.version;
    inherit (top.selfManagement) repo apply;
    inherit (top) checkout;
  };
in {
  config = lib.mkIf top.selfManagement.enable {
    rules.claude-code-nix = lib.mkDefault (import ../self/rule.nix ctx);
    skills.claude-code-nix = lib.mkDefault (import ../self/skill.nix ctx);
  };
}
