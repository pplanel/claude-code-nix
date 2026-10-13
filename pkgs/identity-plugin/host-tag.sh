#!/bin/bash
# UserPromptSubmit hook: tells Claude which Mac this turn runs on, and to start
# its reply with "[<host>]:". Once synced, a transcript is the same file on
# every Mac; the tag is how a reader (or a later session) sees where each
# answer was written. A theme can't do it: it colors the whole history by the
# Mac you're on now. Silent on a machine that isn't one of the hosts.
# HOST_TAG_HOST overrides this host's name (tests).
# Part of the identity plugin (claude-code-nix); @...@ are filled in by nix.
JQ=@JQ@
HOSTS="@HOSTS@"

cat >/dev/null # the hook's input; not needed
here=${HOST_TAG_HOST:-$(hostname -s)}
[[ " $HOSTS " == *" $here "* ]] || exit 0
"$JQ" -nc --arg h "$here" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit",
  additionalContext: ("This turn runs on the Mac \"" + $h + "\". Start your reply with \"[" + $h + "]: \" so the transcript shows which Mac each answer was written on.")}}'
