{
  config,
  claudeNix,
  ...
}: {
  options.agents = claudeNix.entriesOption ''
    Subagents, linked as <configDir>/agents/<name>.md. A path or the text itself.
  '';
  config.files = claudeNix.filesFor config "agents" (name: _: "agents/${name}.md");
}
