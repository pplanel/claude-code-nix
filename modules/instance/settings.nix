# settings.json keys. Not linked: settings.json stays a normal file that
# Claude, /config and permission prompts write to. Activation merges these
# keys in and takes back the ones a previous generation set but this one
# doesn't (see instances.nix).
{
  lib,
  claudeNix,
  ...
}: {
  options.settings = lib.mkOption {
    type = claudeNix.jsonType;
    default = {};
    example = {
      model = "opus";
      permissions.allow = ["Bash(nix build:*)"];
    };
    description = ''
      Keys merged into <configDir>/settings.json on activation. Keys that nix
      sets win over hand edits. The permission lists (allow, deny, ask,
      additionalDirectories) are combined with what's already there, not
      replaced. An instance's settings go on top of the shared ones, and
      their permission lists are combined too.
    '';
  };
}
