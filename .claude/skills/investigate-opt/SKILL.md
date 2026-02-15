---
description: Investigate how to implement an optimization idea in the m68k GCC backend. Example: /investigate-opt eliminate redundant tst after move
context: fork
agent: Explore
---

Investigate how to implement the following optimization in the m68k GCC backend: `$ARGUMENTS`

Follow these steps:

1. **Understand the optimization**: What code pattern is being targeted? What should the before/after look like in m68k assembly?

2. **Check if it already exists**: Search `/Users/peylow/m68k-atari-mint-gcc/build/M68K_OPTIMIZATIONS.md` and Appendix B (known missing optimizations) for overlap. Also search `gcc/config/m68k/m68k.md`, `gcc/config/m68k/m68k-rtl-passes.cc`, and `gcc/config/m68k/m68k-gimple-passes.cc` for related code.

3. **Identify the right IR level**: Is this a GIMPLE-level optimization (high-level, before register allocation) or RTL-level (low-level, after instruction selection)? Check `/Users/peylow/m68k-atari-mint-gcc/build/GCC_ARCHITECTURE.md` for guidance on which IR level is appropriate.

4. **Identify the right pass location**: Using `/Users/peylow/m68k-atari-mint-gcc/build/GCC_PASSES.md`, determine where in the pipeline this optimization should run. Consider:
   - What information is available at that point (value ranges, register allocation, liveness)?
   - Which existing passes might interfere or interact?
   - Should it run before or after register allocation?

5. **Find similar existing implementations**: Look at the m68k-specific passes in `gcc/config/m68k/m68k-rtl-passes.cc` and `gcc/config/m68k/m68k-gimple-passes.cc` for patterns to follow. Identify the most similar existing pass.

6. **Identify potential pitfalls**: Check for known gotchas:
   - DF notification requirements for RTL passes
   - SSA update requirements for GIMPLE passes
   - Cost model interactions (will combine/late_combine undo the optimization?)
   - ColdFire compatibility concerns

7. **Report findings**: Summarize with:
   - Recommended approach (new pass, peephole2 pattern, existing pass modification, or cost model change)
   - Where in the pipeline it should run (pass number)
   - Which existing pass to use as a template
   - Key risks and interactions to watch for
   - Suggested test cases for test_cases.cpp
