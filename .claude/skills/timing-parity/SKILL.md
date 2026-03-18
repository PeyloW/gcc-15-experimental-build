---
description: Ensure 020+ builds are on par or better than baseline. Investigates assembly differences, inspects intermediate data and cost calculations, then presents a plan for user approval.
user-invocable: true
---

# Timing Parity: 020+ vs Baseline

Ensure that 68020, 68030, 68040, 68060, and ColdFire builds produce code that is at least as good as the baseline (stock GCC 15 / system compiler). The 68000 target is the reference — if it has zero regressions, 020+ targets should too.

## Invocation

The user may provide a regression line from `tmp/test_cases/regressed.log` as arguments, e.g.:

```
/timing-parity O2 -m68030    test_array_indexing_byte    25    27    +2
```

This means: build flags `-O2 -m68030`, function `test_array_indexing_byte()` in `test_cases.cpp`, baseline (old compiler) reports 25 cycles, new compiler reports 27 cycles, regression of +2 cycles. When a specific regression line is provided, skip Phase 1 and go directly to Phase 2 for that function. The variant suffix maps to assembly files as follows:

| Flags | Suffix | Old file | New file |
|-------|--------|----------|----------|
| `-O2` | `O2` | `O2_old.s` | `O2_new.s` |
| `-O2 -mshort` | `O2_short` | `O2_short_old.s` | `O2_short_new.s` |
| `-Os` | `Os` | `Os_old.s` | `Os_new.s` |
| `-Os -mshort` | `Os_short` | `Os_short_old.s` | `Os_short_new.s` |
| `-O2 -m68030` | `O2_68030` | `O2_68030_old.s` | `O2_68030_new.s` |
| `-Os -m68030` | `Os_68030` | `Os_68030_old.s` | `Os_68030_new.s` |
| `-O2 -m68040` | `O2_68040` | `O2_68040_old.s` | `O2_68040_new.s` |
| `-Os -m68040` | `Os_68040` | `Os_68040_old.s` | `Os_68040_new.s` |
| `-O2 -m68060` | `O2_68060` | `O2_68060_old.s` | `O2_68060_new.s` |
| `-Os -m68060` | `Os_68060` | `Os_68060_old.s` | `Os_68060_new.s` |
| `-O2 -mcpu=5475` | `O2_cf` | `O2_cf_old.s` | `O2_cf_new.s` |
| `-Os -mcpu=5475` | `Os_cf` | `Os_cf_old.s` | `Os_cf_new.s` |

All files are in `tmp/test_cases/`.

## Constraints

- **Cost tables are never changed** unless they contain errors compared to the hardware documentation in `./notes/`. The cost tables reflect real hardware timings and are considered correct.
- **Do not start by binary-searching custom m68k options.** That approach masks root causes. Start with assembly analysis.

## Tools

The `clccnt` command-line tool counts clock cycles for m68k assembly. It breaks generated code into basic blocks and analyzes all possible execution paths, reporting min-max cycles per function. This is the same tool used by `./build-test_cases.sh` to compute cycle counts.

Use `clccnt` to analyze individual functions:

```bash
# Per-function cycle breakdown
clccnt -c 030 tmp/test_cases/O2_68030_new.s | grep test_function_name

# Verbose: per-instruction detail with basic block structure
clccnt -v -c 030 tmp/test_cases/O2_68030_new.s

# Single instruction timing check
clccnt -c 030 -i "move.l (a0)+,d0"
```

CPU flags: `-c 000` (68000), `-c 020` (68020), `-c 030` (68030), `-c 040` (68040), `-c 060` (68060/ColdFire).

**clccnt bugs**: In rare cases, `clccnt` itself may have timing bugs for specific instructions. If you suspect one, verify against hardware documentation in `./notes/`. A clccnt bug is only relevant to a "regression" if it costs old and new code differently (e.g., an instruction only present in the new code is undercosted). If both old and new are equally affected (same instruction miscosted in both), it is not a regression cause — but still point it out so it can be corrected upstream.

## Procedure

### Phase 1: Identify Regressions

Run the test suite and collect per-function regression data:

```bash
./build-test_cases.sh
```

Parse `tmp/test_cases/regressed.log` to get a list of regressed functions, grouped by variant. Focus on 020+ variants that regress while the 68000 variant does not.

### Phase 2: Investigate Assembly (per regressed function)

For each regressed function, compare old vs new assembly. Use `clccnt -v` to get per-instruction cycle breakdowns for both versions — this saves manual cycle counting:

```bash
# Per-instruction detail for old and new
clccnt -v -c 030 tmp/test_cases/O2_68030_old.s 2>/dev/null | sed -n '/^test_func_name/,/^$/p'
clccnt -v -c 030 tmp/test_cases/O2_68030_new.s 2>/dev/null | sed -n '/^test_func_name/,/^$/p'

# Or diff the full assembly
diff tmp/test_cases/O2_68030_old.s tmp/test_cases/O2_68030_new.s
```

Focus the diff on the specific function. Identify:

1. **What changed** — extra instructions, different register allocation, missed autoincrement, different addressing modes, different loop structure
2. **Whether the 68000 variant has the same code** — if the 68000 variant is fine, the difference is CPU-specific

### Phase 3: Inspect Intermediate Data

Once you know what changed in the assembly, trace backwards through GCC's pipeline to find the cause. Use dump flags to compare passes:

```bash
# Compile with pass dumps for both old and new
m68k-atari-mintelf-gcc -O2 -m68030 -mfastcall -fno-inline -S -fdump-rtl-all test_cases.cpp -o /tmp/old.s -dumpdir /tmp/old_
./build-host/gcc/xgcc -B./build-host/gcc -O2 -m68030 -mfastcall -fno-inline -S -fdump-rtl-all test_cases.cpp -o /tmp/new.s -dumpdir /tmp/new_

# Compare specific passes (e.g., combine, ira, reload)
diff /tmp/old_*.combine /tmp/new_*.combine
diff /tmp/old_*.ira /tmp/new_*.ira
```

Common root causes for 020+ regressions:

- **Cost model differences**: A cost function returns different values for 020+ vs 68000, causing combine/late_combine/IVOPTS to make different decisions. Check `m68k_rtx_costs_impl` and `m68k_insn_cost_impl` in `gcc/config/m68k/m68k_costs.cc`.
- **Addressing mode differences**: 020+ supports full 32-bit displacements and scaled index modes. IVOPTS or combine may choose different IV structures.
- **Instruction pattern differences**: Some `.md` patterns are conditional on `TARGET_68020_ONLY` or `!TARGET_COLDFIRE`. Missing or miscosted patterns cause fallback to worse code.
- **Register pressure**: 020+ instructions may have different register constraints, causing IRA to spill differently.

### Phase 4: Trace Cost Calculations

When the root cause involves cost decisions, trace the exact cost path:

```bash
# Compile with cost debugging (if available)
./build-host/gcc/xgcc -B./build-host/gcc -O2 -m68030 -mfastcall -fno-inline -S \
    -fdump-rtl-combine-details test_cases.cpp -o /tmp/new.s -dumpdir /tmp/new_
```

Look at combine dump details to see which transformations were accepted/rejected and their costs. Compare with the 68000 variant to understand why decisions diverge.

For IVOPTS differences:

```bash
./build-host/gcc/xgcc -B./build-host/gcc -O2 -m68030 -mfastcall -fno-inline -S \
    -fdump-tree-ivopts-details test_cases.cpp -o /tmp/new.s -dumpdir /tmp/new_
```

### Phase 5: Classify and Plan

For each regression, classify the root cause:

| Category | Fix Location | Example |
|----------|-------------|---------|
| Cost table error vs hardware docs | `m68k_costs.cc` cost tables | Table says 12 cycles, docs say 8 |
| Cost function logic error | `m68k_costs.cc` hook functions | Missing case for 020+ addressing mode |
| Missing/miscosted `.md` pattern | `m68k.md` | Pattern missing for 020+ instruction variant |
| Pass interaction | m68k pass files | Custom pass creates pattern that combine undoes on 020+ |
| GCC core limitation | Cannot fix locally | IVOPTS makes globally suboptimal choice |

### Phase 6: Present Plan

Present findings to the user as a plan with:

1. **Summary table**: Each regressed function, variant, old/new cycles, root cause category
2. **Proposed fixes**: Grouped by root cause, with specific code changes
3. **Risk assessment**: Which fixes might affect 68000 results (must not regress)
4. **Verification steps**: How to confirm each fix works

**Wait for user approval before making any changes.**

## Important Notes

- Always compare against the baseline commit, not just the system compiler. The baseline is the branch state before recent changes (check git log for the right commit).
- A function that regresses on 020+ but not on 68000 usually indicates a cost model or pattern issue specific to 020+ features, not a general optimization bug.
- Some 020+ regressions may be acceptable if they reflect genuinely different optimal code for those CPUs. Flag these separately.
- Setup/teardown regression is acceptable when the loop body improves. When the loop body is neutral, setup+teardown MUST also be neutral.
