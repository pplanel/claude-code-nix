# Claude Code plugins loaded from the store with --plugin-dir: nothing is
# installed or published, and they load only through the instance's command.
{lib, ...}: {
  options.plugins = lib.mkOption {
    type = lib.types.listOf (lib.types.either lib.types.package lib.types.path);
    default = [];
    description = ''
      Plugin folders (each with .claude-plugin/plugin.json) the instance's
      command loads with --plugin-dir. An instance's list adds to the shared
      one. They show up as <name>@inline and load in place, read-only.
    '';
  };
}
