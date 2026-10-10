# In both `shared` and each instance. The kind modules (rules, skills, ...)
# collect their home.file entries here; instances.nix deploys them.
{lib, ...}: {
  options.files = lib.mkOption {
    type = lib.types.attrsOf lib.types.attrs;
    default = {};
    internal = true;
    description = "home.file entries (relative to $HOME) this instance produces.";
  };
}
