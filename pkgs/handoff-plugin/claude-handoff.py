#!@PYTHON@
# /// script
# requires-python = ">=3.11"
# dependencies = ["rich"]
# ///
# Installed by nix with its own Python and rich (the shebang above). To work on
# it directly: `uv run pkgs/handoff-plugin/claude-handoff.py --help`, and
# `uv run --with pytest --with rich pytest pkgs/handoff-plugin` for the tests.
"""Move a Claude Code session from this Mac to another and resume it there.

    claude-handoff --session ID --transcript PATH --cwd DIR [--target HOST]
                   [--tmux] [--tmux-session NAME] [--tmux-window NAME] [--dry-run]

1. Snapshot: the repo's uncommitted work, untracked files included (ignored
   ones excluded), becomes a stash commit (`git add -A`, `git stash create`,
   `git reset`). This checkout is left exactly as it was: same branch, same
   files, nothing committed, nothing added to the stash list.
2. Peer-to-peer: the branch's commits and the snapshot are pushed straight to
   the target Mac's copy of the repo over ssh, under refs/handoff/<session>.
   Nothing goes to GitHub, and no new branch is made.
3. Same place there: in the target's layout, the same worktree (or the main
   checkout) gets the same branch at the same commit, and the snapshot is
   applied, so the uncommitted work is back exactly as it was. The repo is
   cloned from origin first if the target doesn't have it.
4. The transcript (paths rewritten to the target's layout), its subagent
   folder and the project's memory are copied into the target's Claude config.
5. On the target, a marker says a session waits in that folder: cd there and
   the zsh hook says so; handoff-resume resumes it. With --tmux it resumes in
   a new window of the target's tmux instead (never starting a tmux server
   over ssh: it couldn't reach the local network).
6. This session is marked handed off, so the quota hook stops asking.

Part of the handoff plugin (claude-code-nix). The hosts are filled in by nix.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

from rich.console import Console

# {"<host>": {"src", "configDir", "command", "defaultTarget"}}, from nix.
# CLAUDE_HANDOFF_HOSTS overrides it (tests).
_HOSTS_RAW = os.environ.get("CLAUDE_HANDOFF_HOSTS") or r"""@HOSTS_JSON@"""
# Run from the source (not built by nix) the table is unfilled: no hosts.
HOSTS: dict[str, dict] = {} if _HOSTS_RAW.startswith("@") else json.loads(_HOSTS_RAW)
OWNER = os.environ.get("CLAUDE_HANDOFF_OWNER") or "@OWNER@"
TMUX_SESSION = "work"

# Tests: CLAUDE_HANDOFF_LOCAL=1 runs the "remote" side locally (no ssh) and
# CLAUDE_HANDOFF_HOST pretends to be that host.
LOCAL = os.environ.get("CLAUDE_HANDOFF_LOCAL") == "1"
# Where the target keeps markers for sessions waiting to be resumed by hand
# (handoff-resume and the zsh hook read them); CLAUDE_HANDOFF_STATE in tests.
STATE = os.environ.get("CLAUDE_HANDOFF_STATE")

out = Console(highlight=False, soft_wrap=True)
err = Console(stderr=True, highlight=False, soft_wrap=True)
q = shlex.quote


class HandoffError(Exception):
    def __init__(self, message: str, code: int = 1) -> None:
        super().__init__(message)
        self.message, self.code = message, code


@dataclass(frozen=True)
class Layout:
    name: str
    src: Path
    config: Path
    command: str
    default_target: str | None
    routes: tuple[str, ...] = ()

    @property
    def ssh_routes(self) -> list[str]:
        """How to reach this host, in order: airshell, the local network,
        then the plain name (Tailscale), then any extra aliases from nix."""
        return [f"{self.name}.airshell", f"{self.name}.local", self.name, *self.routes]


def layout(host: str) -> Layout:
    h = HOSTS.get(host)
    if h is None:
        raise HandoffError(f'unknown host "{host}" (known: {", ".join(sorted(HOSTS))})', 2)
    return Layout(
        host,
        Path(h["src"]),
        Path(h["configDir"]),
        h["command"],
        h.get("defaultTarget"),
        tuple(h.get("extraRoutes") or ()),
    )


def this_host() -> str:
    return os.environ.get("CLAUDE_HANDOFF_HOST") or run(["hostname", "-s"]).strip()


def there(path: Path, here: Layout, dest: Layout) -> Path:
    """The same place in the target's layout: a path under this Mac's sources
    moves under the target's; anything else stays as it is."""
    try:
        return dest.src / path.relative_to(here.src)
    except ValueError:
        return path


def project_key(path: Path) -> str:
    """Claude names a project's folder after its path, / and . becoming -."""
    return re.sub(r"[/.]", "-", str(path))


def run(cmd: list[str], *, cwd: Path | None = None, stdin: str | None = None, check: bool = True) -> str:
    try:
        res = subprocess.run(cmd, cwd=cwd, input=stdin, capture_output=True, text=True, check=check)
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "").strip()
        what = " ".join(map(q, cmd))
        if "\n" in what or len(what) > 120:  # a remote script: its stderr says enough
            what = "ssh" if cmd[0] == "ssh" else cmd[0]
        raise HandoffError(f"{what} failed ({exc.returncode})" + (f": {detail}" if detail else "")) from exc
    return res.stdout


def git(repo: Path, *args: str, check: bool = True) -> str:
    return run(["git", "-C", str(repo), *args], check=check).strip()


SSH = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8"]


def pick_route(routes: list[str], answers) -> str | None:
    """The first route for which answers(route) is true."""
    return next((r for r in routes if answers(r)), None)


class Target:
    """Runs commands and copies files on the target Mac (or locally, in tests),
    over the first ssh route that answers."""

    PATH = (
        "export PATH=/etc/profiles/per-user/$USER/bin:/run/current-system/sw/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH"
    )

    def __init__(self, dest: Layout, dry: bool) -> None:
        self.host, self.dry, self.route = dest.name, dry, dest.name
        if LOCAL:
            return
        route = pick_route(
            dest.ssh_routes, lambda r: subprocess.run([*SSH, r, "true"], capture_output=True).returncode == 0
        )
        if route is None:
            raise HandoffError(f"can't reach {dest.name} over ssh (tried {', '.join(dest.ssh_routes)})")
        self.route = route
        step(f"reach {dest.name} as {route}")

    def _cmd(self, script: str) -> list[str]:
        return ["sh", "-c", script] if LOCAL else [*SSH, self.route, f"{self.PATH}; {script}"]

    def sh(self, script: str, *, stdin: str | None = None, check: bool = True, mutating: bool = True) -> str:
        if self.dry and mutating:
            out.print(f"    [dim](dry run) on {self.host}:[/dim] {script}")
            return ""
        return run(self._cmd(script), stdin=stdin, check=check)

    def ok(self, script: str) -> bool:
        return subprocess.run(self._cmd(script), capture_output=True).returncode == 0

    def url(self, path: Path) -> str:
        """A path on the target, as git push and rsync take it."""
        return str(path) if LOCAL else f"{self.route}:{path}"

    def push_args(self) -> list[str]:
        # The same ssh options for git, and git on PATH in the target's
        # non-login shell.
        return [] if LOCAL else ["-c", f"core.sshCommand={' '.join(SSH)}"]

    def receive_pack(self) -> list[str]:
        return [] if LOCAL else [f"--receive-pack={self.PATH}; git-receive-pack"]

    def rsync_args(self) -> list[str]:
        return [] if LOCAL else ["-e", " ".join(SSH)]


def step(msg: str) -> None:
    out.print(f"[bold cyan]==>[/bold cyan] {msg}")


def do(dry: bool, cmd: list[str], *, cwd: Path | None = None) -> str:
    if dry:
        out.print(f"    [dim](dry run)[/dim] {' '.join(map(q, cmd))}")
        return ""
    return run(cmd, cwd=cwd)


@dataclass
class Checkout:
    top: Path  # the worktree (or the repo itself) this session works in
    repo: Path  # the main repository
    url: str
    branch: str  # "" when HEAD is detached
    head: str
    snapshot: str  # stash commit of the uncommitted work, "" if there was none
    untracked: list[str]

    @property
    def is_worktree(self) -> bool:
        return self.top != self.repo


def find_checkout(cwd: Path, target: str, dry: bool) -> Checkout | None:
    top_s = run(["git", "-C", str(cwd), "rev-parse", "--show-toplevel"], check=False).strip()
    if not top_s:
        return None
    top = Path(top_s)
    common = Path(git(top, "rev-parse", "--path-format=absolute", "--git-common-dir"))
    repo = common.parent if common.name == ".git" else top
    # The URL as configured: `remote get-url` would apply url.insteadOf.
    url = git(repo, "config", "--get", "remote.origin.url", check=False)
    if not re.search(rf"github\.com[:/]{re.escape(OWNER)}/", url):
        raise HandoffError(
            f"{repo}'s origin ({url or 'none'}) isn't a github.com/{OWNER} repo; {target} couldn't clone it"
        )
    untracked = [f for f in git(top, "ls-files", "--others", "--exclude-standard").splitlines() if f]
    snapshot = ""
    if not dry:
        # Everything uncommitted, untracked files included, as one stash commit;
        # then the index is put back, so this checkout looks exactly as before.
        git(top, "add", "-A")
        try:
            snapshot = git(top, "stash", "create", "handoff snapshot")
        finally:
            git(top, "reset", "-q")
    return Checkout(
        top, repo, url, git(top, "branch", "--show-current"), git(top, "rev-parse", "HEAD"), snapshot, untracked
    )


def move_checkout(co: Checkout, session: str, here: Layout, dest: Layout, tgt: Target, dry: bool) -> Path:
    """Gets the same checkout onto the target; returns its path there."""
    repo_there, top_there = there(co.repo, here, dest), there(co.top, here, dest)
    ref = f"refs/handoff/{session}"

    step(f"make sure {dest.name} has {repo_there}")
    tgt.sh(
        f"[ -e {q(str(repo_there))}/.git ] || {{ mkdir -p {q(str(repo_there.parent))} && git clone -q {q(co.url)} {q(str(repo_there))}; }}"
    )

    what = co.branch or "the detached HEAD"
    step(f"send {what}" + (" and the uncommitted work" if co.snapshot else "") + f" to {dest.name} (ssh, not GitHub)")
    refspecs = [f"+{co.head}:{ref}/head"] + ([f"+{co.snapshot}:{ref}/snapshot"] if co.snapshot else [])
    do(
        dry,
        [
            "git",
            *tgt.push_args(),
            "-C",
            str(co.top),
            "push",
            "-q",
            "--no-verify",
            *tgt.receive_pack(),
            tgt.url(repo_there),
            *refspecs,
        ],
    )

    checkout = f"git checkout -q -B {q(co.branch)} {ref}/head" if co.branch else f"git checkout -q --detach {ref}/head"
    if co.is_worktree:
        enter = (
            f"if [ -e {q(str(top_there))} ]; then cd {q(str(top_there))}; "
            f"else git worktree add -q --detach {q(str(top_there))} {ref}/head && cd {q(str(top_there))}; fi"
        )
    else:
        enter = f"cd {q(str(top_there))}"
    step(
        f"check out {what} in {top_there} on {dest.name}"
        + (", then restore the uncommitted work" if co.snapshot else "")
    )
    tgt.sh(
        "set -e\n"
        f"cd {q(str(repo_there))}\n"
        f"{enter}\n"
        f'if [ -n "$(git status --porcelain)" ]; then echo {q(f"{top_there} has local changes on {dest.name}; not touching it")} >&2; exit 1; fi\n'
        f"{checkout}\n"
        + (f"git stash apply -q {ref}/snapshot\ngit reset -q\n" if co.snapshot else "")
        + f"git update-ref -d {ref}/head\n"
        + (f"git update-ref -d {ref}/snapshot\n" if co.snapshot else "")
    )
    return top_there


def copy_session(
    session: str,
    transcript: Path,
    rewrite: tuple[Path, Path] | None,
    project_there: Path,
    dest: Layout,
    tgt: Target,
    dry: bool,
) -> None:
    step(f"copy session {session} and memory to {dest.name}:{project_there}")
    tgt.sh(f"mkdir -p {q(str(project_there))}")
    text = transcript.read_text(encoding="utf-8")
    if rewrite and rewrite[0] != rewrite[1]:
        text = text.replace(str(rewrite[0]), str(rewrite[1]))
    if dry:
        out.print(
            f"    [dim](dry run)[/dim] write {project_there / transcript.name}"
            + (f" ({rewrite[0]} → {rewrite[1]})" if rewrite else "")
        )
    else:
        tgt.sh(f"cat > {q(str(project_there / transcript.name))}", stdin=text)
    project_dir = transcript.parent
    if (project_dir / session).is_dir():
        do(dry, ["rsync", "-a", *tgt.rsync_args(), f"{project_dir / session}/", tgt.url(project_there / session) + "/"])
    if (project_dir / "memory").is_dir():
        do(
            dry,
            [
                "rsync",
                "-a",
                "--update",
                *tgt.rsync_args(),
                f"{project_dir / 'memory'}/",
                tgt.url(project_there / "memory") + "/",
            ],
        )


def leave_marker(session: str, cwd_there: Path, here: Layout, dest: Layout, tgt: Target, dry: bool) -> None:
    """Tells the target a session waits in cwd_there: on cd there, the zsh hook
    says so, and handoff-resume resumes it."""
    state = q(STATE) if STATE else '"$HOME/.local/state/claude-handoff"'
    marker = json.dumps(
        {"dir": str(cwd_there), "session": session, "command": dest.command, "from": here.name, "at": int(time.time())}
    )
    step(f"leave a marker on {dest.name}: cd {cwd_there}, then handoff-resume")
    tgt.sh(f"mkdir -p {state} && cat > {state}/{q(project_key(cwd_there) + '.json')}", stdin=marker + "\n")


def resume(
    session: str,
    cwd_there: Path,
    window: str,
    tmux_session: str,
    note: str,
    dest: Layout,
    tgt: Target,
    use_tmux: bool,
    dry: bool,
) -> bool:
    """Resumes the session in tmux on the target; False when it couldn't."""
    if not use_tmux:
        return False
    if not dry and not tgt.ok("tmux list-sessions"):
        err.print(
            f"[yellow]{dest.name} has no tmux running.[/yellow] A tmux server started over ssh couldn't reach the local network, so none was started."
        )
        return False
    step(f"resume it on {dest.name} in tmux window {tmux_session}:{window} ({dest.command})")
    start = f"zsh -lc {q(f'{dest.command} --resume {session}; exec zsh -l')}"
    tgt.sh(
        f"tmux has-session -t {q(tmux_session)} 2>/dev/null || tmux new-session -d -s {q(tmux_session)}\n"
        f"tmux new-window -d -t {q(tmux_session)} -n {q(window)} -c {q(str(cwd_there))} {q(start)}"
    )
    if dry:
        out.print(f"    [dim](dry run)[/dim] wait for its prompt, then send: {note}")
        return True
    pane = q(f"{tmux_session}:{window}")
    for _ in range(30):
        if "❯" in tgt.sh(f"tmux capture-pane -p -t {pane}", check=False, mutating=False):
            tgt.sh(
                f"tmux load-buffer -b handoff - && tmux paste-buffer -p -d -b handoff -t {pane} && sleep 1 && tmux send-keys -t {pane} Enter",
                stdin=note,
            )
            return True
        time.sleep(2)
    err.print(
        f"[yellow]warning:[/yellow] {tmux_session}:{window} didn't show a prompt within 60 s; the note wasn't sent"
    )
    return True


def handoff(args: argparse.Namespace) -> None:
    session, transcript, cwd, dry = args.session, args.transcript.resolve(), args.cwd.resolve(), args.dry_run
    if not transcript.is_file():
        raise HandoffError(f"no transcript at {transcript}")
    if transcript.name != f"{session}.jsonl":
        raise HandoffError(f"transcript doesn't belong to session {session}")

    here = layout(this_host())
    target = args.target or here.default_target
    if not target:
        raise HandoffError(f"no --target, and {here.name} has no default target", 2)
    dest = layout(target)
    if dest.name == here.name:
        raise HandoffError(f"already on {dest.name}")
    tgt = Target(dest, dry)

    co = find_checkout(cwd, dest.name, dry)
    if co:
        top_there = move_checkout(co, session, here, dest, tgt, dry)
        cwd_there = top_there / cwd.relative_to(co.top)
        rewrite = (co.top, top_there)
    else:
        cwd_there = there(cwd, here, dest)
        step(f"{cwd} isn't a git repo; moving the session only ({cwd_there} must exist on {dest.name})")
        if not dry and not tgt.ok(f"test -d {q(str(cwd_there))}"):
            raise HandoffError(f"{cwd_there} doesn't exist on {dest.name}")
        rewrite = (cwd, cwd_there)

    project_there = dest.config / "projects" / project_key(cwd_there)
    copy_session(session, transcript, rewrite, project_there, dest, tgt, dry)

    name = co.repo.name if co else cwd.name
    window = args.tmux_window or f"handoff-{name}"
    note = f"Resumed on {dest.name} after a handoff from {here.name}."
    if co:
        note += (
            f" The checkout is at {cwd_there}, on "
            + (f"branch {co.branch}" if co.branch else "a detached HEAD")
            + ", with the uncommitted work restored as it was; nothing was committed or pushed to GitHub."
        )
    note += " Continue autonomously from where the conversation stopped: commit and push after each step, open or update a draft PR when it makes sense, never merge."
    resumed = resume(session, cwd_there, window, args.tmux_session, note, dest, tgt, args.tmux, dry)
    if not resumed:
        leave_marker(session, cwd_there, here, dest, tgt, dry)

    marks = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude") / "quota" / "handed-off"
    if dry:
        out.print(f"    [dim](dry run)[/dim] mark {marks / session}")
    else:
        marks.mkdir(parents=True, exist_ok=True)
        (marks / session).touch()

    if resumed:
        step(f"handed off: continue in {dest.name}'s tmux window {args.tmux_session}:{window}")
    else:
        step(
            f"handed off; on {dest.name}: cd {q(str(cwd_there))} && handoff-resume"
            f" (or {dest.command} --resume {session})"
        )
    if co and co.untracked:
        out.print(
            f"untracked files copied ({len(co.untracked)}): "
            + " ".join(co.untracked[:10])
            + (" …" if len(co.untracked) > 10 else "")
        )


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        prog="claude-handoff", description="Move this Claude Code session to another Mac and resume it there."
    )
    p.add_argument("--session", required=True)
    p.add_argument("--transcript", required=True, type=Path)
    p.add_argument("--cwd", required=True, type=Path)
    p.add_argument("--target", help="host to move to (default: this Mac's default target)")
    p.add_argument(
        "--tmux",
        action="store_true",
        help="also resume it in a window of the target's running tmux (default: leave a marker for handoff-resume)",
    )
    p.add_argument("--tmux-session", default=TMUX_SESSION)
    p.add_argument("--tmux-window", help="window name (default: handoff-<repo>)")
    p.add_argument("--dry-run", action="store_true", help="show the plan without changing anything")
    args = p.parse_args(argv)
    try:
        handoff(args)
        return 0
    except HandoffError as e:
        err.print(f"[bold red]error:[/bold red] {e.message}")
        return e.code
    except KeyboardInterrupt:
        err.print("interrupted")
        return 130


if __name__ == "__main__":
    sys.exit(main())
