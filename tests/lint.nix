# Lints the repo: Python (ruff, with ruff.toml), Nix (statix, deadnix) and
# shell (shellcheck). The plugin's shell scripts are templates, so shellcheck
# reads them as built, with the placeholders filled.
{
  runCommand,
  callPackage,
  ruff,
  statix,
  deadnix,
  shellcheck,
  src,
}: let
  plugin = callPackage ../pkgs/handoff-plugin {
    githubOwner = "someone";
    hosts = {
      alpha = {
        src = "/Users/u/src";
        configDir = "/Users/u/.claude";
        command = "claude";
        defaultTarget = "beta";
      };
      beta = {
        src = "/Users/u/src";
        configDir = "/Users/u/.claude";
        command = "claude";
      };
    };
  };
in
  runCommand "lint" {nativeBuildInputs = [ruff statix deadnix shellcheck];} ''
    cp -r ${src} repo && chmod -R u+w repo && cd repo
    export NO_COLOR=1
    set -x
    ruff check --no-cache .
    ruff format --no-cache --check .
    statix check -o errfmt .
    deadnix --fail .
    shellcheck --severity=warning \
      ${plugin}/scripts/quota-check.sh ${plugin}/scripts/statusline.sh ${plugin}/bin/handoff-resume pkgs/claude-code/update.sh
    set +x
    touch $out
  ''
