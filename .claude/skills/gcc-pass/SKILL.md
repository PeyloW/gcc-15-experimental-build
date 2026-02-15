---
description: Look up a GCC optimization pass by name or number. Example: /gcc-pass combine, /gcc-pass 7.33
context: fork
agent: Explore
---

Look up the GCC pass matching `$ARGUMENTS` in `/Users/peylow/m68k-atari-mint-gcc/build/GCC_PASSES.md`.

Search for the pass by name or number. Return:

- Pass number and name
- IR level (GIMPLE, RTL, etc.)
- Purpose
- Related passes
- Example transformation
- If it's an m68k-specific pass, include the full description from the "m68k-Specific Passes" section

If the argument is ambiguous, list all matching passes.
