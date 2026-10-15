#!/bin/sh
# PreToolUse, PostToolUse, PostToolUseFailure (Bash): hands the hook's JSON
# to `atuin hook claude-code` unchanged, with ATUIN_HISTORY_AUTHOR set to
# "<agent>/<session title>", so atuin's history says who ran each command
# and in which session:
#   <agent>          CLAUDE_AGENT_NAME (the identity instances export it from
#                    hosts.<host>.agentName), else this host's name
#   <session title>  the session's latest title (/rename included), read from
#                    its transcript; left out while the session has none

input=$(cat)
field() { printf '%s' "$input" | @JQ@ -r ".$1 // empty" 2>/dev/null; }
session=$(field session_id | tr -cd 'A-Za-z0-9-')
transcript=$(field transcript_path)

# The title is the last "custom-title" record in the transcript, which can be
# tens of MB. Each session caches its title and how far it has read, and only
# reads what was appended since; a trailing line still being written is read
# again next time, so a title can't be skipped.
session_title() {
  [ -n "$session" ] && [ -f "$transcript" ] || return 0
  cache="${TMPDIR:-/tmp}/claude-atuin-author"
  mkdir -p "$cache" && chmod 700 "$cache"
  read_to=$(cat "$cache/$session.offset" 2>/dev/null || echo 0)
  size=$(wc -c <"$transcript" | tr -d ' ')
  [ "$size" -lt "$read_to" ] && read_to=0 # the transcript was rewritten
  if [ "$size" -gt "$read_to" ]; then
    latest=$(tail -c +"$((read_to + 1))" "$transcript" |
      grep '"type":"custom-title"' | tail -n 1 |
      @JQ@ -r '.customTitle // empty' 2>/dev/null)
    [ -n "$latest" ] && printf '%s' "$latest" >"$cache/$session.title"
    if [ "$(tail -c 1 "$transcript" | od -An -c | tr -d ' ')" = '\n' ]; then
      printf '%s' "$size" >"$cache/$session.offset"
    fi
  fi
  cat "$cache/$session.title" 2>/dev/null
}

author="${CLAUDE_AGENT_NAME:-$(@HOSTNAME@ -s)}"
title=$(session_title)
[ -n "$title" ] && author="$author/$title"

export ATUIN_HISTORY_AUTHOR="$author"
printf '%s' "$input" | exec @ATUIN@ hook claude-code
