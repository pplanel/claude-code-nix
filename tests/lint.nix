# Lints the repo: Nix (statix, deadnix) and shell (shellcheck). The plugin's
# shell scripts are templates, so shellcheck reads them as built, with the
# placeholders filled.
{
  runCommand,
  callPackage,
  statix,
  deadnix,
  shellcheck,
  src,
}: let
  plugin = callPackage ../pkgs/identity-plugin {
    githubOwner = "someone";
    hosts = {
      alpha = {};
      beta = {};
    };
  };
in
  runCommand "lint" {nativeBuildInputs = [statix deadnix shellcheck];} ''
    cp -r ${src} repo && chmod -R u+w repo && cd repo
    export NO_COLOR=1
    set -x
    statix check -o errfmt .
    deadnix --fail .
    shellcheck --severity=warning \
      ${plugin}/scripts/identity.sh ${plugin}/scripts/host-tag.sh pkgs/claude-code/update.sh
    set +x
    touch $out
  ''
