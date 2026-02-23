# Debugging the m68k GCC Backend

Practical guide for diagnosing regressions, miscompilations, and ICEs when working on the m68k backend. Assumes familiarity with C/C++ and m68k assembly.

## Contents

1. [Comparing Assembly Output](#1-comparing-assembly-output)
2. [Finding the Culprit Pass](#2-finding-the-culprit-pass)
3. [Inspecting Pass Output](#3-inspecting-pass-output)
4. [Debugging ICE Errors](#4-debugging-ice-errors)
5. [Common Pitfalls in Custom Passes](#5-common-pitfalls-in-custom-passes)
6. [Debugging Register Allocation (IRA)](#6-debugging-register-allocation-ira)
7. [Debugging LRA and Reload](#7-debugging-lra-and-reload)

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
| `-mno-m68k-ira-promote` | IRA register class promotion + register move cost | 8.1 |
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

#### Wrong width assumption (struct zero miscompilation)

**Symptom:** Silent miscompilation — `clr.w d5` instead of `clr.l d5` for a `point_s{0,0}` struct argument. High word of the register contained garbage from an earlier `move.l a6,d5`, producing a wrong struct value.

**Cause:** The `clrw_follows_andi_p` optimization in `m68k-elim-andi` saw `andi.l #$ffff` followed by `clr.w` and concluded "andi only preserves low bits that clr.w will clear, so andi is redundant." But `andi.l #$ffff` *also* clears the high word (bits 16-31) — it's `AND` with `0x0000FFFF`, which zeros everything above bit 15. Deleting it left the high word as garbage.

**Fix:** Removed the optimization. Added a peephole2 that safely combines `andi.l #$ffff` + `clr.w` into `moveq #0` instead.

**Lesson:** When reasoning about what bits an instruction "preserves", consider *all* bits it affects. `andi.l #$ffff` doesn't just preserve the low word — it actively clears the high word.

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

### cprop_hardreg undoes peephole2

**Rule:** Peephole2 patterns that emit separate insns (e.g. `move` + `branch`) can be undone by `cprop_hardreg` (9.18), which runs after `peephole2` (9.14). If the peephole copies a register and the copy is only used by the next insn, cprop propagates the original register back and deletes the dead copy.

**Why:** cprop_hardreg performs forward copy propagation on hard registers. A peephole2 that splits `(branch on %aN)` into `(set %dN %aN)` + `(branch on %dN)` creates a copy that cprop can see through — it replaces `%dN` with `%aN` in the branch and marks the `move` as dead.

**Solution:** Use a parallel-with-clobber in the peephole2 output, keeping the transformation as a single insn. The RTL still contains the original operand (e.g. `%aN`), so cprop has nothing to propagate. The actual substitution (e.g. `move.l %aN,%dN`) happens only at assembly output time in the `define_insn` template.

**Violation symptom:** Peephole2 fires (visible in `-fdump-rtl-peephole2`) but the final assembly is unchanged. The cprop dump (`-fdump-rtl-cprop_hardreg`) shows "replaced reg N with M" and "deferring deletion of insn".

### `recog_memoized` is not sufficient for constraint validation

**Rule:** After modifying an insn's operands post-RA (e.g. converting a MEM to POST_INC), validate with `extract_insn()` + `constrain_operands(1, get_enabled_alternatives(insn))`, not just `recog_memoized()`. Use strict mode (`1`) since all operands are hard registers after register allocation.

**Why:** `recog_memoized()` only checks operand predicates (e.g. `nonimmediate_operand`), which accept any MEM including POST_INC. It does not check constraint letters — `<` (pre-dec) and `>` (post-inc) are constraints, not predicates. A pattern like `extendsidi2` with constraints `"=d,o,o,<"` matches POST_INC via the predicate but rejects it at the constraint level.

**Caveat:** `constrain_operands(0, ...)` (non-strict) can incorrectly accept a POST_INC MEM for a register constraint like `d`. Only `constrain_operands(1, ...)` (strict) correctly rejects it.

**Violation symptom:** ICE in a later pass (typically `rnreg`) with "insn does not satisfy its constraints" in `extract_constrain_insn`.

### Cross-BB SSA (GIMPLE passes with sjlj exceptions)

**Rule:** GIMPLE passes that chain SSA names across basic blocks must account for extra EH edges created by sjlj exceptions.

**Why:** With sjlj (setjmp/longjmp) exceptions, every call site gets an extra edge to an EH landing pad. This creates new basic blocks that break dominance assumptions — an SSA name defined in one BB may not dominate its use in another BB if there's an intervening EH edge.

**Violation symptom:** ICE in SSA verification (`dominance frontier`), but only with `-mcpu=5475` (ColdFire) and sjlj exceptions. Classic m68k with DWARF exceptions is unaffected.

**Testing:** Build with sjlj exceptions to catch these bugs:

```bash
./build-gcc.sh -sjlj build
```

---

## 6. Debugging Register Allocation (IRA)

[IRA](GCC_GLOSSARY.md#ira) (Integrated Register Allocator, [Phase 8.1](GCC_PASSES.md#phase-8-register-allocation)) assigns pseudo-registers to physical registers via graph coloring. On m68k, the split register file (DATA_REGS `d0`–`d7`, ADDR_REGS `a0`–`a6`) makes IRA decisions particularly important — a pseudo in the wrong class forces a register-to-register copy on every use.

### Getting IRA dumps

```bash
# Basic dump
./build-host/gcc/xgcc -B./build-host/gcc -O2 -fdump-rtl-ira -S test.c

# With verbose coloring decisions (levels 0-5, higher = more detail)
./build-host/gcc/xgcc -B./build-host/gcc -O2 -fdump-rtl-ira -fira-verbose=5 -S test.c

# Verbose to stderr for real-time watching (add 10 to level)
./build-host/gcc/xgcc -B./build-host/gcc -O2 -fdump-rtl-ira -fira-verbose=15 -S test.c 2>&1 | less
```

The dump file is named `<source>.NNNr.ira` (e.g. `test.c.312r.ira`).

### m68k hard register numbers

Dumps show hard register numbers, not names. The mapping for m68k:

| Number | Register | Class |
|--------|----------|-------|
| 0–7 | `d0`–`d7` | DATA_REGS |
| 8–14 | `a0`–`a6` | ADDR_REGS |
| 15 | `sp` (`a7`) | ADDR_REGS |
| 16–23 | `fp0`–`fp7` | FP_REGS |

So `assign reg 8` means the pseudo was assigned to `a0`.

### What to look for in the IRA dump

#### Allocno cost table (`-fira-verbose=1`)

```
  a0(r78,b2) costs: DATA_REGS:1000,1000 ADDR_REGS:2000,2000 MEM:3000,3000
```

Format: `a<allocno>(r<pseudo>,b<bb>)` then `<class>:<cost>,<full_cost>` pairs. Lower cost = preferred. `MEM` = cost of spilling to stack. IRA picks the cheapest class — if DATA_REGS is cheapest, the pseudo will be colored from `d0`–`d7`.

#### Disposition table (`-fira-verbose=1`)

```
Disposition:
    0:r78 b2   0    1:r79 l0   8    2:r80 b3  mem    3:r81 b2   1
```

Format: `<allocno>:r<pseudo> b<bb>|l<loop> <hard_reg_or_mem>`. This is the final assignment. In this example: r78→d0, r79→a0, r80→spilled, r81→d1.

#### Available registers and conflicts (`-fira-verbose=3`)

```
      Allocno a0r78 of DATA_REGS(8) has 5 avail. regs [d0 d1 d2 d3 d4],
        node: [d0..d7] (confl regs = [d5 d6 d7])
```

Shows how many candidate registers remain after removing conflicts. If `avail. regs` is 0, the pseudo must spill.

#### Coloring stack push/pop (`-fira-verbose=3`)

```
      Pushing a0(r78,b2)(cost 1000)
      ...
      Popping a1(r79,l0)  -- assign reg 8
      Popping a0(r78,b2)  -- assign memory
```

IRA uses Chaitin-Briggs: push allocnos onto a stack (lowest priority first), then pop and assign. `assign memory` means the allocno couldn't be colored — it's spilled.

#### Per-register costs (`-fira-verbose=5`)

```
      a2(r80) costs: 0:2000 1:2000 2:1500 ... 8:500 9:500 ...
```

Shows the cost of assigning the allocno to each hard register individually. Useful for understanding why IRA chose one register over another.

### Cost summary

```
+++Costs: overall 1234, reg 800, mem 434, ld 200, st 100, move 134
```

After LRA/reload completes:

```
+++Overall after reload 1456
```

If the "after reload" cost is much higher than the "overall" cost, LRA/reload had to insert many spills.

### IRA tuning flags

| Flag | Default | Purpose |
|------|---------|---------|
| `-fira-algorithm=CB` | CB | Chaitin-Briggs graph coloring (default) |
| `-fira-algorithm=priority` | — | Priority-based coloring (alternative) |
| `-fira-region=one` | one | RA over whole function |
| `-fira-region=all` | — | RA per loop region |
| `-fira-share-spill-slots` | on | Share stack slots between non-overlapping spills |
| `-fira-merge-passthrough` | off (on for m68k) | Merge zero-ref pass-through allocnos with parent region (budget-limited) |

### Example: diagnosing a wrong register class

A pointer pseudo assigned to DATA_REGS forces `move.l dN,aM` copies before every memory access. To diagnose:

1. Find the pseudo number from the assembly (`%d3` used as a base → pseudo was assigned to d3)
2. Search the `*.ira` dump for `r<pseudo>` in the cost table
3. Check if ADDR_REGS cost is higher than DATA_REGS cost — if so, IRA made the optimal choice given its information, and the fix is in the cost model or the `m68k_ira_change_pseudo_allocno_class` hook
4. Check if the hook promoted the pseudo — search for the pseudo number in the hook's debug output (enabled with `-fdump-rtl-ira`)

See [M68K_OPTIMIZATIONS.md §9](M68K_OPTIMIZATIONS.md#9-ira-register-allocation-improvements) for the IRA promotion hook.

---

## 7. Debugging LRA and Reload

After IRA assigns physical registers, a second pass resolves remaining constraint violations. m68k defaults to [LRA](GCC_GLOSSARY.md#lra) (`-mlra`); the legacy reload pass is available via `-mno-lra`. Both write to the same dump file. Reload is scheduled for removal in GCC 16.

### Getting LRA / reload dumps

```bash
# LRA dump (default)
./build-host/gcc/xgcc -B./build-host/gcc -O2 -fdump-rtl-reload -fira-verbose=3 -S test.c

# Old reload dump
./build-host/gcc/xgcc -B./build-host/gcc -O2 -mno-lra -fdump-rtl-reload -fira-verbose=3 -S test.c

# Maximum LRA detail (verbose >= 7 dumps full insns at each step)
./build-host/gcc/xgcc -B./build-host/gcc -O2 -fdump-rtl-reload -fira-verbose=7 -S test.c
```

The dump file is named `<source>.NNNr.reload` (e.g. `test.c.313r.reload`). Both LRA and old reload write to this same file — the content differs depending on `-mlra` / `-mno-lra`.

### Comparing LRA vs reload output

```bash
# Side-by-side assembly comparison
./build-host/gcc/xgcc -B./build-host/gcc -O2 -S test.c -o test-lra.s
./build-host/gcc/xgcc -B./build-host/gcc -O2 -mno-lra -S test.c -o test-reload.s
diff -u test-lra.s test-reload.s
```

### LRA dump structure

LRA works in multiple rounds. The dump is organized into labeled iterations:

#### Constraint iterations

```
********** Local #1: **********

      Choosing alt 1 in insn 42: {*movsi_m68k} (sp_off=0)
         Considering alt=0 of insn 42: (0) =d (1) rmi  ...
         Considering alt=1 of insn 42: (0) =a (1) rmi  ...
      overall=5,losers=0,rld_nregs=0
```

LRA tries each alternative of each instruction and picks the best. `losers` = operands that don't match (need reloads). `rld_nregs` = reload registers needed. On m68k, this is where you see LRA choosing between data and address register alternatives.

#### Assignment iterations

```
********** Assignment #1: **********

	   Assign 2 to r99 (freq=1000)
	 Trying 0: spill 78(freq=500) assign 0(cost=200)
	 Assigning 3 to r100
	 Reload r102 assignment failure
```

Shows LRA assigning hard registers to reload pseudos. `assignment failure` means LRA couldn't find a register — it will retry or spill in a subsequent round.

#### Inheritance

```
********** Inheritance #1: **********

EBB 0 1 3 4
    Original reg change 78->103 (bb2):
    Split reuse change 103->78:
```

LRA copies values across basic block boundaries to avoid reloading from the stack at each use. The EBB lines show extended basic block membership.

#### Elimination

```
New elimination table:
    Using elimination 64 to 15 now      [virtual frame pointer -> stack pointer]
```

Frame pointer elimination: virtual registers (like the frame pointer, register 64) are replaced by `sp + offset`. On m68k, this is where indexed displacements can exceed the 8-bit limit on 68000/ColdFire — the LEA ICE fix ([M68K_OPTIMIZATIONS.md §16](M68K_OPTIMIZATIONS.md#16-lra-register-allocator)) handles this case.

### Old reload dump structure

When using `-mno-lra`, the `*.reload` dump contains different messages:

```
Reloads for insn # 42
  Reload 0: reload_in (SI) = (reg:SI 80)
    DATA_REGS, RELOAD_FOR_INPUT, ...
Using reg 3 for reload 0
Spilling for insn 55.
Register 80 now on stack.
```

`Using reg N for reload M` shows which hard register was selected for each reload. `now on stack` means a pseudo was spilled.

### What to search for in dumps

| Search term | Meaning |
|-------------|---------|
| `Disposition:` | IRA's final register assignments (in `*.ira`) |
| `assign memory` / `mem` | Pseudo spilled to stack |
| `assign reg N` | Pseudo assigned to hard register N |
| `memory is more profitable` | IRA chose memory because register cost exceeded memory cost |
| `avail. regs` | Candidate hard registers after conflict removal |
| `Choosing alt N` | LRA chose alternative N of an instruction pattern |
| `assignment failure` | LRA could not assign a register to a reload pseudo |
| `Spilling r` / `Spilling for insn` | A pseudo is being spilled (LRA / old reload) |
| `elimination` | Frame pointer / arg pointer elimination |
| `losers=` | Number of operands needing reloads in an instruction |

### LRA tuning params

| Param | Default | Purpose |
|-------|---------|---------|
| `--param=lra-max-considered-reload-pseudos=N` | 500 | Max reload pseudos considered during spilling |
| `--param=lra-inheritance-ebb-probability-cutoff=N` | 40 | Min fall-through probability for inheritance EBB |
| `-flra-remat` | on | CFG-sensitive rematerialization in LRA |

### Example: diagnosing a spill

A function has an unexpected `move.l %dN,-(sp)` / `move.l (sp)+,%dN` pair. To find why:

1. Compile with `-fdump-rtl-ira -fdump-rtl-reload -fira-verbose=3`
2. In the `*.ira` dump, search for the pseudo's allocno: `r<N>`. Check the cost table — is MEM cost close to the register cost? If so, IRA may have judged spilling acceptable.
3. Check the disposition table — was the pseudo assigned a register by IRA, or was it already marked `mem`?
4. If IRA assigned a register, check the `*.reload` dump for `Spilling` — LRA may have spilled it due to a constraint conflict that IRA didn't anticipate.
5. In LRA's constraint output, look for `losers=` on the relevant insn — a nonzero value means LRA needed a reload register at that point, which may have triggered the spill.

### Example: LRA vs reload regression

When switching from `-mno-lra` to `-mlra` causes a code quality regression:

1. Compare assembly: `diff test-lra.s test-reload.s`
2. Identify the changed function and the extra instructions (usually spills or register copies)
3. Dump both: `-fdump-rtl-reload -fira-verbose=3` with `-mlra` and `-mno-lra`
4. Compare the `*.reload` dumps — look for different alternative choices (`Choosing alt N`) or different spill decisions
5. Common causes on m68k:
   - LRA chose a different instruction alternative that requires a register copy (fix: reorder alternatives in `m68k.md`)
   - LRA's constraint iteration couldn't satisfy a `"p"` (address) constraint after frame pointer elimination (fix: use explicit register/const constraints — see the LEA ICE fix in [M68K_OPTIMIZATIONS.md §16](M68K_OPTIMIZATIONS.md#16-lra-register-allocator))
   - LRA's inheritance inserted cross-BB copies that reload didn't need (usually acceptable — LRA's overall result is still better)

