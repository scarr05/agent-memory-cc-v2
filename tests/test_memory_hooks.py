"""Harness for the memory hooks and the /memory-sync and /handoff commands.

Every test runs the hook scripts through Git Bash with HOME and CLAUDE_CONFIG_DIR pointed at a
temp folder and OBSIDIAN_CLI_PATH pointed at nothing, so no test can reach the real
~/.claude/memory-staging or the vault. Hooks get crafted JSON on stdin, as Claude Code sends it.
The commands' bash blocks are lifted out of the markdown and run the same way.
"""
import json
import os
import re
import shutil
import subprocess
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
CONTRIB = ROOT  # hooks/ and commands/ at the repo root
GIT_ID = ("-c", "user.name=t", "-c", "user.email=t@t.invalid", "-c", "commit.gpgsign=false")
SID_ONE, SID_TWO = "one-0001", "two-0002"


def _git_bash() -> str | None:
    """Git's own bash: on Windows `bash` on PATH can be WSL's, which has another HOME."""
    if os.name != "nt":
        return shutil.which("bash")
    git = shutil.which("git")
    if not git:
        return None
    for up in (1, 2):
        cand = Path(git).resolve().parents[up] / "bin" / "bash.exe"
        if cand.is_file():
            return str(cand)
    return None


BASH = _git_bash()


def _has_jq() -> bool:
    if not BASH:
        return False
    return subprocess.run([BASH, "-c", "command -v jq"], capture_output=True).returncode == 0


pytestmark = [pytest.mark.skipif(not _has_jq(), reason="needs Git Bash with jq"),
              pytest.mark.slow]


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", *GIT_ID, *args], cwd=cwd, check=True, capture_output=True,
                          text=True).stdout


class World:
    """A temp HOME with this repo's hooks installed, and a project with two linked worktrees."""

    def __init__(self, tmp: Path):
        self.tmp = tmp
        self.home = tmp / "home"
        claude = self.home / ".claude"
        shutil.copytree(CONTRIB / "hooks", claude / "hooks")
        shutil.copytree(CONTRIB / "commands", claude / "commands")
        self.staging = claude / "memory-staging"
        self.main = tmp / "proj"
        self.main.mkdir()
        (self.main / "a.txt").write_text("a\n", encoding="utf-8")
        git(self.main, "init", "-q", "-b", "main")
        git(self.main, "add", "a.txt")
        git(self.main, "commit", "-q", "-m", "base")
        # The marker lives only in the main checkout (untracked), as `/memory-init` leaves it.
        (self.main / ".claude").mkdir()
        (self.main / ".claude" / "CLAUDE.md").write_text(
            "<!-- memory:project-slug=demo -->\n", encoding="utf-8")
        self.wt1 = tmp / "proj-wt" / "1"
        self.wt2 = tmp / "proj-wt" / "2"
        git(self.main, "worktree", "add", "-q", str(self.wt1), "-b", "w1")
        git(self.main, "worktree", "add", "-q", str(self.wt2), "-b", "w2")

    def env(self, **extra: str) -> dict:
        env = {k: v for k, v in os.environ.items()
               if k not in ("CLAUDE_SESSION_ID", "CLAUDE_PLUGIN_ROOT",
                            "MEMORY_HOOK_PLAINTEXT", "SLUG_IGNORE_STATE")}
        env.update(HOME=self.home.as_posix(), CLAUDE_CONFIG_DIR=(self.home / ".claude").as_posix(),
                   OBSIDIAN_CLI_PATH=(self.tmp / "no-obsidian").as_posix(), MSYS_NO_PATHCONV="1")
        env.update(extra)
        return env

    def hook(self, name: str, cwd: Path, payload: dict | str | None = None,
             **extra: str) -> subprocess.CompletedProcess:
        script = (self.home / ".claude" / "hooks" / name).as_posix()
        stdin = payload if isinstance(payload, str) else json.dumps(payload or {})
        out = subprocess.run([BASH, script], input=stdin, cwd=cwd, env=self.env(**extra),
                             capture_output=True, text=True, encoding="utf-8")
        assert out.returncode == 0, f"{name} failed: {out.stderr}"
        return out

    def start(self, cwd: Path, sid: str, source: str = "startup",
              transcript: Path | None = None) -> str:
        payload = {"session_id": sid, "source": source, "hook_event_name": "SessionStart",
                   "cwd": str(cwd)}
        if transcript:
            payload["transcript_path"] = str(transcript)
        return self.hook("session-start.sh", cwd, payload).stdout

    def stop(self, cwd: Path, sid: str, times: int = 1) -> None:
        for _ in range(times):
            self.hook("stop-memory.sh", cwd, {"session_id": sid, "hook_event_name": "Stop"})

    def end(self, cwd: Path, sid: str, reason: str = "other",
            transcript: Path | None = None) -> None:
        payload = {"session_id": sid, "reason": reason, "hook_event_name": "SessionEnd"}
        if transcript:
            payload["transcript_path"] = str(transcript)
        self.hook("session-end.sh", cwd, payload)

    def bash(self, script: str, cwd: Path, **extra: str) -> subprocess.CompletedProcess:
        return subprocess.run([BASH, "-c", script], cwd=cwd, env=self.env(**extra),
                              capture_output=True, text=True, encoding="utf-8")

    def state(self, cwd: Path, *args: str, stdin: str = "",
              **extra: str) -> subprocess.CompletedProcess:
        script = (self.home / ".claude" / "hooks" / "state-lib.sh").as_posix()
        return subprocess.run([BASH, script, *args], input=stdin, cwd=cwd,
                              env=self.env(**extra), capture_output=True, text=True,
                              encoding="utf-8")

    def transcript(self, name: str, edited: str = "src/x.py") -> Path:
        path = self.tmp / "projects" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        line = {"type": "assistant", "message": {"content": [
            {"type": "tool_use", "name": "Edit", "input": {"file_path": edited}}],
            "usage": {"input_tokens": 1000}}}
        path.write_text(json.dumps(line) + "\n", encoding="utf-8")
        return path

    def slugs(self) -> list[str]:
        return sorted(p.name for p in self.staging.iterdir()) if self.staging.exists() else []

    def auto_marker(self, value: str = "true") -> None:
        """Opt the project into auto memory, in the main checkout only (as /memory-init would)."""
        (self.main / ".claude" / "CLAUDE.md").write_text(
            f"<!-- memory:project-slug=demo -->\n<!-- memory:auto={value} -->\n", encoding="utf-8")

    def meta(self, sid: str, slug: str = "demo") -> dict[str, str]:
        text = (self.staging / slug / "sessions" / sid / ".session-meta").read_text(encoding="utf-8")
        return dict(line.split("=", 1) for line in text.splitlines() if "=" in line)


@pytest.fixture
def world(tmp_path):
    return World(tmp_path)


def kv(text: str) -> dict[str, str]:
    return dict(line.split("=", 1) for line in text.splitlines() if re.match(r"^[A-Z_]+=", line))


def bash_block(command: str, heading: str) -> str:
    """The first ```bash block under `heading` in one of the repo's command files."""
    text = (CONTRIB / "commands" / command).read_text(encoding="utf-8")
    section = text.split(heading, 1)[1]
    return re.search(r"```bash\n(.*?)```", section, re.S).group(1)


def as_command(block: str, arguments: str, session: str) -> str:
    """What Claude Code hands the Bash tool: $ARGUMENTS and ${CLAUDE_SESSION_ID} substituted."""
    return block.replace("$ARGUMENTS", arguments).replace("${CLAUDE_SESSION_ID}", session)


# ---- Box 1: state keyed by session ------------------------------------------------------------

def test_two_sessions_in_one_project_keep_their_own_meta(world):
    world.start(world.main, SID_ONE)
    world.stop(world.main, SID_ONE, times=3)
    world.start(world.wt1, SID_TWO)  # used to reset the first session's message_count
    world.stop(world.wt1, SID_TWO)
    assert world.meta(SID_ONE)["message_count"] == "3"
    assert world.meta(SID_TWO)["message_count"] == "1"
    assert not (world.staging / "demo" / ".session-meta").exists()


def test_transcript_breadcrumb_is_per_session(world):
    sam, two = world.transcript("sam.jsonl"), world.transcript("two.jsonl")
    world.start(world.main, SID_ONE, transcript=sam)
    world.start(world.wt1, SID_TWO, transcript=two)
    crumb = lambda sid: (world.staging / "demo" / "sessions" / sid / ".transcript-path").read_text(
        encoding="utf-8").strip()
    assert crumb(SID_ONE) == str(sam)
    assert crumb(SID_TWO) == str(two)




def test_an_unsynced_session_warns_the_next(world):
    world.start(world.main, SID_ONE)
    world.stop(world.main, SID_ONE, times=10)
    world.end(world.main, SID_ONE)
    assert "never synced" in world.start(world.main, "sam-0006")


def test_a_worktree_session_hands_off_through_the_project_slot(world):
    """relay-baton, /wrap and memory-load read <slug>/handoff.md."""
    world.start(world.wt2, SID_ONE)
    world.end(world.wt2, SID_ONE, reason="clear", transcript=world.transcript("sam.jsonl"))
    assert (world.staging / "demo" / "handoff.md").is_file()


def test_hook_input_without_a_session_id_keeps_the_old_layout(world):
    world.hook("session-start.sh", world.main, {"source": "startup"})
    world.hook("stop-memory.sh", world.main, {})
    meta = (world.staging / "demo" / ".session-meta").read_text(encoding="utf-8")
    assert "message_count=1" in meta
    assert not (world.staging / "demo" / "sessions").exists()


def test_session_id_is_clamped_before_it_becomes_a_path(world):
    world.start(world.main, "../../evil id")
    assert (world.staging / "demo" / "sessions" / "evilid" / ".session-meta").is_file()
    assert sorted(p.name for p in (world.staging / "demo" / "sessions").iterdir()) == ["evilid"]


def test_stale_session_folders_are_pruned_at_start(world):
    old = world.staging / "demo" / "sessions" / "old-0001"
    old.mkdir(parents=True)
    (old / ".session-meta").write_text("message_count=4\n", encoding="utf-8")
    stamp = time.time() - 9 * 86400
    os.utime(old / ".session-meta", (stamp, stamp))
    os.utime(old, (stamp, stamp))
    world.start(world.main, SID_ONE)
    assert not old.exists()
    assert (world.staging / "demo" / "sessions" / SID_ONE).is_dir()


def test_previous_session_hint_reads_the_last_session(world):
    world.start(world.main, SID_ONE)
    world.stop(world.main, SID_ONE, times=12)
    assert "Previous session had 12 messages" in world.start(world.main, "sam-0007")


def test_pre_compact_clears_read_once_cache_for_the_session_on_stdin(world):
    cache = world.home / ".claude" / "read-once" / "cache"
    (cache / SID_ONE).mkdir(parents=True)
    (cache / SID_TWO).mkdir(parents=True)
    world.hook("pre-compact.sh", world.main, {"session_id": SID_ONE, "trigger": "auto"})
    assert not (cache / SID_ONE).exists()
    assert (cache / SID_TWO).exists()


def test_mark_synced_marks_only_the_named_session(world):
    world.start(world.main, SID_ONE)
    world.start(world.wt1, SID_TWO)
    world.stop(world.wt1, SID_TWO, times=10)
    world.end(world.wt1, SID_TWO)
    out = world.state(world.wt1, "mark", "synced", "--session", SID_TWO)
    assert out.returncode == 0, out.stderr
    two = world.meta(SID_TWO)
    assert two["synced"] == "true" and two["message_count"] == "0"
    assert int(two["synced_at"]) >= int(time.time()) - 60
    assert "synced" not in world.meta(SID_ONE)
    assert not (world.staging / "demo" / ".unsynced").exists()


def test_synced_session_is_not_flagged_unsynced(world):
    world.start(world.wt1, SID_TWO)
    world.stop(world.wt1, SID_TWO, times=10)
    world.state(world.wt1, "mark", "synced", "--session", SID_TWO)
    world.stop(world.wt1, SID_TWO, times=10)
    world.end(world.wt1, SID_TWO)
    assert not (world.staging / "demo" / ".unsynced").exists()


def test_paths_falls_back_to_the_slots_last_session(world):
    world.start(world.wt1, SID_TWO, transcript=world.transcript("two.jsonl"))
    out = kv(world.state(world.wt1, "paths", "--session", "").stdout)
    assert out["SESSION_ID"] == SID_TWO and out["SESSION_SOURCE"] == "pointer"
    assert out["SLOT_DIR"].endswith("/demo")
    assert out["TRANSCRIPT"].endswith("two.jsonl")


# ---- Box 2: a worktree maps to its project's slug ---------------------------------------------

def test_worktrees_share_the_projects_staging_folder(world):
    sub = world.wt2 / "src"
    sub.mkdir()
    for i, cwd in enumerate((world.main, world.wt1, world.wt2, sub)):
        world.start(cwd, f"s-{i}")
        world.stop(cwd, f"s-{i}")
    assert world.slugs() == ["demo"]
    assert len(list((world.staging / "demo" / "sessions").iterdir())) == 4


def test_worktrees_without_marker_or_remote_share_the_main_folder_name(world):
    (world.main / ".claude" / "CLAUDE.md").unlink()
    for cwd in (world.main, world.wt1, world.wt2 / "."):
        world.start(cwd, "x")
    assert world.slugs() == ["proj"]


def test_worktree_subdirectory_without_marker_or_remote(world):
    (world.main / ".claude" / "CLAUDE.md").unlink()
    sub = world.wt1 / "deep" / "er"
    sub.mkdir(parents=True)
    world.start(sub, "x")
    world.stop(sub, "x")
    assert world.slugs() == ["proj"]


def test_relative_path_worktree_shares_the_projects_staging_folder(world):
    rel = world.tmp / "proj-wt" / "rel"
    git(world.main, "-c", "worktree.useRelativePaths=true", "worktree", "add", "-q", str(rel),
        "-b", "rel")
    assert not Path((rel / ".git").read_text(encoding="utf-8").split(": ", 1)[1].strip()).is_absolute()
    world.start(rel / ".", "x")
    world.stop(rel, "x")
    assert world.slugs() == ["demo"]


def test_state_file_in_a_worktree_stays_out_of_git_status(world):
    world.start(world.wt1, SID_TWO)
    assert (world.wt1 / ".claude" / "memory-state.json").is_file()
    assert ".claude" not in git(world.wt1, "status", "--porcelain")


# ---- Box 3: --auto, a real mode for /memory-sync and /handoff ---------------------------------

@pytest.mark.parametrize("args, mode, auto", [
    ("", "standard", "0"),
    ("--auto", "standard", "1"),
    ("--dream --auto", "dream", "1"),
    ("--status", "status", "0"),
    ("--ingest", "ingest", "0"),
])
def test_memory_sync_arguments(world, args, mode, auto):
    out = world.state(world.main, "args", "memory-sync", stdin=args)
    assert out.returncode == 0, out.stderr
    got = kv(out.stdout)
    assert (got["MODE"], got["AUTO"]) == (mode, auto)


@pytest.mark.parametrize("cwd", ["main", "wt1"])
def test_a_project_marker_makes_every_run_auto(world, cwd):
    """The marker is untracked in the main checkout; a linked worktree reads it from there."""
    world.auto_marker()
    for cmd in ("memory-sync", "handoff"):
        out = kv(world.state(getattr(world, cwd), "args", cmd, stdin="").stdout)
        assert out["AUTO"] == "1" and out["AUTO_WHY"] == "project", (cmd, out)


def test_the_flag_wins_over_the_marker_as_the_reason(world):
    world.auto_marker()
    out = kv(world.state(world.main, "args", "memory-sync", stdin="--auto").stdout)
    assert out["AUTO"] == "1" and out["AUTO_WHY"] == "flag"


@pytest.mark.parametrize("value", ["false", "no", "TRUE"])
def test_only_auto_true_turns_the_marker_on(world, value):
    world.auto_marker(value)
    out = kv(world.state(world.main, "args", "memory-sync", stdin="").stdout)
    assert out["AUTO"] == "0" and "AUTO_WHY" not in out


def test_session_start_tells_claude_when_auto_memory_is_on(world):
    assert "Auto memory is on" not in world.start(world.main, SID_ONE)
    world.auto_marker()
    assert "Auto memory is on" in world.start(world.wt1, SID_TWO)
    assert "Auto memory is on" in world.start(world.main, "sam-0009", source="clear")


@pytest.mark.parametrize("args", ["--bogus", "--dream --status", "auto", "--auto --auto=no"])
def test_memory_sync_refuses_arguments_it_does_not_know(world, args):
    out = world.state(world.main, "args", "memory-sync", stdin=args)
    assert out.returncode == 2
    assert "memory-sync" in out.stderr


def test_handoff_arguments_keep_a_note(world):
    out = kv(world.state(world.main, "args", "handoff", stdin="--auto finish the parser's tests\n").stdout)
    assert out == {"COMMAND": "handoff", "MODE": "handoff", "AUTO": "1", "AUTO_WHY": "flag",
                   "NOTE": "finish the parser's tests"}
    assert world.state(world.main, "args", "handoff", stdin="--force").returncode == 2


def test_handoff_auto_arms_with_another_session_active_in_the_project(world):
    """Steps 1, 2 and 4 of handoff.md as written, with the other transcript just as fresh."""
    sam, two = world.transcript("sam.jsonl"), world.transcript("two.jsonl", "src/two.py")
    world.start(world.main, SID_ONE, transcript=sam)
    world.start(world.wt1, SID_TWO, transcript=two)
    step1 = world.bash(as_command(bash_block("handoff.md", "## Step 1"), "--auto", SID_TWO),
                       world.wt1)
    assert step1.returncode == 0, step1.stderr
    got = kv(step1.stdout)
    assert got["AUTO"] == "1" and got["AMBIGUOUS"] == "0" and got["SESSION_SOURCE"] == "given"
    assert got["TRANSCRIPT"] == str(two)
    # Bash may spell HOME its own way (/tmp/...), so compare the part under it.
    assert got["HANDOFF"].endswith("/.claude/memory-staging/demo/handoff.md")
    handoff = world.staging / "demo" / "handoff.md"
    env = {k: got[k] for k in ("LIB", "TRANSCRIPT", "SLUG", "HANDOFF", "CONSUMED", "HOOKS")}
    step2 = world.bash(bash_block("handoff.md", "## Step 2"), world.wt1, **env)
    assert step2.returncode == 0, step2.stderr
    assert "src/two.py" in handoff.read_text(encoding="utf-8")
    # Step 3 is the model's: fill the two sentinels.
    text = handoff.read_text(encoding="utf-8")
    text = text.replace("<!-- HANDOFF:NARRATIVE -->",
                        "Mid-way through the parser; next, run the tests in tests/test_parse.py.")
    text = text.replace("<!-- HANDOFF:DONOTREDO -->", "- None.")
    handoff.write_text(text, encoding="utf-8")
    step4 = world.bash(as_command(bash_block("handoff.md", "## Step 4"), "--auto", SID_TWO),
                       world.wt1, **env)
    assert step4.returncode == 0, step4.stderr
    assert "ARMED:" in step4.stdout
    assert "handoff_at" in world.meta(SID_TWO)
    assert "handoff_at" not in world.meta(SID_ONE)


def test_handoff_step1_without_a_session_id_still_refuses_when_two_sessions_are_live(world):
    """The old ambiguity gate stays for the fallback: a Claude Code that does not substitute."""
    dir_ = world.tmp / "projects"
    sam = world.transcript("sam.jsonl")
    world.start(world.main, SID_ONE, transcript=sam)
    (dir_ / "other.jsonl").write_text("{}\n", encoding="utf-8")
    step1 = world.bash(as_command(bash_block("handoff.md", "## Step 1"), "", ""), world.main)
    got = kv(step1.stdout)
    assert got["SESSION_SOURCE"] == "pointer" and got["AMBIGUOUS"] == "1"


def test_memory_sync_step6_marks_this_session_only(world):
    world.start(world.main, SID_ONE)
    world.start(world.wt1, SID_TWO)
    handoff = world.staging / "demo" / "handoff.md"
    handoff.write_text("armed\n", encoding="utf-8")
    block = as_command(bash_block("memory-sync.md", "### Step 6"), "--auto", SID_TWO)
    out = world.bash(block, world.wt1)
    assert out.returncode == 0, out.stderr
    assert world.meta(SID_TWO)["synced"] == "true"
    assert "synced" not in world.meta(SID_ONE)
    assert not handoff.exists()


def test_memory_sync_step0_prints_the_mode(world):
    block = as_command(bash_block("memory-sync.md", "### Step 0"), "--auto", SID_ONE)
    world.start(world.main, SID_ONE)
    got = kv(world.bash(block, world.main).stdout)
    assert got["AUTO"] == "1" and got["MODE"] == "standard" and got["SESSION_ID"] == SID_ONE


def test_commands_ask_nothing_in_auto_mode():
    """Each question site in the two commands names what --auto does instead."""
    sync = (CONTRIB / "commands" / "memory-sync.md").read_text(encoding="utf-8")
    auto = sync.split("## Auto mode", 1)[1].split("\n## ", 1)[0]
    for site in ("trivial", "AskUserQuestion", "--dream", "Step 7"):
        assert site in auto, site
    handoff = (CONTRIB / "commands" / "handoff.md").read_text(encoding="utf-8")
    assert "## Auto mode" in handoff
    assert "state-lib.sh\" args handoff" in handoff and "state-lib.sh\" args memory-sync" in sync


def test_commands_inline_the_decisions_template():
    """config/ is not installed beside the commands, so each command that creates
    _decisions.md carries the template; this keeps the copies equal to the source."""
    template = (CONTRIB / "config" / "decisions-template.md").read_text(encoding="utf-8").strip()
    for name in ("decision.md", "memory-sync.md", "memory-init.md"):
        text = (CONTRIB / "commands" / name).read_text(encoding="utf-8")
        assert "```markdown\n" + template + "\n```" in text, name
