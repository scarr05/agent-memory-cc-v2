# Codex setup and review

The Codex adapter shares the existing Obsidian Markdown notes with Claude Code. It provides context loading, session sync, decisions and handoffs through a user-level skill and a small global `AGENTS.md` addition. It uses direct filesystem access, so no Obsidian process, API token or MCP server is required. Normal Codex filesystem approvals still apply to the vault.

## Install for all projects

On Windows, run the non-overwriting installer from the repository:

```powershell
./codex/Install-AgentMemory.ps1 -VaultPath 'C:/path/to/your/vault'
```

It verifies the existing memory folder, installs the skill, and backs up existing global instructions before merging the memory block. It refuses to overwrite an existing installation. The equivalent manual steps are:

1. Copy `codex/agent-memory/` to `~/.agents/skills/agent-memory/`.
2. Create `local-config.md` inside the installed skill with the absolute vault root and memory root (`<vault>/5 Agent Memory`). Keep this machine-specific file outside the repository.
3. Merge `codex/global-agents-memory.md` into `~/.codex/AGENTS.md`, preserving existing guidance. If `CODEX_HOME` is set, use that directory. An `AGENTS.override.md` takes precedence: merge the block into the active file instead.
4. Start a new Codex session to load global instructions. Ask: `$agent-memory load context for this project`.
5. Ask `Save a short memory checkpoint`, then check the reported vault path. Use `Sync this session` before leaving substantial work.

Use the same steps on another machine with its own local vault path. Recopy the skill when upgrading, retaining `local-config.md`. To uninstall, remove the installed skill and only the marked `agent-memory:codex` block from global instructions.

## Design notes

- The original `skills/agent-memory/SKILL.md` depends on Claude hook injection, `~/.claude` staging, named Haiku subagents and slash commands. Installing it unchanged would not implement that lifecycle in Codex. The adapter has independent instructions and does not register the Claude hook scripts.
- The adapter does not need an Obsidian MCP server. Direct file access provides a credential-free backend; sandbox access must still be approved.
- Project identity is read from the `AGENTS.md` marker (or a local `.claude/CLAUDE.md`). Falling back directly to the checkout folder name would split a project's history, so the adapter follows the Claude slug order and preserves existing identities.
- Treat session notes as primary context; the project index is a pointer. The adapter skips index updates when the table is damaged; repairing existing data is a separate task.
- Memory loading and saving are agent instructions, not deterministic hook enforcement. Abrupt termination may lose unsaved context. Explicit checkpoints remain useful.
- Shared files may be edited by Claude, Codex, Obsidian or sync software. Prefer unique session notes, fresh reads and narrow edits; this adapter provides no cross-process transaction lock.

## Official references

- [Codex skill discovery and invocation](https://developers.openai.com/codex/skills)
- [Global and project AGENTS.md discovery](https://developers.openai.com/codex/guides/agents-md)

## Validation

Validate the source skill using the installed skill-creator validator. Verify the installed copy matches it, the active global instructions contain exactly one managed block, and the configured vault is readable. A fresh Codex session is the final check for skill discovery and instruction loading.

On Windows, run the Python validator with `python -X utf8` so UTF-8 Markdown is decoded correctly.
