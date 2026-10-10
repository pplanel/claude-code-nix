# Says so when you cd into a folder where a handed-off Claude session waits
# (claude-handoff's marker); handoff-resume resumes it. Loaded by the handoff
# module in zsh. Part of the handoff plugin (claude-code-nix).
_claude_handoff_hint() {
  local f="${CLAUDE_HANDOFF_STATE:-$HOME/.local/state/claude-handoff}/${PWD//[\/.]/-}.json"
  [[ -f $f ]] || return 0
  print -P "%F{cyan}⤷ handed-off Claude session waiting here%f (from $(@JQ@ -r .from $f)): run %Bhandoff-resume%b"
}
autoload -Uz add-zsh-hook
add-zsh-hook chpwd _claude_handoff_hint
_claude_handoff_hint
