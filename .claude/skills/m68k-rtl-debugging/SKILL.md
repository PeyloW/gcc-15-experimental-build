---
user-invocable: false
description: Loaded when debugging ICEs, crashes, or RTL pass issues in the m68k backend.
---

# RTL Debugging Knowledge

## DF Notification Rules

When modifying RTL insns in a pass where DF is active, you **must** call `df_insn_rescan(insn)` after each modification. Failing to do so leaves stale DF refs that cause use-after-free in later passes (e.g. sched2's `df_note_compute`).

- `SET_INSN_DELETED` does NOT notify DF — use `delete_insn()` instead
- `TODO_df_finish` alone is NOT sufficient to clean up after modifications
- After modifying an insn's pattern (e.g. via `validate_change` + `apply_change_group`), call `df_insn_rescan(insn)`

## RTL Dump Flags

```
-fdump-rtl-<passname>     # Dump RTL before/after a pass
-fdump-rtl-m68k-autoinc   # Example: dump the m68k autoinc pass
-fdump-rtl-all            # Dump all RTL passes (huge output)
-fchecking=2              # Extra verification after each pass
```

Diff consecutive RTL dumps to see what a pass changed. Filter out pointer address differences (they change between runs).

## macOS Freed Memory Pattern

The pattern `0xa5a5a5a5...` in crash dumps indicates use-after-free. On macOS, freed memory is filled with `0xa5` bytes. If you see this in a register or memory value during debugging, look for stale pointers — typically caused by missing `df_insn_rescan` calls.

## Peephole2 Stamp Files

When adding or modifying `define_peephole2` patterns:

```bash
rm -f gcc/s-peep gcc/s-tmp-recog gcc/s-tmp-emit
```

Generated peephole2 code goes into `insn-recog-*.cc`, NOT `insn-peep.cc`. The stamp file is `s-tmp-recog`.

## peep2_reg_dead_p Semantics

`peep2_reg_dead_p(N, reg)` checks `live_before[N]`, NOT "dead after insn N". For a 3-insn peephole (positions 0, 1, 2), use `peep2_reg_dead_p(3, reg)` to check if reg is dead after the last matched insn.

## Common RTL Debugging Workflow

1. Add `-fdump-rtl-<passname>` to isolate the failing pass
2. Compare the RTL dump before and after the pass
3. If crash is in a later pass (e.g. sched2), the bug is likely in an earlier pass that didn't notify DF
4. Use `-fchecking=2` to catch issues earlier
5. ColdFire (`-mcpu=5475`) + sjlj exceptions can trigger bugs not seen with classic m68k — build with `./build-gcc.sh -sjlj build` and test with the sjlj compiler at `build-host-sjlj/gcc/xgcc`
