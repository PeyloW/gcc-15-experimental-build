---
user-invocable: false
description: Loaded when adding or modifying define_peephole2 or define_peephole patterns in m68k.md.
---

# Peephole Pattern Writing

## peep2_reg_dead_p Semantics

`peep2_reg_dead_p(N, reg)` checks `live_before[N]`, NOT "dead after insn N".

For a 3-insn peephole matching positions 0, 1, 2:

- `peep2_reg_dead_p(2, reg)` — checks if reg is dead before insn 2 (i.e. dead after insn 1)
- `peep2_reg_dead_p(3, reg)` — checks if reg is dead after the last matched insn (what you usually want)

## Stamp Files

After adding or modifying `define_peephole2` patterns, delete these stamp files to force regeneration:

```bash
rm -f gcc/s-peep gcc/s-tmp-recog gcc/s-tmp-emit
```

## Generated Code Location

- `define_peephole2` code is generated into `insn-recog-*.cc` (NOT `insn-peep.cc`)
- `define_peephole` (peephole1) code goes into `insn-output.cc`
- Stamp file for recog: `s-tmp-recog`

## Peephole1 vs Peephole2

| Feature | `define_peephole` (peephole1) | `define_peephole2` |
|---------|-------------------------------|-------------------|
| When it runs | Inside `final_scan_insn()` | Pass 9.14 (post-RA) |
| Output | Raw assembly text | Replacement RTL |
| Visibility | Later passes cannot see result | Result goes through `recog()` |
| Match window | 2+ adjacent insns | 2-5 adjacent insns |
| Use case | Legacy; for patterns that only make sense at assembly level | Preferred for all new patterns |

## Writing Tips

- Always check that scratch registers are dead after the peephole with `peep2_reg_dead_p(N+1, reg)` where N is the last matched position
- Use `peep2_find_free_register()` when you need a temporary register not used in the matched sequence
- Peephole2 patterns are tried in order — put more specific patterns before general ones
- The replacement sequence must be recognizable by `recog()` — each emitted insn must match a `define_insn`
- For m68k, mem-to-mem moves are valid on 68000 (but not ColdFire) — guard with `!TARGET_COLDFIRE`
