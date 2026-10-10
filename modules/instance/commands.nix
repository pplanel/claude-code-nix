{
  config,
  claudeNix,
  ...
}: {
  options.commands = claudeNix.entriesOption ''
    Slash commands, linked as <configDir>/commands/<name>.md. A path or the text itself.
  '';
  config.files = claudeNix.filesFor config "commands" (name: _: "commands/${name}.md");
}
