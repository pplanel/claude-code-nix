{
  config,
  claudeNix,
  ...
}: {
  options.rules = claudeNix.entriesOption ''
    Rules, linked as <configDir>/rules/<name>.md. Claude Code loads them in
    every session, with no @imports. A path or the text itself.
  '';
  config.files = claudeNix.filesFor config "rules" (name: _: "rules/${name}.md");
}
