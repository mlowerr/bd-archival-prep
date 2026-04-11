# AGENTS.md

Guidance for agents working in this repository.

## Project purpose
This repo contains cross-platform (Unix + PowerShell) scripts that generate archival-prep reports for large media directories.

## High-impact workflow for efficient changes
1. Read `README.md` first for expected script behavior and output formats.
2. Make the smallest possible change that satisfies the task.
3. Preserve parity between Unix and Windows script variants when behavior is intended to match.
4. Prefer deterministic output ordering and stable formatting.
5. Avoid changing report file names, section headers, or CLI flags unless explicitly requested.

## Repository conventions
- Keep scripts focused and composable; avoid broad refactors when a targeted edit will do.
- Maintain existing naming patterns and directory structure under `scripts/unix` and `scripts/windows`.
- When adding options, update usage/help text and README documentation in the same task.
- Preserve default output location semantics (`.archival-prep` under target unless overridden).
- When adding shared helpers under platform-specific `lib/` directories, resolve helper paths relative to the invoking script so entry-point scripts remain runnable from any working directory.

## Validation expectations
After script changes, run checks relevant to the edited files (for example, shell syntax checks and/or a dry run with `--help`) before finishing.

## Completion checklist (required)
Before closing **every** task, agents must do all of the following:
1. Confirm the code/doc changes satisfy the user request.
2. Confirm documentation impacted by the change is updated (at minimum `README.md` when behavior changes).
3. **Determine whether this `AGENTS.md` file should be updated based on what was learned during the task.**
   - If any instruction here is outdated, unclear, or missing important recurring guidance, update this file in the same task.
   - If no update is needed, explicitly note that it was reviewed and remains accurate.

This requirement exists to keep agent guidance current and avoid misleading future agents.
