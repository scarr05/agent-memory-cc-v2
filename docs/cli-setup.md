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

Git Bash does not resolve `.com` extensions the way CMD/PowerShell do, so `obsidian` won't find `Obsidian.com` even when its directory is on PATH. Two fixes — use both for best coverage:

**1. Symlink (makes `obsidian` work in all bash sessions):**

```bash
ln -s "/c/Program Files/Obsidian/Obsidian.com" ~/.local/bin/obsidian
```

> **Note:** On NTFS without developer mode / admin elevation, `ln -s` creates a file copy rather than a true symlink. The copy won't update when Obsidian does — re-run the command after Obsidian updates, or rely on the env var below.

**2. `OBSIDIAN_CLI_PATH` env var (reliable for hooks):**

Add to `~/.claude/settings.json` under `"env"`:

```json
{
  "env": {
    "OBSIDIAN_CLI_PATH": "/c/Program Files/Obsidian/Obsidian.com"
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

If the bare `obsidian` command does not work in your shell, set the full path:

```bash
export OBSIDIAN_CLI_PATH="/c/Program Files/Obsidian/Obsidian.com"
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
