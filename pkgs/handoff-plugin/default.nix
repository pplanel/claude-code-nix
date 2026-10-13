# The handoff plugin: move a Claude Code session to another machine and
# resume it there. Built per setup, with the hosts baked in, and loaded with
# --plugin-dir from the store (instances' `plugins`), never published.
#   skills/handoff     the procedure Claude follows
#   bin/claude-handoff on Claude's Bash PATH while the plugin is loaded (Python)
#   bin/handoff-resume resumes a session handed off to the current folder
#   share/claude-handoff/hook.zsh  says so on cd into such a folder
#   hooks/hooks.json   quota-check on UserPromptSubmit and PostToolBatch;
#                      host-tag on UserPromptSubmit (replies start "[<host>]:")
#   scripts/statusline.sh  saves rate limits for the hook; plugins can't set
#                      statusLine, so the module points settings.json at
#                      "${plugin}/scripts/statusline.sh"
{
  lib,
  runCommand,
  writeText,
  jq,
  coreutils,
  python3,
  # { <host> = { src; configDir; command; defaultTarget ? null; extraRoutes ? []; }; }, with
  # absolute src and configDir.
  hosts,
  # Repos are pushed and cloned from github.com/<githubOwner>.
  githubOwner,
}: let
  names = builtins.attrNames hosts;
  # claude-handoff's interpreter: rich for its output; the rest is stdlib.
  python = python3.withPackages (ps: [ps.rich]);
  fill = text:
    builtins.replaceStrings
    ["@JQ@" "@DATE@" "@PYTHON@" "@HOSTS_JSON@" "@HOSTS@" "@HOST_LIST@" "@HOST_ARGS@" "@OWNER@" "@TARGETS@\n" "@LAYOUT_TABLE@"]
    [
      (lib.getExe jq)
      "${coreutils}/bin/date"
      "${python}/bin/python3"
      (builtins.toJSON (lib.mapAttrs (_: h: {
          inherit (h) src configDir command;
          defaultTarget = h.defaultTarget or null;
          extraRoutes = h.extraRoutes or [];
        })
        hosts))
      (lib.concatStringsSep " " names)
      (lib.concatStringsSep ", " names)
      (lib.concatStringsSep "|" names)
      githubOwner
      (lib.concatStrings (lib.mapAttrsToList (n: h: lib.optionalString (h.defaultTarget or null != null) "  ${n}) TARGET=${h.defaultTarget} ;;\n") hosts))
      (''
          | Host | Sources | Claude config | Command |
          |---|---|---|---|
        ''
        + lib.concatStrings (lib.mapAttrsToList (n: h: "| ${n} | `${h.src}` | `${h.configDir}` | `${h.command}` |\n") hosts))
    ]
    text;
  script = name: writeText name (fill (builtins.readFile ./${name}));

  hook = name: {
    type = "command";
    command = "${placeholder "out"}/scripts/${name}";
    timeout = 5;
  };
  hooks = builtins.toJSON {
    hooks = {
      UserPromptSubmit = [{hooks = [(hook "quota-check.sh") (hook "host-tag.sh")];}];
      PostToolBatch = [{hooks = [(hook "quota-check.sh")];}];
    };
  };
  manifest = builtins.toJSON {
    name = "handoff";
    version = "1.0.0";
    description = "Move a Claude Code session to another of your machines and resume it there; hands off automatically near the plan's usage limit.";
    author.name = githubOwner;
  };
in
  runCommand "claude-code-handoff-plugin" {
    passAsFile = ["hooks" "manifest"];
    inherit hooks manifest;
  } ''
    mkdir -p $out/.claude-plugin $out/bin $out/hooks $out/scripts $out/skills/handoff
    cp $manifestPath $out/.claude-plugin/plugin.json
    cp $hooksPath $out/hooks/hooks.json
    install -m755 ${script "quota-check.sh"} $out/scripts/quota-check.sh
    install -m755 ${script "host-tag.sh"} $out/scripts/host-tag.sh
    install -m755 ${script "statusline.sh"} $out/scripts/statusline.sh
    install -m755 ${script "claude-handoff.py"} $out/bin/claude-handoff
    install -m755 ${script "handoff-resume.sh"} $out/bin/handoff-resume
    install -Dm644 ${script "hook.zsh"} $out/share/claude-handoff/hook.zsh
    cp ${script "SKILL.md"} $out/skills/handoff/SKILL.md
    # Nothing may be left unfilled.
    if grep -rn '@[A-Z_]*@' $out; then echo "unfilled placeholders" >&2; exit 1; fi
  ''
