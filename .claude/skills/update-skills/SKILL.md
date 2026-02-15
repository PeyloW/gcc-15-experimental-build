---
user-invocable: false
description: Loaded after completing a task that uncovered new pitfalls, gotchas, debugging tips, or other knowledge that should be recorded in project skills for future sessions.
---

After completing a task, check if any new knowledge was gained that should be recorded in the project skills. This includes:

- New pitfalls or gotchas discovered during implementation
- Debugging techniques that were useful
- Interactions between passes that weren't previously documented
- Cost model edge cases
- Peephole pattern writing lessons
- Build system quirks
- Any "I wish I'd known this before starting" insights

## How to Update

1. Identify which existing skill file is most relevant:

   | Topic | Skill file |
   |-------|-----------|
   | RTL pass bugs, ICEs, crashes, DF issues | `.claude/skills/m68k-rtl-debugging/SKILL.md` |
   | RTX/address/instruction cost issues | `.claude/skills/m68k-cost-model/SKILL.md` |
   | `define_peephole2` pattern issues | `.claude/skills/m68k-peephole/SKILL.md` |
   | GIMPLE pass issues, SSA, alias oracle | `.claude/skills/m68k-gimple-debugging/SKILL.md` |
   | Documentation formatting | `.claude/skills/m68k-doc-style/SKILL.md` |

2. Add the new knowledge to the appropriate section of that skill file. Keep it concise — a few sentences with a concrete example is ideal.

3. If the knowledge doesn't fit any existing skill, consider whether it warrants a new skill or belongs in `MEMORY.md` instead.

4. Also update `MEMORY.md` if the lesson is broadly applicable across sessions (not just within a specific skill's domain).

## What NOT to Record

- Session-specific context (current task details, temporary state)
- Information already in CLAUDE.md
- Speculative conclusions from a single observation — wait until confirmed
- Verbose explanations — keep entries short and actionable
