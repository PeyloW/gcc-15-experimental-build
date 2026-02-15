---
user-invocable: true
description: Read notes and source code, then propose a plan for updating all project documentation.
---

# Update Documentation

Read all input sources, then propose a comprehensive documentation update plan for user approval before making changes.

## Input Sources

Read all of the following before proposing changes:

1. **Notes** — raw text, source code, and markdown files in `./notes/` (if the directory exists)
2. **Source code changes** — `git diff` for uncommitted changes, `git diff HEAD~1` for recent commit, and `git diff mint/gcc-15...HEAD` for all branch changes in `gcc/config/m68k/`
3. **Scripts and docs in `./`** — check for manual user edits to `*.sh` and `*.md` files (compare against previous commit)
4. **Auto-memory** — review Claude Code memory files for relevant context, past bugs, gotchas, and decisions that should be reflected in documentation
5. **Existing documentation** — all `.md` files listed below

## Documentation Files

| File | Purpose |
|------|---------|
| `M68K_OPTIMIZATIONS.md` | Detailed descriptions of all m68k-specific optimizations — the authoritative reference |
| `PR_COMMENT.md` | Succinct PR description derived from M68K_OPTIMIZATIONS.md — suitable for a Pull Request |
| `GCC_PASSES.md` | Complete GCC 15 pass list with m68k additions, in execution order |
| `GCC_ARCHITECTURE.md` | Conceptual guide to GCC's transformation pipeline |
| `GCC_DEBUG.md` | Practical debugging guide (pass dumps, ICE diagnosis, pitfalls) |
| `GCC_GLOSSARY.md` | Glossary of GCC internal terms |
| `README.md` | Project overview, setup instructions, workflow, script/doc index |
| `CLAUDE.md` | Claude Code project instructions (build commands, key files, workflow) |

## Plan Requirements

The proposed plan must:

1. **List every file** that needs changes, with a summary of what changes and why
2. **Flag inaccuracies** — anything that contradicts the source code or other documentation
3. **Flag redundancies** — only `PR_COMMENT.md` is allowed to duplicate more than a single sentence from other documents. All other files must cross-reference instead of repeating
4. **Check internal consistency** — pass names, pass numbers, section numbers, file paths, flag names, and disable options must match across all documents
5. **Update cross-document links** — ensure all `[text](file.md)` references are correct and that the README doc/script tables are complete
6. **Keep PR_COMMENT.md under 8k** — it is the succinct version of M68K_OPTIMIZATIONS.md, not a copy

## Execution

After the user approves the plan:

1. Update each file in the plan
2. Verify `PR_COMMENT.md` is under 8k bytes
3. Verify no stale cross-references remain (grep for broken `](` links)
4. Present a summary of all changes made
