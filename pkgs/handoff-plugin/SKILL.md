---
name: handoff
argument-hint: "[@HOST_ARGS@] [tmux]"
description: Move this Claude Code session to another of the user's Macs (@HOST_LIST@) and resume it there, with its whole conversation, on that Mac's Claude account. Use when the user types /handoff [host], or immediately when the context says "QUOTA HANDOFF NOW" (the quota hook, at 80% of the 5-hour or weekly limit). Not for anything else.
---

# Hand this session off to another Mac

Each Mac runs Claude Code on its own account. This moves the session: the uncommitted work goes straight to the target over ssh (nothing is committed or pushed to GitHub), the transcript is copied into the target's Claude config, and the target runs `claude --resume <id>` in tmux and carries on. It works from any of these Macs to any other, and each Mac's layout (sources dir, Claude config, command) is built into the script:

@LAYOUT_TABLE@

The user decided to **hand off immediately, even if the work is broken**. Don't try to finish the current step first.

## 1. Get the details

They're in the hook's message in your context: "QUOTA HANDOFF NOW: … target=… session_id=… transcript=… cwd=…", "Handoff requested by the user. target=… session_id=… transcript=… cwd=…", or "Handoff requested by the user without a host. session_id=… transcript=… cwd=…". Use those values exactly. `target` is the Mac the user named after `/handoff`, or for the quota handoff this Mac's default target.

- **Without a host** (the user typed a bare `/handoff`): run `claude-handoff --routes`. It prints one line per other Mac: its name, then how it's reachable right now (`airshell`, `local network`, `tailscale`, `via <alias>` or `unreachable`), with `(default)` on this Mac's default target. Ask the user which Mac with AskUserQuestion: one option per reachable host, labelled `<host> · <route>`, the default first. Their pick is `target`.

- If the hook says the named host isn't another Mac, tell the user the valid choices and stop.
- If the details aren't there (rare: the hook didn't run), ask the user to type `/handoff <host>` again. Don't guess the session from file times.

## 2. Leave the note: one message, before running anything

The resumed session reads this conversation, so write a short handoff note to the user as a normal message. **Always write a fresh one in this turn, from the current state**: never refer to, summarize or reuse an earlier handoff note in the conversation, which is out of date by now.
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
1. snapshots the repo's uncommitted work, untracked files included (ignored ones excluded), without changing this checkout;
2. pushes the branch's commits and the snapshot straight to the target's copy of the repo over ssh, cloning the repo there first if needed (no new branch, nothing goes to GitHub);
3. checks out the same branch in the same worktree (or the main checkout) in the target's layout, and restores the uncommitted work there exactly as it was;
4. copies the transcript (paths rewritten to the target's layout) and memory into the target's Claude config;
5. leaves a marker on the target saying the session waits in that folder, and marks this session handed off. On the target, `cd` into the folder: zsh says a session is waiting, and `handoff-resume` resumes it. Only if the user asked for tmux (e.g. `/handoff arrakis tmux`), pass `--tmux`: it then resumes in a new window of the target's running tmux and sends it a "continue autonomously" note (it never starts a tmux server over ssh; without one it leaves the marker instead).

It reaches the target over the first ssh route that answers: `<host>.airshell`, `<host>.local`, `<host>` (Tailscale), then any extra aliases. If the target's checkout has local changes of its own, it stops without touching them. `--dry-run` shows the plan without doing anything.

## 4. Report, then stop

- **On success:** tell the user the session waits on the target in its folder (the same worktree and branch, uncommitted work restored): `cd` there and run `handoff-resume` (or the `--resume` command the script printed). With `--tmux`, it's running in the target's tmux window `work:handoff-<repo>` instead (`ssh <target> -t tmux attach -t work`).
- **On failure:** report the exact error and the step it stopped at. Don't retry blindly. What was already done (refs pushed to the target, copied files) is harmless, and this checkout is unchanged. Tell the user how to finish by hand: on the target, `cd` to the repo in its layout and run its claude command with `--resume <session_id>`.
- **After a successful handoff, do no more work in this session:** no edits, commands or commits. The target owns it now, and two sessions editing the same work would collide. Only answer the user.
