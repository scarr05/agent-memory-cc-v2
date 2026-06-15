# Obsidian CLI Setup

The agent memory v3 system uses the Obsidian CLI (1.12+) for token-efficient vault reads. This guide covers per-platform setup.

## Prerequisites

- Obsidian 1.12.4+ **installer** (not just an app update — the installer adds the CLI binary)
- Catalyst licence (early access, as of March 2026)

## Enable CLI

1. Open Obsidian
2. Go to **Settings → General**
3. Enable **Command line interface**
4. Follow the registration prompt
5. Restart your terminal

## Platform-Specific Setup

### Windows (PowerShell / CMD)

The 1.12+ installer places `Obsidian.com` (terminal redirector) alongside `Obsidian.exe` and registers it on PATH. After enabling CLI in settings and restarting your terminal:

```powershell
obsidian version
# Expected: 1.12.x (installer 1.12.x)
```

### Windows (Git Bash / WSL / Claude Code)

Git Bash does not resolve `.com` extensions the way CMD/PowerShell do, so `obsidian` won't find `Obsidian.com` even when its directory is on PATH. Two fixes — use both for best coverage.

**First, find the binary.** Its location depends on how Obsidian was installed, and the bash path depends on your shell's mount prefix:

- **Install location** — per-user (most common): `…\AppData\Local\Programs\Obsidian\Obsidian.com`; machine-wide: `C:\Program Files\Obsidian\Obsidian.com`
- **Mount prefix** — **WSL mounts C: at `/mnt/c`**, Git Bash at `/c`

Detect the real path (WSL — for Git Bash swap `/mnt/c` for `/c`):

```bash
OBS_BIN=$(find "/mnt/c/Users/$(whoami)/AppData/Local/Programs/Obsidian" "/mnt/c/Program Files/Obsidian" -iname Obsidian.com 2>/dev/null | head -1)
echo "$OBS_BIN"
```

> `$(whoami)` is your WSL username; if it differs from your Windows username, substitute the Windows one in the path.

**1. Symlink (makes `obsidian` work in all bash sessions):**

```bash
ln -sf "$OBS_BIN" ~/.local/bin/obsidian   # -f overwrites any stale/broken link
```

> **Note:** In WSL your home is on ext4, so this is a true symlink. In Git Bash on NTFS without developer mode / admin elevation, `ln -s` creates a file *copy* instead — it won't update when Obsidian does, so re-run after each Obsidian update, or rely on the env var below.

**2. `OBSIDIAN_CLI_PATH` env var (reliable for hooks):**

Add to `~/.claude/settings.json` under `"env"`, using the path from `$OBS_BIN` above (WSL example):

```json
{
  "env": {
    "OBSIDIAN_CLI_PATH": "/mnt/c/Users/<you>/AppData/Local/Programs/Obsidian/Obsidian.com"
  }
}
```

All hooks use `OBS="${OBSIDIAN_CLI_PATH:-obsidian}"` and will pick this up regardless of PATH state.

**Verify:**

```bash
obsidian version
# Expected: 1.12.x (installer 1.12.x)
```

### macOS

CLI is registered via Settings → General → CLI. Available in all terminals after restart.

```bash
obsidian version
```

If not found, check if the Obsidian app bundle includes the CLI binary and add its location to PATH.

### Linux

CLI is registered via Settings → General → CLI. If using AppImage, the CLI binary may need manual PATH setup:

```bash
# Find the CLI binary
find / -name "obsidian" -type f 2>/dev/null

# Add to PATH
export PATH="/path/to/obsidian/cli:$PATH"
```

## Fallback: Environment Variable

If the bare `obsidian` command does not work in your shell, set the full path (WSL example — Git Bash swaps `/mnt/c` for `/c`; the exact path depends on your install, see the detect snippet above):

```bash
export OBSIDIAN_CLI_PATH="/mnt/c/Users/<you>/AppData/Local/Programs/Obsidian/Obsidian.com"
```

All hooks and subagents use `${OBSIDIAN_CLI_PATH:-obsidian}` and will pick this up.

## Verify

```bash
# Check version
obsidian version

# Test search
obsidian search query="test" path="5 Agent Memory" format=json limit=1

# Test property read
obsidian property:read name="type" path="5 Agent Memory/project-index.md"
```

All three should return without error. If Obsidian is not running, the first command may take a few seconds to launch it.
