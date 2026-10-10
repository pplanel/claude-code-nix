{
  config,
  claudeNix,
  ...
}: {
  options.skills = claudeNix.entriesOption ''
    Skills. A path is the skill's folder (SKILL.md plus any scripts), linked
    whole as <configDir>/skills/<name>. Text is just the SKILL.md, written to
    <configDir>/skills/<name>/SKILL.md. Either way skills/ stays a real folder,
    so hand-made skills can sit next to these.
  '';
  config.files = claudeNix.filesFor config "skills" (name: value:
    if claudeNix.isText value
    then "skills/${name}/SKILL.md"
    else "skills/${name}");
}
