---
name: handoff
description: Move this Claude Code session to another of the user's Macs (@HOST_LIST@) and resume it there, with its whole conversation, on that Mac's Claude account. Use when the user types /handoff [host], or immediately when the context says "QUOTA HANDOFF NOW" (the quota hook, at 80% of the 5-hour or weekly limit). Not for anything else.
---

# Hand this session off to another Mac

Each Mac runs Claude Code on its own account. This moves the session: the work gets committed and pushed, the transcript is copied into the target's Claude config, and the target runs `claude --resume <id>` in tmux and carries on. It works from any of these Macs to any other, and each Mac's layout (sources dir, Claude config, command) is built into the script:

@LAYOUT_TABLE@

The user decided to **hand off immediately, even if the work is broken**. Don't try to finish the current step first.

## 1. Get the details

They're in the hook's message in your context: either "QUOTA HANDOFF NOW: … target=… session_id=… transcript=… cwd=…" or "Handoff requested by the user. target=… session_id=… transcript=… cwd=…". Use those values exactly. `target` is the Mac the user named after `/handoff`, or this Mac's default target.

- If the hook says the named host isn't another Mac, tell the user the valid choices and stop.
- If the details aren't there (rare: the hook didn't run), ask the user to type `/handoff <host>` again. Don't guess the session from file times.

## 2. Leave the note: one message, before running anything

The resumed session reads this conversation, so write a short handoff note to the user as a normal message:
- **Why:** quota at N% on this Mac, or the user asked.
- **In flight:** what you were doing, and what state it's in (builds? tests pass?).
- **Next step:** the exact thing to do next, and how to verify it.
- **Open questions:** decisions still waiting on the user.
- **Not carried over:** background tasks, watchers or loops that were running.

## 3. Run the handoff

```
claude-handoff --target <target> --session <session_id> --transcript <transcript> --cwd <cwd>
```

Set the Bash timeout to 300000 ms. `claude-handoff` comes with this plugin (claude-code-nix), so it's on your PATH. It:
1. commits changes to tracked files (WIP, hooks skipped) on `handoff/<repo>-<date>` and pushes;
2. checks out that branch on the target, in the target's layout, cloning if needed;
3. copies the transcript (paths rewritten to the target's layout) and memory into the target's Claude config;
4. opens tmux window `work:handoff-<repo>` there, running the target's claude with `--resume`;
5. sends it a "continue autonomously" note and marks this session handed off.

Untracked files are never pushed; the script lists them. `--dry-run` shows the plan without doing anything.

## 4. Report, then stop

- **On success:** tell the user it now continues in the target's tmux window `work:handoff-<repo>` (`ssh <target> -t tmux attach -t work`), on branch `handoff/…`, and list any untracked files that stayed here.
- **On failure:** report the exact error and the step it stopped at. Don't retry blindly. What was already done (a pushed branch, copied files) is harmless. Tell the user how to finish by hand: on the target, `cd` to the repo in its layout and run its claude command with `--resume <session_id>`.
- **After a successful handoff, do no more work in this session:** no edits, commands or commits. The target owns it now, and two sessions editing the same work would collide. Only answer the user.
