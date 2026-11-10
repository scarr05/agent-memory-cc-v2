"""Harness for the memory hooks and the /memory-sync and /handoff commands.

Ported from cc-chief tests/test_memory_hooks.py (cc-chief #42 / PR #99), so this repo owns it.

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
SID_SAM, SID_LEAD = "sam-0001", "lead-0002"


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

    def env(self, lead: bool = False, **extra: str) -> dict:
        env = {k: v for k, v in os.environ.items()
               if k not in ("CHIEF_LEAD", "CLAUDE_SESSION_ID", "CLAUDE_PLUGIN_ROOT",
                            "MEMORY_HOOK_PLAINTEXT", "SLUG_IGNORE_STATE")}
        env.update(HOME=self.home.as_posix(), CLAUDE_CONFIG_DIR=(self.home / ".claude").as_posix(),
                   OBSIDIAN_CLI_PATH=(self.tmp / "no-obsidian").as_posix(), MSYS_NO_PATHCONV="1")
        if lead:
            env["CHIEF_LEAD"] = "1"
        env.update(extra)
        return env

    def hook(self, name: str, cwd: Path, payload: dict | str | None = None, lead: bool = False,
             **extra: str) -> subprocess.CompletedProcess:
        script = (self.home / ".claude" / "hooks" / name).as_posix()
        stdin = payload if isinstance(payload, str) else json.dumps(payload or {})
        out = subprocess.run([BASH, script], input=stdin, cwd=cwd, env=self.env(lead, **extra),
                             capture_output=True, text=True, encoding="utf-8")
        assert out.returncode == 0, f"{name} failed: {out.stderr}"
        return out

    def start(self, cwd: Path, sid: str, source: str = "startup", lead: bool = False,
              transcript: Path | None = None) -> str:
        payload = {"session_id": sid, "source": source, "hook_event_name": "SessionStart",
                   "cwd": str(cwd)}
        if transcript:
            payload["transcript_path"] = str(transcript)
        return self.hook("session-start.sh", cwd, payload, lead).stdout

    def stop(self, cwd: Path, sid: str, lead: bool = False, times: int = 1) -> None:
        for _ in range(times):
            self.hook("stop-memory.sh", cwd, {"session_id": sid, "hook_event_name": "Stop"}, lead)

    def end(self, cwd: Path, sid: str, reason: str = "other", lead: bool = False,
            transcript: Path | None = None) -> None:
        payload = {"session_id": sid, "reason": reason, "hook_event_name": "SessionEnd"}
        if transcript:
            payload["transcript_path"] = str(transcript)
        self.hook("session-end.sh", cwd, payload, lead)

    def bash(self, script: str, cwd: Path, lead: bool = False,
             **extra: str) -> subprocess.CompletedProcess:
        return subprocess.run([BASH, "-c", script], cwd=cwd, env=self.env(lead, **extra),
                              capture_output=True, text=True, encoding="utf-8")

    def state(self, cwd: Path, *args: str, stdin: str = "", lead: bool = False,
              **extra: str) -> subprocess.CompletedProcess:
        script = (self.home / ".claude" / "hooks" / "state-lib.sh").as_posix()
        return subprocess.run([BASH, script, *args], input=stdin, cwd=cwd,
                              env=self.env(lead, **extra), capture_output=True, text=True,
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
    world.start(world.main, SID_SAM)
    world.stop(world.main, SID_SAM, times=3)
    world.start(world.wt1, SID_LEAD, lead=True)  # used to reset Sam's message_count to 0
    world.stop(world.wt1, SID_LEAD)
    assert world.meta(SID_SAM)["message_count"] == "3"
    assert world.meta(SID_LEAD)["message_count"] == "1"
    assert not (world.staging / "demo" / ".session-meta").exists()


def test_transcript_breadcrumb_is_per_session(world):
    sam, lead = world.transcript("sam.jsonl"), world.transcript("lead.jsonl")
    world.start(world.main, SID_SAM, transcript=sam)
    world.start(world.wt1, SID_LEAD, lead=True, transcript=lead)
    crumb = lambda sid: (world.staging / "demo" / "sessions" / sid / ".transcript-path").read_text(
        encoding="utf-8").strip()
    assert crumb(SID_SAM) == str(sam)
    assert crumb(SID_LEAD) == str(lead)


def test_lead_clear_neither_overwrites_nor_consumes_sams_handoff(world):
    world.start(world.main, SID_SAM)
    sams = world.staging / "demo" / "handoff.md"
    sams.write_text("---\nsource: \"handoff\"\n---\nSam's armed handoff\n", encoding="utf-8")
    world.start(world.wt1, SID_LEAD, lead=True)
    world.stop(world.wt1, SID_LEAD, lead=True)
    # The lead's bare /clear harvests a clear-fallback into its own slot ...
    world.end(world.wt1, SID_LEAD, reason="clear", lead=True,
              transcript=world.transcript("lead.jsonl"))
    lead_slot = world.staging / "demo" / "leads" / "1"
    assert (lead_slot / "handoff.md").is_file()
    assert sams.read_text(encoding="utf-8").endswith("Sam's armed handoff\n")
    # ... and the lead's next session picks up its own, leaving Sam's armed.
    out = world.start(world.wt1, "lead-0003", source="clear", lead=True)
    assert "RESUMING FROM HANDOFF" in out and "Auto-harvested on bare /clear" in out
    assert (lead_slot / "handoff.consumed.md").is_file() and sams.is_file()
    out = world.start(world.main, "sam-0004", source="clear")
    assert "RESUMING FROM HANDOFF" in out
    assert (world.staging / "demo" / "handoff.consumed.md").is_file()


def test_unsynced_lead_session_does_not_warn_sam(world):
    world.start(world.wt1, SID_LEAD, lead=True)
    world.stop(world.wt1, SID_LEAD, lead=True, times=10)
    world.end(world.wt1, SID_LEAD, lead=True)
    assert (world.staging / "demo" / "leads" / "1" / ".unsynced").is_file()
    assert "never synced" not in world.start(world.main, SID_SAM)
    assert "never synced" in world.start(world.wt1, "lead-0005", lead=True)


def test_unsynced_sam_session_still_warns_sam(world):
    world.start(world.main, SID_SAM)
    world.stop(world.main, SID_SAM, times=10)
    world.end(world.main, SID_SAM)
    assert "never synced" in world.start(world.main, "sam-0006")


def test_sams_sessions_in_two_worktrees_share_his_slot(world):
    """Only leads get their own slot: relay-baton, /wrap and memory-load read <slug>/handoff.md."""
    world.start(world.wt2, SID_SAM)
    world.end(world.wt2, SID_SAM, reason="clear", transcript=world.transcript("sam.jsonl"))
    assert (world.staging / "demo" / "handoff.md").is_file()
    assert not (world.staging / "demo" / "leads").exists()


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
    world.start(world.main, SID_SAM)
    assert not old.exists()
    assert (world.staging / "demo" / "sessions" / SID_SAM).is_dir()


def test_previous_session_hint_reads_this_slots_last_session(world):
    world.start(world.main, SID_SAM)
    world.stop(world.main, SID_SAM, times=12)
    world.start(world.wt1, SID_LEAD, lead=True)  # a lead starting in between changes nothing
    assert "Previous session had 12 messages" in world.start(world.main, "sam-0007")


def test_pre_compact_clears_read_once_cache_for_the_session_on_stdin(world):
    cache = world.home / ".claude" / "read-once" / "cache"
    (cache / SID_SAM).mkdir(parents=True)
    (cache / SID_LEAD).mkdir(parents=True)
    world.hook("pre-compact.sh", world.main, {"session_id": SID_SAM, "trigger": "auto"})
    assert not (cache / SID_SAM).exists()
    assert (cache / SID_LEAD).exists()


def test_mark_synced_marks_only_the_named_session(world):
    world.start(world.main, SID_SAM)
    world.start(world.wt1, SID_LEAD, lead=True)
    world.stop(world.wt1, SID_LEAD, lead=True, times=10)
    world.end(world.wt1, SID_LEAD, lead=True)
    out = world.state(world.wt1, "mark", "synced", "--session", SID_LEAD, lead=True)
    assert out.returncode == 0, out.stderr
    lead = world.meta(SID_LEAD)
    assert lead["synced"] == "true" and lead["message_count"] == "0"
    assert int(lead["synced_at"]) >= int(time.time()) - 60
    assert "synced" not in world.meta(SID_SAM)
    assert not (world.staging / "demo" / "leads" / "1" / ".unsynced").exists()


def test_synced_session_is_not_flagged_unsynced(world):
    world.start(world.wt1, SID_LEAD, lead=True)
    world.stop(world.wt1, SID_LEAD, lead=True, times=10)
    world.state(world.wt1, "mark", "synced", "--session", SID_LEAD, lead=True)
    world.stop(world.wt1, SID_LEAD, lead=True, times=10)
    world.end(world.wt1, SID_LEAD, lead=True)
    assert not (world.staging / "demo" / "leads" / "1" / ".unsynced").exists()


def test_paths_falls_back_to_the_slots_last_session(world):
    world.start(world.wt1, SID_LEAD, lead=True, transcript=world.transcript("lead.jsonl"))
    out = kv(world.state(world.wt1, "paths", "--session", "", lead=True).stdout)
    assert out["SESSION_ID"] == SID_LEAD and out["SESSION_SOURCE"] == "pointer"
    assert out["SLOT_DIR"].endswith("/demo/leads/1")
    assert out["TRANSCRIPT"].endswith("lead.jsonl")


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
    world.start(world.wt1, SID_LEAD, lead=True)
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


def test_a_lead_is_always_auto(world):
    out = kv(world.state(world.wt1, "args", "memory-sync", stdin="", lead=True).stdout)
    assert out["AUTO"] == "1" and out["AUTO_WHY"] == "lead"


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


def test_handoff_auto_arms_from_the_lead_with_sam_active_in_the_project(world):
    """Steps 1, 2 and 4 of handoff.md as written, with Sam's transcript just as fresh."""
    sam, lead = world.transcript("sam.jsonl"), world.transcript("lead.jsonl", "src/lead.py")
    world.start(world.main, SID_SAM, transcript=sam)
    world.start(world.wt1, SID_LEAD, lead=True, transcript=lead)
    step1 = world.bash(as_command(bash_block("handoff.md", "## Step 1"), "--auto", SID_LEAD),
                       world.wt1, lead=True)
    assert step1.returncode == 0, step1.stderr
    got = kv(step1.stdout)
    assert got["AUTO"] == "1" and got["AMBIGUOUS"] == "0" and got["SESSION_SOURCE"] == "given"
    assert got["TRANSCRIPT"] == str(lead)
    # Bash may spell HOME its own way (/tmp/...), so compare the part under it.
    assert got["HANDOFF"].endswith("/.claude/memory-staging/demo/leads/1/handoff.md")
    handoff = world.staging / "demo" / "leads" / "1" / "handoff.md"
    env = {k: got[k] for k in ("LIB", "TRANSCRIPT", "SLUG", "HANDOFF", "CONSUMED", "HOOKS")}
    step2 = world.bash(bash_block("handoff.md", "## Step 2"), world.wt1, lead=True, **env)
    assert step2.returncode == 0, step2.stderr
    assert "src/lead.py" in handoff.read_text(encoding="utf-8")
    # Step 3 is the model's: fill the two sentinels.
    text = handoff.read_text(encoding="utf-8")
    text = text.replace("<!-- HANDOFF:NARRATIVE -->",
                        "Mid-way through the parser; next, run the tests in tests/test_parse.py.")
    text = text.replace("<!-- HANDOFF:DONOTREDO -->", "- None.")
    handoff.write_text(text, encoding="utf-8")
    step4 = world.bash(as_command(bash_block("handoff.md", "## Step 4"), "--auto", SID_LEAD),
                       world.wt1, lead=True, **env)
    assert step4.returncode == 0, step4.stderr
    assert "ARMED:" in step4.stdout
    assert "handoff_at" in world.meta(SID_LEAD)
    assert not (world.staging / "demo" / "handoff.md").exists()  # Sam's slot untouched


def test_handoff_step1_without_a_session_id_still_refuses_when_two_sessions_are_live(world):
    """The old ambiguity gate stays for the fallback: a Claude Code that does not substitute."""
    dir_ = world.tmp / "projects"
    sam = world.transcript("sam.jsonl")
    world.start(world.main, SID_SAM, transcript=sam)
    (dir_ / "other.jsonl").write_text("{}\n", encoding="utf-8")
    step1 = world.bash(as_command(bash_block("handoff.md", "## Step 1"), "", ""), world.main)
    got = kv(step1.stdout)
    assert got["SESSION_SOURCE"] == "pointer" and got["AMBIGUOUS"] == "1"


def test_memory_sync_step6_marks_this_session_only(world):
    world.start(world.main, SID_SAM)
    world.start(world.wt1, SID_LEAD, lead=True)
    sams = world.staging / "demo" / "handoff.md"
    sams.write_text("Sam's\n", encoding="utf-8")
    lead_slot = world.staging / "demo" / "leads" / "1"
    (lead_slot / "handoff.md").write_text("lead's\n", encoding="utf-8")
    block = as_command(bash_block("memory-sync.md", "### Step 6"), "--auto", SID_LEAD)
    out = world.bash(block, world.wt1, lead=True)
    assert out.returncode == 0, out.stderr
    assert world.meta(SID_LEAD)["synced"] == "true"
    assert "synced" not in world.meta(SID_SAM)
    assert not (lead_slot / "handoff.md").exists()
    assert sams.is_file()


def test_memory_sync_step0_prints_the_mode(world):
    block = as_command(bash_block("memory-sync.md", "### Step 0"), "--auto", SID_SAM)
    world.start(world.main, SID_SAM)
    got = kv(world.bash(block, world.main).stdout)
    assert got["AUTO"] == "1" and got["MODE"] == "standard" and got["SESSION_ID"] == SID_SAM


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
