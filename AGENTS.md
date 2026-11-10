# Repository guidance

This repository packages an Obsidian-backed memory workflow. The original Claude integration lives in `hooks/`, `commands/`, `agents/`, and `skills/`. The Codex adapter lives in `codex/agent-memory/`; see `docs/codex-setup.md`.

<!-- memory:project-slug=memory-architecture -->

Preserve the shared vault schema and existing Claude integration when editing the Codex adapter. Use British English. Never commit machine-specific vault paths or private memory notes.

For Codex skill edits, run the installed skill-creator's `scripts/quick_validate.py` on `codex/agent-memory`. Hook changes additionally require the checks documented in `CLAUDE.md`, including execution on Windows Git Bash and macOS before merge.
