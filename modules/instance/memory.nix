# CLAUDE.md. Unset by default: a nix-managed CLAUDE.md is read-only, so
# /memory and Claude couldn't edit it. Prefer rules for nix-managed content.
{
  config,
  lib,
  claudeNix,
  ...
}: {
  options.memory = lib.mkOption {
    type = lib.types.nullOr claudeNix.entryType;
    default = null;
    description = "<configDir>/CLAUDE.md, as a path or the text itself. An instance's value replaces the shared one. null leaves CLAUDE.md alone.";
  };

  config.files =
    if claudeNix.isShared
    then {}
    else let
      memory =
        if config.memory != null
        then config.memory
        else claudeNix.shared.memory;
    in
      lib.optionalAttrs (memory != null) {
        "${config.dir}/CLAUDE.md" = claudeNix.fileOf memory;
      };
}
