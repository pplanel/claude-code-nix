#!/bin/sh
# Resume the Claude session handed off to this folder (claude-handoff leaves
# a marker when it couldn't resume it in tmux), and remove its marker.
#   handoff-resume          the session waiting in the current folder
#   handoff-resume --list   every session waiting on this Mac
# Part of the handoff plugin (claude-code-nix); @...@ are filled in by nix.
JQ=@JQ@
state="${CLAUDE_HANDOFF_STATE:-$HOME/.local/state/claude-handoff}"

if [ "${1:-}" = --list ]; then
  found=0
  for f in "$state"/*.json; do
    [ -f "$f" ] || continue
    found=1
    $JQ -r '"\(.dir)  (from \(.from), \(.command) --resume \(.session))"' "$f"
  done
  [ "$found" = 1 ] || echo "no handed-off sessions waiting"
  exit 0
fi

# Claude's folder naming: / and . become -.
f="$state/$(printf '%s' "$PWD" | sed 's#[/.]#-#g').json"
if [ ! -f "$f" ]; then
  echo "no handed-off session waiting in $PWD (handoff-resume --list shows them all)" >&2
  exit 1
fi
command=$($JQ -r .command "$f")
session=$($JQ -r .session "$f")
rm -f "$f"
exec "$command" --resume "$session"
