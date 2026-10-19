#!/bin/bash
# UserPromptSubmit hook: tells Claude which agent and Mac this turn runs as,
# and to start its reply with "[<agent>@<host>]:" ("[Liet@arrakis]:"), or
# "[<host>]:" for an instance with no agent name. Once synced, a transcript is
# the same file on every Mac; the tag is how a reader (or a later session) sees
# who wrote each answer, and where. A theme can't do it: it colors the whole
# history by the Mac you're on now. Silent on a machine that isn't one of the
# hosts. The agent is CLAUDE_AGENT_NAME (hosts.<host>.agentName, exported by
# the identity instances); HOST_TAG_HOST and HOST_TAG_AGENT override (tests).
# Part of the identity plugin (claude-code-nix); @...@ are filled in by nix.
JQ=@JQ@
HOSTS="@HOSTS@"

cat >/dev/null # the hook's input; not needed
here=${HOST_TAG_HOST:-$(hostname -s)}
[[ " $HOSTS " == *" $here "* ]] || exit 0
agent=${HOST_TAG_AGENT-${CLAUDE_AGENT_NAME:-}}
"$JQ" -nc --arg h "$here" --arg a "$agent" '
  (if $a == "" then $h else $a + "@" + $h end) as $tag
  | {hookSpecificOutput: {hookEventName: "UserPromptSubmit",
      additionalContext: (
        (if $a == "" then "This turn runs on the Mac \"" + $h + "\""
         else "This turn runs as the agent " + $a + " on the Mac \"" + $h + "\"" end)
        + ". Start your reply with \"[" + $tag + "]: \" so the transcript shows who wrote each answer, and on which Mac.")}}'
