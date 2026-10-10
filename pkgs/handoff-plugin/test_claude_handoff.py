"""Tests for claude-handoff. The end-to-end ones run the real flow between two
local "Macs" (CLAUDE_HANDOFF_LOCAL: no ssh), with a fake GitHub: a local bare
repo standing in for git@github.com:someone/proj.git through url.insteadOf.

    uv run --with pytest --with rich pytest pkgs/handoff-plugin
HANDOFF_SCRIPT points them at a built claude-handoff instead of the source.
"""

import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(os.environ.get("HANDOFF_SCRIPT") or Path(__file__).with_name("claude-handoff.py"))
SESSION = "11111111-2222-3333-4444-555555555555"
URL = "git@github.com:someone/proj.git"


def load():
    spec = importlib.util.spec_from_loader("handoff", loader=None)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["handoff"] = mod
    exec(compile(SCRIPT.read_text().replace("@OWNER@", "someone"), str(SCRIPT), "exec"), mod.__dict__)
    return mod


def sh(*cmd, cwd=None, env=None):
    return subprocess.run(cmd, cwd=cwd, env=env, check=True, capture_output=True, text=True).stdout.rstrip()


@pytest.fixture
def world(tmp_path):
    """Two hosts: alpha (sources in a/src/u, like arrakis) and beta (b/src)."""
    a, b = tmp_path / "a", tmp_path / "b"
    hosts = {
        "alpha": {
            "src": str(a / "src/u"),
            "configDir": str(a / "cfg"),
            "command": "claude-personal",
            "defaultTarget": "beta",
        },
        "beta": {"src": str(b / "src"), "configDir": str(b / "cfg"), "command": "claude", "defaultTarget": None},
    }
    origin = tmp_path / "github/proj.git"
    gitconfig = tmp_path / "gitconfig"
    gitconfig.write_text(
        f'[url "{origin}"]\n\tinsteadOf = {URL}\n[user]\n\tname = t\n\temail = t@t\n'
        "[init]\n\tdefaultBranch = main\n[commit]\n\tgpgsign = false\n"
    )
    env = {
        **os.environ,
        "GIT_CONFIG_GLOBAL": str(gitconfig),
        "GIT_CONFIG_NOSYSTEM": "1",
        "CLAUDE_HANDOFF_LOCAL": "1",
        "CLAUDE_HANDOFF_HOST": "alpha",
        "CLAUDE_HANDOFF_OWNER": "someone",
        "CLAUDE_HANDOFF_HOSTS": json.dumps(hosts),
        "CLAUDE_CONFIG_DIR": str(a / "cfg"),
    }

    sh("git", "init", "-q", "--bare", str(origin), env=env)
    repo = a / "src/u/proj"
    sh("git", "clone", "-q", URL, str(repo), env=env)
    (repo / "readme.md").write_text("v1\n")
    sh("git", "add", "readme.md", cwd=repo, env=env)
    sh("git", "commit", "-qm", "first", cwd=repo, env=env)
    sh("git", "push", "-q", "origin", "main", cwd=repo, env=env)

    # The session's worktree: a branch never pushed, an unpushed commit,
    # a modified file and a new untracked one.
    wt = repo / ".claude/worktrees/feat"
    sh("git", "worktree", "add", "-q", "-b", "feat", str(wt), cwd=repo, env=env)
    (wt / "readme.md").write_text("v2 committed\n")
    sh("git", "commit", "-qam", "local only", cwd=wt, env=env)
    (wt / "readme.md").write_text("v3 uncommitted\n")
    (wt / "new.txt").write_text("untracked\n")
    (wt / "sub").mkdir()

    project = a / "cfg/projects/key"
    project.mkdir(parents=True)
    transcript = project / f"{SESSION}.jsonl"
    transcript.write_text(json.dumps({"cwd": str(wt / "sub"), "msg": f"edited {wt}/readme.md"}) + "\n")
    (project / "memory").mkdir()
    (project / "memory/note.md").write_text("remember\n")
    (b / "cfg").mkdir(parents=True)
    return dict(a=a, b=b, repo=repo, wt=wt, origin=origin, env=env, transcript=transcript)


def handoff(w, *extra, cwd=None):
    return subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--session",
            SESSION,
            "--transcript",
            str(w["transcript"]),
            "--cwd",
            str(cwd or w["wt"] / "sub"),
            "--no-tmux",
            *extra,
        ],
        env=w["env"],
        capture_output=True,
        text=True,
    )


def test_moves_worktree_with_uncommitted_work(world):
    w = world
    head_before = sh("git", "rev-parse", "HEAD", cwd=w["wt"])
    status_before = sh("git", "status", "--porcelain", cwd=w["wt"])

    r = handoff(w)
    assert r.returncode == 0, r.stdout + r.stderr

    wt_there = w["b"] / "src/proj/.claude/worktrees/feat"
    assert sh("git", "branch", "--show-current", cwd=wt_there) == "feat"
    assert sh("git", "rev-parse", "HEAD", cwd=wt_there) == head_before  # the unpushed commit made it
    assert (wt_there / "readme.md").read_text() == "v3 uncommitted\n"  # uncommitted, restored
    assert (wt_there / "new.txt").read_text() == "untracked\n"  # untracked, copied
    status_there = sh("git", "status", "--porcelain", cwd=wt_there)
    assert " M readme.md" in status_there and "?? new.txt" in status_there  # nothing staged or committed
    assert sh("git", "for-each-ref", "refs/handoff", cwd=w["b"] / "src/proj") == ""  # cleaned up

    # This side is exactly as it was, and GitHub got nothing.
    assert sh("git", "rev-parse", "HEAD", cwd=w["wt"]) == head_before
    assert sh("git", "status", "--porcelain", cwd=w["wt"]) == status_before
    assert sh("git", "stash", "list", cwd=w["wt"]) == ""
    assert (
        sh("git", "branch", "--list", cwd=w["origin"]) == "main"
        or sh("git", "for-each-ref", "--format=%(refname)", "refs/heads", cwd=w["origin"]) == "refs/heads/main"
    )

    # The session, with paths in the target's layout.
    project_there = w["b"] / "cfg/projects" / str(wt_there / "sub").replace("/", "-").replace(".", "-")
    text = (project_there / f"{SESSION}.jsonl").read_text()
    assert str(wt_there) in text and str(w["wt"]) not in text
    assert (project_there / "memory/note.md").read_text() == "remember\n"
    assert (w["a"] / "cfg/quota/handed-off" / SESSION).exists()
    assert f"cd {wt_there / 'sub'} && claude --resume {SESSION}" in r.stdout


def test_reuses_existing_target_worktree(world):
    w = world
    assert handoff(w).returncode == 0
    (w["wt"] / "readme.md").write_text("v4\n")
    wt_there = w["b"] / "src/proj/.claude/worktrees/feat"
    sh("git", "checkout", "-q", "--", ".", cwd=wt_there)  # target clean again
    sh("git", "clean", "-qfd", cwd=wt_there)
    r = handoff(w)
    assert r.returncode == 0, r.stderr
    assert (wt_there / "readme.md").read_text() == "v4\n"


def test_refuses_dirty_target(world):
    w = world
    assert handoff(w).returncode == 0  # target worktree now has the moved changes
    r = handoff(w)
    assert r.returncode == 1 and "has local changes" in r.stderr


def test_main_checkout_not_a_worktree(world):
    w = world
    (w["repo"] / "readme.md").write_text("main dirty\n")
    r = handoff(w, cwd=w["repo"])
    assert r.returncode == 0, r.stderr
    there = w["b"] / "src/proj"
    assert sh("git", "branch", "--show-current", cwd=there) == "main"
    assert (there / "readme.md").read_text() == "main dirty\n"


def test_refuses_foreign_repo(world):
    w = world
    sh("git", "remote", "set-url", "origin", "git@github.com:employer/proj.git", cwd=w["repo"])
    r = handoff(w)
    assert r.returncode == 1 and "isn't a github.com/someone repo" in r.stderr
    assert sh("git", "status", "--porcelain", cwd=w["wt"]) != ""  # untouched


def test_unknown_and_same_host(world):
    w = world
    r = handoff(w, "--target", "imperum")
    assert r.returncode == 2 and 'unknown host "imperum"' in r.stderr
    r = handoff(w, "--target", "alpha")
    assert r.returncode == 1 and "already on alpha" in r.stderr


def test_dry_run_changes_nothing(world):
    w = world
    status = sh("git", "status", "--porcelain", cwd=w["wt"])
    r = handoff(w, "--dry-run")
    assert r.returncode == 0, r.stderr
    assert not (w["b"] / "src/proj").exists()
    assert sh("git", "status", "--porcelain", cwd=w["wt"]) == status
    assert not (w["a"] / "cfg/quota/handed-off" / SESSION).exists()


def test_there_and_project_key():
    m = load()
    here = m.Layout("alpha", Path("/U/src/u"), Path("/U/src/u/.claude"), "claude-personal", "beta")
    dest = m.Layout("beta", Path("/U/src"), Path("/U/.claude"), "claude", None)
    assert m.there(Path("/U/src/u/proj/x"), here, dest) == Path("/U/src/proj/x")
    assert m.there(Path("/tmp/x"), here, dest) == Path("/tmp/x")
    assert m.project_key(Path("/U/src/proj/.claude/w")) == "-U-src-proj--claude-w"


def test_routes_in_order():
    m = load()
    dest = m.Layout("imperium", Path("/U/src"), Path("/U/.claude"), "claude", None, ("m2",))
    assert dest.ssh_routes == ["imperium.airshell", "imperium.local", "imperium", "m2"]
    # airshell down: the local network wins; only the cloudflared alias works: it's used.
    assert m.pick_route(dest.ssh_routes, lambda r: r != "imperium.airshell") == "imperium.local"
    assert m.pick_route(dest.ssh_routes, lambda r: r == "m2") == "m2"
    assert m.pick_route(dest.ssh_routes, lambda r: False) is None
