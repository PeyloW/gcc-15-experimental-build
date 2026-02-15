# Debugging the m68k GCC Backend

Practical guide for diagnosing regressions, miscompilations, and ICEs when working on the m68k backend. Assumes familiarity with C/C++ and m68k assembly.

## Contents

1. [Comparing Assembly Output](#1-comparing-assembly-output)
2. [Finding the Culprit Pass](#2-finding-the-culprit-pass)
3. [Inspecting Pass Output](#3-inspecting-pass-output)
4. [Debugging ICE Errors](#4-debugging-ice-errors)
5. [Common Pitfalls in Custom Passes](#5-common-pitfalls-in-custom-passes)

---

## 1. Comparing Assembly Output

### This branch vs stock GCC 15

`build-test_cases.sh` compiles `test_cases.cpp` with both the system compiler (`m68k-atari-mintelf-gcc` in `/opt/cross-mint`) and the built compiler (`build-host/gcc/xgcc`), then counts instructions:

```bash
./build-test_cases.sh
```

Output is a table showing instruction counts per optimization variant:

```
Variant                      Old      New     Diff   Diff%
-------                      ---      ---     ----   -----
O2                          1234     1100     -134   -10.9%
O2 -mshort                  1100      980     -120   -10.9%
O2 -m68030                  1180     1060     -120   -10.2%
Os                          1000      900     -100   -10.0%
Os -mshort                   900      810      -90   -10.0%
Os -m68030                   960      870      -90    -9.4%
```

Both compilers use `-mfastcall -fno-inline`. Assembly files go to `tmp/test_cases/`.

### Quick comparison with `debug-asm-diff.sh`

```bash
# Compare assembly for a file (default: -Os -mshort -mfastcall)
./debug-asm-diff.sh test.c

# Compare only a specific function
./debug-asm-diff.sh -f memcmp memcmp.c

# Custom flags
./debug-asm-diff.sh -O "-O2" -x "-mcpu=68030" test.c

# New compiler only (skip old)
./debug-asm-diff.sh -n test.c
```

Shows instruction counts and `diff -u` output. Temp files go to `./tmp/debug/`.

### Manual compilation for a single file

To compile a specific file manually:

```bash
# Stock GCC 15 (system compiler)
m68k-atari-mintelf-gcc -Os -mshort -mfastcall -fno-inline -S test.c -o test_old.s

# This branch
./build-host/gcc/xgcc -B./build-host/gcc -Os -mshort -mfastcall -fno-inline -S test.c -o test_new.s

# Compare
diff -u test_old.s test_new.s
```

### Comparing two source variants

Write two `.c` files with different implementations and compare their assembly:

```bash
./build-host/gcc/xgcc -B./build-host/gcc -Os -mshort -S variant_a.c -o a.s
./build-host/gcc/xgcc -B./build-host/gcc -Os -mshort -S variant_b.c -o b.s
diff -u a.s b.s
```

Use `-fno-inline` to prevent functions from disappearing. For individual functions, use `__attribute__((noinline))`:

```c
__attribute__((noinline))
int my_func(int x) { return x * 2; }
```

### Per-function diffing

Use `-f` to focus on a single function:

```bash
./debug-asm-diff.sh -f memcmp memcmp.c
```

Or extract manually from assembly output:

```bash
sed -n '/^_memcmp:/,/^\t\.size/p' test.s
```

### Example: libcmini memcmp

```bash
./debug-asm-diff.sh -f memcmp memcmp.c
```

Before (stock GCC, indexed addressing, 56 cycles/byte):

```asm
        moveq   #0,d2
.loop:  move.b  (a0,d2.l),d1
        addq.l  #1,d2
        move.b  -1(a1,d2.l),d3
        cmp.b   d1,d3
        beq.s   .loop
```

After (this branch, post-increment, 32 cycles/byte):

```asm
.loop:  move.b  (a0)+,d0
        move.b  (a1)+,d1
        cmp.b   d0,d1
        beq.s   .check
```

---

## 2. Finding the Culprit Pass

When a regression or miscompilation appears, the goal is to isolate which pass is responsible.

### m68k-specific passes

The fastest test: each custom pass has a `-mno-*` flag. Disable one at a time to see if the problem disappears.

| Flag | Pass | Phase |
|------|------|-------|
| `-mno-m68k-autoinc` | Autoincrement (GIMPLE split + RTL convert) | 5.95a, 9.13a, 9.14b |
| `-mno-m68k-doloop` | DBRA loop optimization | 7.21 |
| `-mno-m68k-narrow-index-mult` | Narrow 32-bit multiply to 16-bit | 5.26a |
| `-mno-m68k-reorder-mem` | Memory access reordering | 5.123a |
| `-mno-m68k-elim-andi` | ANDI elimination / zero-extend hoisting | 9.19b |
| `-mno-m68k-highword-opt` | Word packing optimization | 9.19a |
| `-mno-m68k-ira-promote` | IRA register class promotion | 8.1 |
| `-mno-m68k-insn-cost` | Instruction cost hook (destination cost) | All costing |
| `-mno-m68k-btst-extract` | Single-bit btst+sne extraction | 9.14 |
| `-mno-m68k-avail-copy-elim` | Available copy elimination | 7.29a |
| `-fno-ivopts-autoinc-step` | IV step discount for auto-increment | 5.95 |

Example:

```bash
# Does the bug disappear without the autoinc pass?
./build-host/gcc/xgcc -B./build-host/gcc -Os -mshort -mno-m68k-autoinc -S test.c -o test.s
```

### GCC generic passes

Disable individual stock passes with `-fdisable-rtl-<pass>` or `-fdisable-tree-<pass>`:

```bash
# Disable the combine pass
./build-host/gcc/xgcc -B./build-host/gcc -Os -fdisable-rtl-combine -S test.c -o test.s

# Disable peephole2
./build-host/gcc/xgcc -B./build-host/gcc -Os -fdisable-rtl-peephole2 -S test.c -o test.s

# Disable late_combine
./build-host/gcc/xgcc -B./build-host/gcc -Os -fdisable-rtl-late_combine -S test.c -o test.s

# Disable IVOPTS (GIMPLE pass)
./build-host/gcc/xgcc -B./build-host/gcc -Os -fdisable-tree-ivopts -S test.c -o test.s
```

### Automated bisection with `debug-bisect-passes.sh`

```bash
# Test all m68k passes at once
./debug-bisect-passes.sh test.c

# Focus on a specific function
./debug-bisect-passes.sh -f my_func test.c

# Find which pass causes an ICE
./debug-bisect-passes.sh -ice test.c
```

Prints a table showing instruction count changes when each pass is disabled (or ICE status with `-ice`):

```
Pass                                Insns   Diff  Changed?
---                                 -----   ----  --------
baseline (all enabled)                 42
all m68k disabled                      58    +16   YES
-mno-m68k-autoinc                      50     +8   YES
-mno-m68k-doloop                       42      0   no
...
```

### Binary search strategy

1. **Disable all m68k passes first** — run `debug-bisect-passes.sh` to see which passes matter. If the "all m68k disabled" row shows a change, the table tells you which specific pass is responsible.
2. **If still present**, bisect generic passes by phase:
   - Disable GIMPLE passes: `-fdisable-tree-<pass>` for passes in Phases 2 and 5
   - Disable pre-RA RTL passes: `-fdisable-rtl-<pass>` for Phase 7
   - Disable post-RA RTL passes: `-fdisable-rtl-<pass>` for Phase 9
3. **Narrow within a phase** by disabling individual passes.

### Example: cost model regression

The non-RMW compound cost bug was found this way:

1. Noticed `late_combine` folding IV chains into base+offset form
2. Disabled custom passes — problem persisted
3. Disabled `late_combine` (`-fdisable-rtl-late_combine`) — improvement reverted
4. But `late_combine` was just acting on bad cost information — the real fix was in `TARGET_INSN_COST`: detecting non-RMW compound-to-memory and using additive cost (copy+op+store) instead of `max(src, dst)`

---

## 3. Inspecting Pass Output

### Getting RTL/GIMPLE dumps

```bash
# Dump everything (produces many files)
./build-host/gcc/xgcc -B./build-host/gcc -Os -fdump-rtl-all -S test.c

# Dump a specific RTL pass
./build-host/gcc/xgcc -B./build-host/gcc -Os -fdump-rtl-combine -S test.c

# Dump a GIMPLE pass
./build-host/gcc/xgcc -B./build-host/gcc -Os -fdump-tree-ivopts -S test.c

# Dump a custom m68k pass
./build-host/gcc/xgcc -B./build-host/gcc -Os -fdump-rtl-m68k-autoinc -S test.c
```

Dump files are named `<source>.NNN<r|t>.<passname>`, e.g.:

- `test.c.287r.combine` — RTL combine pass (pass #287)
- `test.c.123t.ivopts` — GIMPLE ivopts pass (pass #123)
- `test.c.302r.m68k-autoinc` — custom RTL pass

### Reading RTL notation

RTL represents instructions as nested S-expressions. Key patterns for m68k:

| RTL | m68k instruction |
|-----|------------------|
| `(set (reg:SI 0 %d0) (mem:SI (reg:SI 8 %a0)))` | `move.l (%a0),%d0` |
| `(set (reg:SI 0 %d0) (mem:SI (post_inc:SI (reg:SI 8 %a0))))` | `move.l (%a0)+,%d0` |
| `(set (mem:HI (reg:SI 8 %a0)) (const_int 0))` | `clr.w (%a0)` |
| `(set (reg:SI 0 %d0) (plus:SI (reg:SI 0 %d0) (const_int 4)))` | `addq.l #4,%d0` |
| `(set (reg:SI 0 %d0) (mem:SI (plus:SI (reg:SI 8 %a0) (reg:SI 0 %d0))))` | `move.l (%a0,%d0.l),%d0` |

**Key RTL elements:**

- `reg` — register. `(reg:SI 0 %d0)` = 32-bit register d0
- `mem` — memory reference. `(mem:HI ...)` = 16-bit memory access
- `set` — assignment. `(set dst src)` = `move src,dst`
- `plus` — addition (used in addressing and arithmetic)
- `post_inc` — post-increment addressing
- `const_int` — integer constant

**Mode suffixes:**

- `:QI` = byte (8-bit)
- `:HI` = word (16-bit)
- `:SI` = long (32-bit)

### Quick dumps with `debug-dump-pass.sh`

```bash
# Dump a single pass
./debug-dump-pass.sh test.c combine

# Diff two passes (address noise auto-filtered)
./debug-dump-pass.sh test.c cse2 combine

# Show only one function
./debug-dump-pass.sh -f my_func test.c m68k-autoinc
```

Pass type (RTL vs GIMPLE) is auto-detected. Dump files are copied to `./tmp/debug/`.

### Diffing two pass dumps manually

Compare a pass's input and output to see what it changed:

```bash
./build-host/gcc/xgcc -B./build-host/gcc -Os -fdump-rtl-all -S test.c

ls -1 test.c.*r.* | grep -n combine

diff -u test.c.286r.cse2 test.c.287r.combine \
  | sed 's/0x[0-9a-f]*/0xADDR/g'
```

### Example: autoinc pass conversion

Before `m68k-autoinc` (from `m68k-reorder-cc` dump):

```
(insn 10 (set (reg:QI 0 %d0)
              (mem:QI (reg:SI 8 %a0))))
(insn 11 (set (reg:SI 8 %a0)
              (plus:SI (reg:SI 8 %a0) (const_int 1))))
```

After `m68k-autoinc`:

```
(insn 10 (set (reg:QI 0 %d0)
              (mem:QI (post_inc:SI (reg:SI 8 %a0)))))
```

The separate load + increment merged into a single post-increment load.

---

## 4. Debugging ICE Errors

An Internal Compiler Error (ICE) is a crash inside the compiler. GCC prints a backtrace and the function being compiled.

### Reading the backtrace

A typical ICE looks like:

```
test.c: In function 'my_func':
test.c:42:1: internal compiler error: in verify_gimple_in_cfg, at tree-cfg.cc:5432
0x12345678 verify_gimple_in_cfg(function*)
    ../../gcc/tree-cfg.cc:5432
0x12345679 execute_function_todo
    ../../gcc/passes.cc:2091
...
```

Key information:

1. **Function name** — `my_func` — isolate this function for a minimal test case
2. **Assertion location** — `tree-cfg.cc:5432` — tells you which verification failed
3. **Call stack** — look for the pass name (`execute_function_todo` means it crashed in a verification after a pass)

### Reducing the test case

1. Use `-ffunction-sections` to compile only the crashing function:

   ```bash
   ./build-host/gcc/xgcc -B./build-host/gcc -Os -ffunction-sections -S big_file.c
   ```

2. Extract the crashing function into a minimal `.c` file
3. Remove unrelated code until the ICE disappears, then add the last removal back

### `-fchecking=2`: catch problems early

```bash
./build-host/gcc/xgcc -B./build-host/gcc -Os -fchecking=2 -S test.c
```

This enables extra verification after each pass — catches CFG corruption, DF inconsistency, and type mismatches at the pass that causes them rather than a later pass that trips over the damage.

### Common ICE causes (real examples from this branch)

#### Type mismatch (vfprintf bug)

**Symptom:** ICE in `verify_gimple_in_cfg` after `m68k_pass_narrow_index_mult`.

**Cause:** When `input_prec == 16` and the input is `unsigned short` but the multiply target type is `signed short`, creating an SSA name with mismatched types.

**Fix:** Check with `useless_type_conversion_p()` before creating SSA names. When types differ, insert a conversion.

#### CFG corruption (ANDI hoisting)

**Symptom:** ICE in CFG verification — instructions inserted outside basic block boundaries.

**Cause:** Walking backward with `PREV_INSN()` past `NOTE_INSN_BASIC_BLOCK`, then inserting instructions in the gap between basic blocks.

**Fix:** Use `emit_insn_before()` / `emit_insn_after()` instead of manual `PREV_INSN` walks.

#### Use-after-free / stale DF (regex.c sched2 crash)

**Symptom:** Crash in `sched2`'s `df_note_compute`. On macOS, the pointer values contain `0xa5a5a5a5` (freed-memory pattern).

**Cause:** `try_convert_to_postinc()` in the autoinc pass modified RTL instructions without calling `df_insn_rescan()`. The dataflow framework retained stale references to deleted/modified insns.

**Fix:** Call `df_insn_rescan(insn)` after every RTL modification. Use `delete_insn()` instead of `SET_INSN_DELETED()` — the latter doesn't notify DF.

#### Read-modify-write breakage (memfrob XOR bug)

**Symptom:** ICE in `try_normalize_increment_position` — assertion failure on XOR read-modify-write patterns.

**Cause:** The normalize pass tried to reorder an XOR instruction that both reads and writes the same memory location, breaking the RMW semantics.

**Fix:** Check `reg_mentioned_p` (is the address register used in the source?) and `get_negative_offset == 0` before attempting normalization.

---

## 5. Common Pitfalls in Custom Passes

Collected from real bugs in this branch. Each with the rule, why it matters, and what happens if violated.

### DF notification is mandatory

**Rule:** Call `df_insn_rescan(insn)` after modifying any RTL instruction when dataflow analysis is active. Use `delete_insn()`, not `SET_INSN_DELETED()`.

**Why:** The DF framework maintains reference chains (use-def, def-use) for every instruction. Modifying an insn without rescanning leaves stale references. `TODO_df_finish` alone does NOT clean these up.

**Violation symptom:** Use-after-free crash in a later pass (typically `sched2`). On macOS, look for `0xa5a5a5a5` pointer values in the backtrace.

### Pass return values

**Rule:** RTL and GIMPLE `execute()` methods must return a bitmask of `TODO_*` flags, not a change count.

**Why:** GCC interprets the return value as TODO flags. Returning a nonzero count (e.g., number of transformations) gets interpreted as `TODO_df_finish | TODO_verify_flow | ...` — triggering unexpected cleanup or verification.

**Violation symptom:** Random verification failures or missing dataflow after your pass, depending on which bits happen to be set.

### CFG boundaries

**Rule:** Never walk backward past `NOTE_INSN_BASIC_BLOCK` with `PREV_INSN()`. Use GCC's `emit_insn_before()` and `emit_insn_after()` APIs.

**Why:** The gap between basic blocks is not part of any BB. Instructions placed there are invisible to the CFG and will be dropped or cause verification failures.

**Violation symptom:** ICE in CFG verification, or silently dropped instructions.

### Peephole2 stamp files

**Rule:** After modifying `define_peephole2` patterns in `m68k.md`, delete stamp files in the build directory:

```bash
rm -f build-host/gcc/s-peep build-host/gcc/s-tmp-recog build-host/gcc/s-tmp-emit
```

**Why:** Generated peephole2 code goes into `insn-recog-*.cc`, not `insn-peep.cc`. The build system tracks regeneration via stamp files, and sometimes doesn't detect `.md` changes.

**Violation symptom:** Your new peephole2 pattern has no effect — the old generated code is still being used.

### `peep2_reg_dead_p` semantics

**Rule:** `peep2_reg_dead_p(N, reg)` checks `live_before[N]`, NOT "dead after insn N". For a 3-insn peephole (positions 0, 1, 2), use `peep2_reg_dead_p(3, reg)` to check if `reg` is dead after the last matched insn.

**Why:** The argument indexes into the `live_before` array. Position 3 is the state *before* the next unmatched insn, which is equivalent to "after position 2".

**Violation symptom:** Peephole fires incorrectly, clobbering a live register.

### Cross-BB SSA (GIMPLE passes with sjlj exceptions)

**Rule:** GIMPLE passes that chain SSA names across basic blocks must account for extra EH edges created by sjlj exceptions.

**Why:** With sjlj (setjmp/longjmp) exceptions, every call site gets an extra edge to an EH landing pad. This creates new basic blocks that break dominance assumptions — an SSA name defined in one BB may not dominate its use in another BB if there's an intervening EH edge.

**Violation symptom:** ICE in SSA verification (`dominance frontier`), but only with `-mcpu=5475` (ColdFire) and sjlj exceptions. Classic m68k with DWARF exceptions is unaffected.

**Testing:** Build with sjlj exceptions to catch these bugs:

```bash
./build-gcc.sh -sjlj build
```

