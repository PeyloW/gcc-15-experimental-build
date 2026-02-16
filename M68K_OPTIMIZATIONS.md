# m68k GCC 15 Optimizations

Since GCC 3, the m68k backend has received little attention while the rest of the compiler infrastructure has evolved significantly. The result is that GCC often generates surprisingly poor code for m68k: inefficient memory access patterns that ignore post-increment addressing, loops that barely ever use `dbra`, and wasteful instruction sequences that a human would never write.

The optimizations in this branch aim to address some of the most glaring missed opportunities.

My target machine is a 68000 with `-mshort` and `-mfastcall`, so that configuration has received the most testing and attention. Many of these optimizations also benefit 32-bit int mode and 68020+, but that is more by luck than deliberate effort—I have only verified that those configurations do not regress.

A PR-ready version of this document is available in [PR_COMMENT.md](PR_COMMENT.md).

## Index

**Optimizations**

1. [RTX and Address Cost Calculations](#1-rtx-and-address-cost-calculations)
2. [Induction Variable Optimization](#2-induction-variable-optimization)
3. [Autoincrement Optimization Pass](#3-autoincrement-optimization-pass)
4. [Memory Access Merge Peepholes](#4-memory-access-merge-peepholes)
5. [DBRA Loop Optimization](#5-dbra-loop-optimization)
6. [Multiplication Optimization](#6-multiplication-optimization)
7. [ANDI Hoisting](#7-andi-hoisting)
8. [Word Packing and Insert Patterns](#8-word-packing-and-insert-patterns)
9. [IRA Register Class Promotion](#9-ira-register-class-promotion)
10. [Improved Loop Unrolling](#10-improved-loop-unrolling)
11. [Memory Access Reordering](#11-memory-access-reordering)
12. [Single-Bit Extraction](#12-single-bit-extraction)
13. [Available Copy Elimination](#13-available-copy-elimination)
14. [Load Reordering for CC Tracking](#14-load-reordering-for-cc-tracking)
15. [Sibcall Optimization](#15-sibcall-optimization)

**Appendix**

- [A. libcmini Real-World Example](#appendix-a-libcmini-real-world-example)
- [B. Known Missing Optimizations](#appendix-b-known-missing-optimizations)

---

## 1. RTX and Address Cost Calculations

Rewritten cost model using lookup tables with actual cycle counts per CPU generation (68000, 68020-030, 68040+), inspired by Bebbo's gcc6 work. The stock GCC 15 m68k backend uses flat costs without distinguishing addressing modes, operand sizes, or CPU generations.

`TARGET_ADDRESS_COST` distinguishes per-mode address costs — `(a0)` (4 cycles) vs `8(a0)` (8 cycles) vs `(a0,d0.l)` (10 cycles). `TARGET_NEW_ADDRESS_PROFITABLE_P` prevents the scheduler from replacing post-increment with indexed addressing when it is not cheaper.

`TARGET_INSN_COST` costs whole instructions including the destination operand. GCC's default only costs the source, so memory stores appear cheap. Non-RMW compound operations to memory are costed additively (copy+op+store), preventing combine passes from folding IVs into base+offset form that needs three instructions. On 68020+, address sub-expressions inside MEM are costed once as addressing modes, avoiding double-counting.

**Hooks:** `TARGET_RTX_COSTS` (rewritten), `TARGET_ADDRESS_COST` (new), `TARGET_NEW_ADDRESS_PROFITABLE_P` (new), `TARGET_INSN_COST` (new)

**Code:** `gcc/config/m68k/m68k.cc` (`m68k_rtx_costs_impl()`, `m68k_insn_cost_impl()`, `m68k_address_cost_impl()`), `gcc/config/m68k/m68k_costs.cc`

### Implementation history

The cost model was developed in several stages:

1. **Initial port** (`9fa842d7054`): Direct port of Bebbo's amiga gcc6 cost tables to GCC 15, providing per-CPU-generation cycle counts for all addressing modes and instruction types.
2. **Store costing bug** (`98264372b75`): Discovered that only the source operand was being costed. `move.b 1(a0),d0` was undercounted to 8 cycles (should be 12), and `move.b d0,1(a0)` even worse at 4. Added `TARGET_INSN_COST` to cost the full `(set dst src)` pattern.
3. **Double-counting fix** (`98264372b75`): On 68020, nested RTX inside MEM were counted twice — once as standalone arithmetic and once as addressing mode. Fixed by recognizing address sub-expressions.
4. **Non-RMW detection** (`97c42dbf01a`): `(set (mem) (plus reg const))` where reg is not the memory base is NOT a single instruction — it requires copy+op+store (3 insns). Without additive costing, `combine` and `late_combine` fold IV chains into base+offset form.

### Examples

```c
int sum = a + b * 4;
```
```asm
; Before: generic costs lead to suboptimal choices
move.l  d1,d0
lsl.l   #2,d0
add.l   d2,d0

; After: costs guide better instruction selection
lea     0(a0,d1.l*4),a0
```

### Test cases

- `test_array_indexing()` — indexed array access costing
- `test_array_indexing_assume()` — with `__builtin_assume` range hint

---

## 2. Induction Variable Optimization

Improves induction variable selection for auto-increment addressing. When the target supports auto-increment, IV step costs are discounted to zero if the step matches a memory access size (1, 2, or 4 bytes). On m68k, the `addq.l #2,a0` that IVOPTS costs for each pointer IV is absorbed into `(a0)+` for free — the same reasoning GCC already applies to doloop decrements. Without this, IVOPTS prefers fewer IVs with indexed addressing over separate pointer IVs that benefit from post-increment.

Also prefers fewer IV registers when cost is equal, and avoids autoincrement in outer loops when the pointer is used in an inner loop.

Disable step discount with: `-fno-ivopts-autoinc-step`

**Pass:** `ivopts` (modified, `tree_ssa_iv_optimize()` in `gcc/tree-ssa-loop-ivopts.cc`)

**Code:** `gcc/tree-ssa-loop-ivopts.cc`

### Implementation history

1. **Step cost discount** (`559f4449f3a`): Credits auto-increment savings in IVOPTS cost model, similar to how doloop is credited over loop increments. Without this, the optimizer favors loop constructs using indexed addressing `(a0,d0.l)` (10 cycles on 68000) over separate pointer IVs with `(a0)+` (4 cycles).
2. **Register pressure tie-breaking** (`ab3a166c954`): When two IV candidate sets have equal cost, prefer the one with fewer IV registers. Reduces register pressure without sacrificing performance.
3. **Inner loop protection** (`dc5ead2194e`): Don't prefer auto-increment for an IV in an outer loop if that pointer is used in an inner loop — the inner loop would need indexed addressing, which is more expensive.
4. **Doloop interaction** (`c4c5a70cb33`): Added `TARGET_DOLOOP_COST_FOR_COMPARE` to credit `dbra` savings, preventing IVOPTS from eliminating the loop counter IV in favor of pointer comparison.

### Examples

```c
for (int i = 0; i < n; i++) dst[i] = src[i];
```
```asm
; Before: indexed addressing — single counter, 10-cycle mem accesses
move.l  (a0,d0.l),(a1,d0.l)
addq.l  #4,d0

; After: post-increment — separate pointer IVs, 4-cycle mem accesses
move.l  (a0)+,(a1)+
```

### Test cases

- `test_dbra_matching_counter()` — IVOPTS replaces integer IV with pointer IVs
- `test_multiple_postinc()` — multiple pointer IVs in one loop
- `test_multiple_postinc_short()` — short pointer increments
- `test_matrix_mul()` — nested loop IV selection

---

## 3. Autoincrement Optimization Pass

Converts indexed memory accesses with incrementing offsets to post-increment addressing. Also works across basic block boundaries: when a load in a predecessor BB has its pointer incremented at the top of the fall-through BB, and the register is dead on the other edge, the pass combines them into post-increment. PRE self-loop edge splitting is suppressed (`--param=pre-no-self-loop-insert=1`) to keep tight loops in a single BB where auto-increment works naturally.

**Passes:** `m68k-autoinc-split` (new GIMPLE pass), `m68k-autoinc` (new RTL pass), `m68k-normalize-autoinc` (new RTL pass)

Disable with: `-mno-m68k-autoinc`

**Code:** `gcc/config/m68k/m68k-gimple-passes.cc`, `gcc/config/m68k/m68k-rtl-passes.cc`, `gcc/gcse.cc`

### Implementation history

The autoincrement optimization evolved through several iterations, each addressing a different class of missed opportunities:

1. **GIMPLE split pass** (`6e3f1c35c3d`): The `m68k-autoinc-split` pass runs after IVOPTS (5.95a) and re-splits combined pointer increments so the later RTL `inc_dec` pass can fold them into `(a0)+`. IVOPTS sometimes combines separate pointer advances into a single multi-step increment.
2. **RTL normalize pass** (`58daf90bee2`): The `m68k-normalize-autoinc` pass runs before `peephole2` and canonicalizes auto-increment patterns. Initially attempted as a modification to `gimplify.cc` but that caused ICEs on complex code.
3. **Post-RA conversion** (`fb441a5d443`, `c0e4abafcff`): The main `m68k-autoinc` RTL pass runs after register allocation (9.14b). At this point, physical registers are known, revealing new merging opportunities invisible pre-RA. Phase 1 (`try_relocate_increment`) handles negative-offset normalization; Phase 2 (`try_convert_to_postinc`) does the actual conversion.
4. **DF notification bug** (`fb441a5d443`): `try_convert_to_postinc()` modified RTL instructions without calling `df_insn_rescan()`, leaving stale dataflow references. This caused use-after-free crashes in `sched2`'s `df_note_compute` — diagnosed via the macOS `0xa5a5a5a5` freed-memory pattern.
5. **Cross-BB post-increment** (`0f37617ba8a`): When a load in a predecessor BB is followed by an increment (`addq`) at the top of the fall-through BB, and the address register is dead on the other edge, the pass combines them into post-increment and deletes the `addq`. Saves 2 instructions per iteration in patterns like mintlib's `strcmp`.
6. **PRE self-loop suppression** (`f260a47bf92`): PRE treats a preheader expression matching the loop body as partially redundant and inserts on the self-loop edge, creating a new latch BB. This adds +1 copy +1 jump per iteration and blocks `auto_inc_dec`. Suppressed with `--param=pre-no-self-loop-insert=1`.

### Examples

```asm
; Before (within-BB indexed)    ; After (post-increment)
    move.w  #1,(a0)                 move.w  #1,(a0)+
    move.w  #2,2(a0)                move.w  #2,(a0)+

; Before (cross-BB)             ; After
    move.b  (%a0),%d0               move.b  (%a0)+,%d0
    jeq     .done                   jeq     .done
    addq    #1,%a0

; Before (PRE edge split)       ; After (single-BB loop)
    tst.b   -1(%a0)                 tst.b   (%a0)+
    jne     .latch                  jne     .loop
    ...
    addq    #1,%a0
    jra     .loop
```

### Test cases

- `test_multiple_postinc()` — 4 post-increments in one iteration
- `test_multiple_postinc_short()` — negative offset relocation
- `test_postinc_write()` — post-increment on store, not load
- `test_while_postinc()` — `strcpy`-style loop
- `test_while_postinc_bounded()` — dual exit condition loop
- `test_mintlib_strcmp()`, `test_libcmini_strcmp()` — real-world cross-BB patterns
- `test_mintlib_strcpy()`, `test_libcmini_strcpy()` — string copy patterns
- `test_mintlib_strlen()`, `test_libcmini_strlen()` — string length patterns

---

## 4. Memory Access Merge Peepholes

Combines adjacent small memory accesses into larger ones, and eliminates register intermediates in load+store+branch sequences by using mem-to-mem moves (68000 only).

**Patterns:** `define_peephole2` in machine description

**Code:** `gcc/config/m68k/m68k.md`

### Implementation history

1. **Word merge** (`e66ddbf957a`): Adjacent `move.w` with consecutive post-increment or offsets are merged into a single `move.l`. Also handles offset+index addressing variants.
2. **Offset+index merge** (`396797f5c35`): Extended merging to handle indexed addressing modes, not just plain register indirect.
3. **Mem-to-mem optimization** (`3ace2ff7867`): On 68000, `move.b (a1)+,d0; move.b d0,(a0)+; jne .L` uses a register as intermediate. Since 68000 supports mem-to-mem moves, this collapses to `move.b (a1)+,(a0)+; jne .L` — saving one instruction and one register. The mem-to-mem move sets CC, so the branch can test it directly.

### Examples

```asm
; Before (word merge)           ; After
    move.w  #1,(a0)+                move.l  #$10002,(a0)+
    move.w  #2,(a0)+

; Before (mem-to-mem)           ; After (68000 only)
    move.b  (a1)+,d0                move.b  (a1)+,(a0)+
    move.b  d0,(a0)+                jne     .L
    jne     .L
```

### Test cases

- `test_clear_struct()` — adjacent field clears merge into `clr.l`
- `test_clear_struct_unorderred()` — requires reordering (§11) before merge
- `test_clear_mixed_sizes()` — mixed-size clears
- `test_copyn_16()` — constant-count copy merges word moves to long

---

## 5. DBRA Loop Optimization

Uses `dbra` for loop counters via GCC's doloop infrastructure. Value Range Propagation determines if the counter fits in 16 bits; when safe, 32-bit counters are narrowed to 16-bit to enable `dbra`.

IVOPTS can transform count-down loops into pointer-comparison loops, preventing `dbra`. A new `TARGET_DOLOOP_COST_FOR_COMPARE` hook credits `dbra` in the IVOPTS cost model, keeping the counter IV for `dbra` over pointer comparison. For dynamic counts, `__builtin_assume()` can provide the range information needed.

Disable with: `-mno-m68k-doloop`

**Code:** `gcc/config/m68k/m68k.cc`, `gcc/config/m68k/m68k.md`, `gcc/tree-ssa-loop-ivopts.cc`

### Implementation history

1. **Initial dbra patterns** (`77b66e964e2`, `3c186d11313`): Inspired by Bebbo's amiga gcc6 work. Added basic `doloop_end` patterns to `m68k.md` that map to `dbra`.
2. **Conservative doloop hooks** (`e28f7d76140`): Second attempt at dbra, using GCC's doloop infrastructure and being conservative about when to apply it. The key constraint: `dbra` operates on 16-bit registers (word decrement, branch on >= 0).
3. **IVOPTS cost credit** (`c4c5a70cb33`): Added `TARGET_DOLOOP_COST_FOR_COMPARE` hook. Without it, IVOPTS eliminates the loop counter in favor of pointer comparison (`ptr != end`), making `dbra` impossible. The hook adds a cost penalty for eliminating the counter IV when `dbra` is available.
4. **Unrolling interaction** (`8b90258683f`): Disabled IV splits in loop unrolling so unrolled iterations chain post-increments. Also consolidated counter increments for constant-iteration unrolled loops so the doloop pass can use `dbra` for the main loop.

### Examples

```c
short count = 100;
do { work(); } while (--count);
```
```asm
; Before: separate decrement and branch
subq.w  #1,d0
bne     .loop

; After: combined dbra
dbra    d0,.loop
```

For dynamic values, `__builtin_assume()` provides range information:

```c
void process(int n) {
    __builtin_assume(n > 0 && n <= 32767);
    for (int i = n; i > 0; i--) work();
}
```
```asm
; Before (without assume): 32-bit counter
subq.l  #1,d2
bne     .loop

; After (with assume): dbra is used
dbra    d2,.loop
```

### Test cases

- `test_dbra_const_count()` — constant 50 iterations → `moveq #49` + `dbra`
- `test_dbra_matching_counter()` — matching counter types enable `dbra`
- `test_dbra_mixed_counter()` — mixed sizes prevent `dbra` (negative test)
- `test_doloop_const_small()` — small constant (100) → `dbra`
- `test_doloop_himode()` — `unsigned short` counter with `__builtin_unreachable` bound
- `test_doloop_simode_unbounded()` — unbounded `unsigned int` → no `dbra` (negative test)
- `test_doloop_const_large()` — 100000 iterations → no `dbra` (negative test)
- `test_matrix_add()` — nested loops, both using `dbra`
- `test_matrix_mul()` — matrix-vector multiply with `dbra` inner loop

---

## 6. Multiplication Optimization

Narrows 32-bit multiplications to 16-bit `muls.w` when operand ranges are known to fit, and removes redundant sign extension after 16-bit multiply since `muls.w` already produces a 32-bit signed result.

**Pass:** `m68k-narrow-index-mult` (new GIMPLE pass)

Disable with: `-mno-m68k-narrow-index-mult`

**Patterns:** `define_peephole2` for sign extension elimination

**Code:** `gcc/config/m68k/m68k-gimple-passes.cc`, `gcc/config/m68k/m68k.md`

### Implementation history

1. **Peephole for muls+ext.l** (`5e61d6f5c4e`): Added `define_peephole2` that folds `muls.w` + `ext.l` into just `muls.w`, since `muls.w` already produces a 32-bit signed result. The `ext.l` is completely redundant.
2. **GIMPLE narrowing pass** (`f4813817686`): Added a GIMPLE pass that narrows 32-bit multiplications to 16-bit when VRP proves both operands fit in 16 bits. On 68000, a 32-bit multiply requires a `__mulsi3` library call (50+ cycles), while `muls.w` is a single instruction (38+2N cycles on 68000, much faster on 68020+).
3. **Type mismatch fix** (`3d521ee7705`): When `input_prec == 16` and the input is unsigned short but `hi_type` is signed short, the multiply had a type mismatch. Fixed by always converting to `hi_type` when types differ, using `useless_type_conversion_p` to check.

### Examples

```c
int idx = (row & 0xFF) * 320;
```
```asm
; Before: 32-bit multiply (library call on 68000)
jsr     __mulsi3
ext.l   d0

; After: 16-bit multiply, no extension needed
muls.w  #320,d0
```

### Test cases

- `test_matrix_mul()` — `muls.w` in inner loop with auto-increment
- `test_no_elim_muls()` — `muls.w` produces 32-bit result, should NOT be modified

---

## 7. ANDI Hoisting

Replaces `andi.l #mask` or `andi.w #mask` for zero-extension with a hoisted `moveq #0` and register moves. This also optimizes explicit masking operations.

**Pass:** `m68k-elim-andi` (new RTL pass)

Disable with: `-mno-m68k-elim-andi`

**Code:** `gcc/config/m68k/m68k-rtl-passes.cc`

### Implementation history

1. **Initial implementation** (`0e6555c0b69`): Replaces `andi.l #$ff` / `andi.l #$ffff` used for zero-extension with a hoisted `moveq #0,dN` before the register's definition point. The `moveq` clears the upper bits, so subsequent byte/word operations preserve the zero upper bits naturally.
2. **Loop hoisting fix** (`ec328e3263e`): Corrected hoisting of the pre-clearing `moveq #0` out of loops. The zero register must be established before the definition that feeds the `andi`, which may be a loop-carried value.
3. **clr.w+move.b scan continuation** (`5d9c5565653`): The backward scan stopped at `DEFINES_BYTE` (e.g., `move.b`), missing a preceding `clr.w` that could be widened to `moveq #0`. For `WORD_TO_LONG` candidates, the scan now continues past byte definitions to find word-level definitions. When it finds `clr.w`, it widens it in-place to `moveq #0` (clearing all 32 bits), making the later `andi.l #65535` redundant.
4. **and.w mask widening** (`5d9c5565653`): When the backward scan reaches function entry with no definition but finds `and.w #N` along the way (e.g., masking a parameter), the pass widens `and.w #N` to `and.l #N`. This clears bits 16-31 as a side effect, eliminating the later `andi.l #65535`.

### How it works

On m68k, word (`.w`) and byte (`.b`) operations only modify the lower bits, leaving upper bits unchanged. When GCC needs a 32-bit value from a 16-bit operation, it generates `andi.l #65535` to zero-extend. This costs 6 bytes and 16 cycles on 68000.

The pass instead inserts `moveq #0,dN` before the register's first definition, pre-clearing the upper bits. Since subsequent `.w`/`.b` operations don't touch the upper bits, they remain zero — making the `andi` redundant.

**Constraint:** The pass must verify that no instruction between the `moveq #0` and the `andi` writes to bits wider than the extension width. A `muls.w` or `ext.l` would clobber the upper bits, invalidating the optimization.

### Examples

```c
for (...) { use(bytes[i] & 0xFF); }
```
```asm
; Before: repeated ANDI per iteration
move.b  (a0)+,d0
andi.l  #255,d0             ; 6 bytes, 16 cycles

; After: hoisted zero register
moveq   #0,d0               ; once, outside loop
move.b  (a0)+,d0             ; upper bits stay zero
```

### Test cases

- `test_elim_andi_basic()` — basic word load + decrement + reuse
- `test_elim_andi_multi()` — chain of word operations
- `test_elim_andi_loop()` — `andi` elimination inside loop (highest value)
- `test_elim_andi_load()` — load from memory then use as 32-bit
- `test_elim_andi_load2()` — two independent loads
- `test_elim_andi_byte_load()` — byte load zero-extension
- `test_elim_andi_byte_loop()` — byte extension in loop
- `test_elim_andi_byte_index()` — byte used as array index
- `test_no_elim_muls()` — `muls` clobbers upper bits (negative test)
- `test_no_elim_ext()` — `ext.l` sets upper bits (negative test)
- `test_no_elim_byte_word_op()` — word op clobbers bits 8-15 (negative test)
- `test_cross_bb_simple()` — cross-BB definition
- `test_cross_bb_cond()` — conditional definition paths
- `test_cross_bb_loop()` — definition before loop
- `test_andi_clrw_byte_def()` — `clr.w`+`move.b` pattern: scan past byte def to find widenable `clr.w`
- `test_andi_widen_mask()` — `and.w #N` widening: widen to `and.l #N` to eliminate later `andi.l #65535`

---

## 8. Word Packing and Insert Patterns

Improves code for packing 16-bit values into 32-bit registers. Folds `andi.l #$ffff` + `ori.l` sequences into `swap`+`move.w`+`swap`.

**Pass:** `m68k-highword-opt` (new RTL pass)

Disable with: `-mno-m68k-highword-opt`

**Patterns:** `define_peephole2` for andi/ori folding

**Code:** `gcc/config/m68k/m68k-rtl-passes.cc`, `gcc/config/m68k/m68k.md`

### Implementation history

1. **Insert patterns** (`60c4dbc510e`): Added `define_insn` patterns for inserting 16-bit values into `struct { short, short }` passed in registers. With `-mfastcall`, these structs are passed/returned in a single data register (high word = first field, low word = second field).
2. **ANDI/ORI folding peepholes** (`61bbaa3c5fb`): Added `define_peephole2` patterns that recognize `andi.l #$ffff` + `ori.l` sequences (used by GCC for field insertion) and replace with `swap` + `move.w` + `swap`.
3. **RTL highword pass** (`2519036243b`): Added the `m68k-highword-opt` RTL pass to handle more complex patterns that peephole2 cannot match, such as when the source and destination are in different registers or when intermediate operations separate the masking and insertion.
4. **ICE fix** (`2519036243b`): Fixed an ICE in the word packing pass exposed by the cross-BB autoinc improvements.

### Examples

```c
struct Point { short x, y; };
struct Point make_point(short a, short b) { return {a, b}; }
```
```asm
; Before: shift and OR (4 insns, 16 bytes)
swap    d0
clr.w   d0
andi.l  #$ffff,d1
or.l    d1,d0

; After: direct packing (2 insns, 4 bytes)
swap    d0
move.w  d1,d0
```

Setting upper word only:

```c
x = (x & 0xFFFF) | 0x464F0000;
```
```asm
; Before: 12 bytes
andi.l  #$ffff,d0
ori.l   #$464f0000,d0

; After: 8 bytes
swap    d0
move.w  #$464f,d0
swap    d0
```

### Test cases

- `test_highword_extract_low()` — low word extraction (already optimal)
- `test_highword_extract_high()` — high word: `clr.w; swap` → `swap`
- `test_highword_extract_computed()` — high word + arithmetic
- `test_highword_insert_low()` — low word insert (already optimal via `strict_low_part`)
- `test_highword_insert_high()` — high word insert: `swap; clr.w; andi.l; or.l` → `swap; move.w; swap`
- `test_highword_insert_computed()` — computed value into high word
- `test_small_struct()` — struct packing in nested loop

---

## 9. IRA Register Class Promotion

Promotes pointer pseudos from DATA_REGS to ADDR_REGS when used as memory base addresses. On m68k, only address registers can serve as base registers, so IRA's default allocation can result in expensive register-to-register moves.

On 68000/68010, this promotion introduces a regression for NULL pointer checks: `tst.l` cannot operate on address registers, so the backend emits `cmp.w #0,%aN` (4 bytes, 12 cycles). A peephole2 fixes this by replacing the compare with `move.l %aN,%dN` (2 bytes, 4 cycles) when a scratch data register is available. The `move.l` sets CC identically to `cmp.w #0`, so the existing CC elision mechanism skips the subsequent `tst.l`. On 68020+ this is unnecessary since `tst.l %aN` is valid (2 bytes).

Disable with: `-mno-m68k-ira-promote`

**Hook:** `TARGET_IRA_CHANGE_PSEUDO_ALLOCNO_CLASS`

**Patterns:** `*cbranchsi4_areg_zero`, `*cbranchsi4_areg_zero_rev` (`define_insn`), address register zero test (`define_peephole2`)

**Code:** `gcc/config/m68k/m68k.cc` (`m68k_ira_change_pseudo_allocno_class()`), `gcc/config/m68k/m68k.md`

### Implementation history

1. **IRA promotion hook** (`595da26c5a1`): Added the `m68k_ira_change_pseudo_allocno_class` hook. When IRA is about to assign a pseudo-register to DATA_REGS but that pseudo is used as a memory base address (inside a MEM RTX), the hook promotes it to ADDR_REGS. This prevents the costly `move.l dN,aM` before every memory access.
2. **Address register zero test** (`ea1920e44cf`): Added peephole2 + define_insn patterns to fix the NULL-check regression on 68000/68010 caused by IRA promotion. A naive peephole2 emitting separate `(set dN aN)` + `(branch on dN)` was undone by `cprop_hardreg` (9.18), which propagated the address register back and deleted the dead copy. The solution uses a parallel-with-clobber: the RTL still compares the address register `(eq %aN 0)`, but the `define_insn` output template emits `move.l %aN,%dN` and relies on CC elision to skip the `tst.l`. Since `cprop_hardreg` sees a comparison against `%aN` (not a copy to `%dN`), it has nothing to undo.
3. **Redundant move elision** (`5d9c5565653`): The `*cbranchsi4_areg_zero` output template now checks `m68k_find_flags_value()` before emitting `move.l %aN,%dN`. When the preceding instruction (e.g., `move.l %aN,<mem>`) already sets CC for the address register, the move is skipped — the branch uses CC directly. Saves 2 bytes and 4 cycles per elided instance (15 instances in the game binary, all shared_ptr reference counting).

### How it works

**IRA promotion:** IRA assigns pseudo-registers to register classes based on instruction constraints. However, it sometimes assigns a pointer pseudo to DATA_REGS when address registers are under pressure. On m68k, data registers cannot be used as base registers in memory operands — any `(d3)` would require a `move.l d3,a0` copy first. The hook scans uses of each pseudo and forces address-register allocation when any use is inside a MEM operand.

**Address register zero test (68000/68010):** The peephole2 matches a `cbranchsi4_insn` comparing an address register against zero and adds a clobber, forming a `*cbranchsi4_areg_zero` insn. The output template first checks `m68k_find_flags_value()` — if CC is already valid for the address register (e.g., from a preceding `move.l %aN,<mem>`), the move is skipped entirely and only the branch is emitted. Otherwise, the template calls `output_move_simode` (which sets `flags_valid = FLAGS_VALID_MOVE` and `flags_operand1 = %dN`), then `m68k_output_compare_si` (which finds flags already valid and elides `tst.l`), then `m68k_output_branch_integer`. Net assembly: `move.l %aN,%dN; jCC label` (4 bytes) instead of `cmp.w #0,%aN; jCC label` (6 bytes), or just `jCC label` (2 bytes) when CC is already valid.

### Examples

```c
while (n--) sum += *p++;
```
```asm
; Before: pointer in data register requires move to address register
.loop:
    move.l  d2,a0           ; d→a copy every iteration!
    move.b  (a0),d0
    addq.l  #1,d2
    add.w   d0,d1
    dbra    d3,.loop

; After: pointer directly in address register
.loop:
    move.b  (a0)+,d0
    add.w   d0,d1
    dbra    d3,.loop
```

Address register NULL check (68000/68010):

```c
while (p) { sum += p->val; p = p->next; }
```
```asm
; Before: expensive address register compare
    cmp.w   #0,%a0          ; 4 bytes, 12 cycles
    jeq     .done

; After: move to scratch data register with CC elision
    move.l  %a0,%d0         ; 2 bytes, 4 cycles (CC set)
    jeq     .done           ; no tst.l needed
```

Redundant move elision (68000/68010, when preceding store sets CC):

```c
*dst = cnt;
if (cnt) cnt->count++;
```
```asm
; Before: redundant move after store
    move.l  %a1,(%a0)       ; sets CC for a1
    move.l  %a1,%d0         ; REDUNDANT — CC already valid
    jeq     .done

; After: store sets CC, branch directly
    move.l  %a1,(%a0)       ; sets CC for a1
    jeq     .done           ; uses CC from store
```

### Test cases

- `test_redundant_move()` — sum loop with pointer in correct register
- `test_loop_moves()` — cast-heavy pointer arithmetic stays in address register
- `test_null_ptr_loop()` — linked list NULL check uses `move.l` instead of `cmp.w #0` on 68000
- `test_areg_zero_elide()` — store sets CC for address register, `move.l aN,dN` elided

---

## 10. Improved Loop Unrolling

`TARGET_PREFER_RUNTIME_UNROLL_TABLEJUMP` hook replaces the default compare cascade with a jump table, dispatching the remainder in constant time (~3 instructions + 2N bytes of data). Constant-iteration loops get their decrement copies consolidated into a single counter for `dbra`. Disables IV splitting so unrolled copies chain post-increments instead of using base+offset. Register renaming is enabled at -O2+ since m68k has no register encoding differences.

**Code:** `gcc/config/m68k/m68k.cc`, `gcc/loop-unroll.cc`, `gcc/loop-doloop.cc`

### Implementation history

1. **Initial Duff's device** (`19cadf4af44`): Replaced GCC's default unrolled remainder (a serial compare cascade) with a modulo-loop approach: a small loop for the leftover iterations, then the main unrolled loop. Smaller and faster than the cascade.
2. **SjLj exception fix** (`34e4bb3426d`): The modulo-loop path called `single_succ_edge`/`single_pred_edge` after `make_edge` had added additional edges, causing assertion failures. SjLj exceptions add extra EH edges that broke the dominator tree. Disabled modulo unrolling entirely for SjLj.
3. **Jump-table rewrite** (`97c42dbf01a`): Replaced the modulo-loop approach with a jump table: `move.w .tab(pc,d1.w),d1; jmp 2(pc,d1.w)`. Constant-time dispatch regardless of remainder value. Reuses most of GCC's default Duff's-device mechanism but dispatches via table instead of compare cascade.
4. **IV split disable** (`8b90258683f`): Disabled IV splitting in loop unrolling so unrolled copies chain post-increments (`(a0)+, (a0)+, ...`) instead of using base+offset (`0(a0), 2(a0), 4(a0), ...`). Also consolidated counter increments for constant-iteration loops so the doloop pass can apply `dbra`.

### Examples

```c
#pragma GCC unroll 8
while (count--) {
    *(d_first) = *(first);
    ++d_first; ++first;
}
```
```asm
; Before: compare cascade + base+offset addressing (65 insns)
    tst.l   d0
    beq     .Lmain
    moveq   #1,d2
    cmp.l   d0,d2
    beq     .Lpeel1
    ...                     ; cases 2-7
.Lmain:
    move.w  (a0),(a1)
    move.w  2(a0),2(a1)
    ...

; After: jump-table dispatch + post-increment with dbra (21 insns)
    move.w  d0,d1
    and.w   #7,d1
    add.w   d1,d1
    move.w  .Ltab(pc,d1.w),d1
    jmp     2(pc,d1.w)
.Ltab:
    .word   .Lmain-.Ltab
    .word   .Lpeel1-.Ltab
    ...
.Lmain:
    lsr.w   #3,d0
    subq.w  #1,d0
.Lloop:
    move.l  (a0)+,(a1)+
    move.l  (a0)+,(a1)+
    move.l  (a0)+,(a1)+
    move.l  (a0)+,(a1)+
    dbra    d0,.Lloop
    rts
```

### Test cases

- `test_unrolled_postinc()` — `#pragma GCC unroll 4` with post-increment
- `test_unroll_tablejump()` — runtime unroll with tablejump dispatch
- `test_unroll_tablejump_manual()` — manual Duff's device as reference
- `test_copyn()` — unrolled copy with runtime count
- `test_copyn_16()` — constant 16-element copy (fully unrolled)
- `test_copy_palette_16()` — constant copy to hardware address

---

## 11. Memory Access Reordering

Reorders memory accesses through a base pointer to be sequential by offset, enabling store merging and post-increment addressing. Verifies safety using GCC's alias oracle. Runs before store-merging.

**Pass:** `m68k-reorder-mem` (new GIMPLE pass)

Disable with: `-mno-m68k-reorder-mem`

**Code:** `gcc/config/m68k/m68k-gimple-passes.cc`

### Implementation history

1. **Initial pass** (`30c150960a9`): Added a GIMPLE pass that reorders indexed memory accesses through the same base pointer in ascending offset order. This enables the store-merging pass (which requires stores in offset order) and the autoincrement pass (which needs sequential access).
2. **Alias safety** (`0d7b02a53d0`): Fixed a miscompilation: a store with a memory source could be reordered past a write that initializes that source. The pass originally only checked whether intervening statements clobber the store's destination, not its source operand.
3. **Build stability** (`c800837c5cb`): Re-enabled the pass after fixing the alias bug. Added individual disable flags for each m68k pass.

### Examples

```c
struct quad { short a, b, c, d; };
void clear_unordered(struct quad *s) {
    s->d = 0;  s->b = 0;  s->c = 0;  s->a = 0;
}
```
```asm
; Before: scattered accesses (no merging possible)
clr.w   6(a0)
clr.w   2(a0)
clr.w   4(a0)
clr.w   (a0)

; After: sequential enables merging + autoinc
clr.l   (a0)+
clr.l   (a0)+
```

### Test cases

- `test_clear_struct_unorderred()` — out-of-order field clears → reordered → merged
- `test_clear_struct()` — already-ordered clears (no reorder needed, just merge)

---

## 12. Single-Bit Extraction

Replaces shift+mask for single-bit extraction with `btst`+`sne` on 68000/68010. Shifts cost 6+2N cycles, while `btst` tests any bit in constant time. For unsigned extraction (result 0 or 1), `neg.b` converts the `sne` output from 0xFF to 0x01. For signed 1-bit fields, `sne` already produces the correct -1/0 result, saving one instruction. Disabled on 68020+ where `bfextu`/`bfexts` handle this natively.

Disable with: `-mno-m68k-btst-extract`

**Patterns:** `cstore_btst` `define_insn`, `define_peephole2`

**Code:** `gcc/config/m68k/m68k.md`

### Implementation history

1. **QI-mode patterns** (`64c9c826e66`): Added `cstore_btst` pattern and supporting peephole2. The `define_insn` emits `btst #N,<ea>; sne dN` directly. For unsigned results, a `neg.b` follows to convert `0xFF` → `0x01`. For signed 1-bit fields, `sne` already produces the correct `-1`/`0` result (`STORE_FLAG_VALUE = -1` on m68k).
2. **HI-mode patterns** (`34a9967708a`): Extended btst extraction peephole2 to HI mode (16-bit values, common with `-mshort`). Also added `ashiftrt` matching — when the source is signed, GCC generates arithmetic shift right, but for single-bit extraction `(x >> N) & 1` the result is identical to logical shift. For shifts exceeding the 68000's immediate limit (1-8), the constant-time `btst` is especially profitable since it avoids a register load for the shift count.

### How it works

On 68000, `(x >> N) & 1` generates `lsr.b #N,d0; and.b #1,d0` costing 6+2N cycles (N=7 → 20 cycles). The `btst` instruction tests any bit in constant time (6 cycles for register, 8 for memory). Combined with `sne` (6 cycles) and optional `neg.b` (4 cycles), the total is 16-18 cycles — profitable for bit positions >= 4.

For memory operands, `btst` can test bits directly in memory without loading to a register first: `btst #3,(a0)` instead of `move.b (a0),d0; lsr.b #3,d0; and.b #1,d0`.

On 68020+, `bfextu`/`bfexts` handle arbitrary bitfield extraction natively, so this optimization is disabled.

### Examples

```c
struct flags { unsigned char a:1, b:1, c:1, d:1, e:1; };
unsigned char get_flag(struct flags *p) { return p->e; }
```
```asm
; Before: load + shift + mask (14+ cycles)
move.b  (a0),d0
lsr.b   #3,d0
and.b   #1,d0

; After: btst + sne + neg (18 cycles, constant time)
btst    #3,(a0)
sne     d0
neg.b   d0
```

Signed 1-bit fields save one instruction:

```c
struct sflags { signed char a:1, b:1, c:1, d:1, e:1; };
signed char get_sflag(struct sflags *p) { return p->e; }
```
```asm
; Before: load + shift + sign-extend (20+ cycles)
move.b  (a0),d0
lsl.b   #4,d0
asr.b   #7,d0

; After: btst + sne (14 cycles, no neg needed)
btst    #3,(a0)
sne     d0
```

### Test cases

- `test_extract_mem_unsigned()` — memory QI unsigned, bit 4 → `btst+sne+neg`
- `test_extract_mem_signed()` — memory QI signed, bit 4 → `btst+sne` (no neg)
- `test_extract_reg_bit6()` — register unsigned, bit 6 (profitable)
- `test_extract_reg_bit1()` — register unsigned, bit 1 (NOT profitable, negative test)
- `test_btst_ashiftrt_hi()` — HI-mode arithmetic shift by 9 → `btst #9` (exceeds immediate limit)
- `test_btst_ashiftrt_hi_const()` — HI-mode arithmetic shift by 5 → `btst #5` (within immediate limit)
- `test_bit_struct_active()` through `test_bit_struct_hidden()` — bitfield operations at various positions

---

## 13. Available Copy Elimination

Removes redundant register-to-register copies that are already established on all incoming paths. Primarily cleans up after `inc_dec`, which reintroduces copies in unrolled loop peels. Eliminating these before IRA allows the register allocator to coalesce registers.

Disable with: `-mno-m68k-avail-copy-elim`

**Pass:** `m68k-avail-copy-elim` (new RTL pass, runs after `inc_dec`)

**Code:** `gcc/config/m68k/m68k-rtl-passes.cc`

### Implementation history

1. **Created alongside unrolling rewrite** (`97c42dbf01a`): When `inc_dec` converts address+increment pairs to post-increment in unrolled loop peels, it reintroduces register copies that were previously optimized away. These redundant copies increase register pressure and can cause unnecessary spills. The `m68k-avail-copy-elim` pass runs after `inc_dec` (7.29a) and before IRA, eliminating copies that are already established on all incoming paths.

### How it works

The pass performs a forward dataflow analysis tracking which register copies (`reg_A = reg_B`) are available at each program point. At basic block entries, it intersects the available copies from all predecessors. When it finds a copy instruction whose source-destination pair is already available (i.e., the copy is redundant), it deletes the instruction.

This is particularly effective for unrolled loops where each peel iteration has its own copy of the loop's register setup, but `inc_dec` has already merged the increments into post-increment addressing — making the separate copies redundant.

---

## 14. Load Reordering for CC Tracking

On m68k, `move` sets CC. If the register tested by a branch is not the last one loaded, `final` must emit an explicit `tst`. This pass reorders loads so the tested register is loaded last, allowing `final` to elide the `tst`.

**Pass:** `m68k-reorder-cc` (new RTL pass)

**Code:** `gcc/config/m68k/m68k-rtl-passes.cc`

### Implementation history

1. **Single commit** (`0bce85e46b4`): Added the `m68k-reorder-cc` RTL pass. It works in two modes:
   - **Within-BB reorder:** When two loads in the same basic block are followed by a branch testing one of them, and the loads are independent (no data dependency), swap them so the tested register is loaded last.
   - **Cross-BB sink:** When a load in a predecessor BB feeds a branch at the top of a successor BB, and there's an independent load between them that could be moved, sink the tested load past the independent one.

### How it works

GCC's `final` pass tracks condition codes: after a `move.l d0,(a0)`, the CC reflects `d0`. If the next branch tests `d0`, no explicit `tst.l d0` is needed. But if another `move` intervenes (e.g., `move.l d1,(a1)`), CC now reflects `d1`, and `final` must emit `tst.l d0` before the branch.

This pass ensures the register being tested is the last one written before the branch, so `final`'s CC tracking can elide the `tst`. Saves one instruction per loop iteration in patterns like `strcmp` where two bytes are loaded and one is tested.

### Examples

```asm
; Before: d0 tested but d1 loaded last — tst needed
    move.b  (%a0)+,%d0
    move.b  (%a1)+,%d1
    tst.b   %d0
    jeq     .done

; After: d0 loaded last — CC already correct
    move.b  (%a1)+,%d1
    move.b  (%a0)+,%d0
    jeq     .done
```

### Test cases

- `test_mintlib_strcmp()` — two-byte compare loop, reordered for CC
- `test_libcmini_strcmp()` — same pattern, different implementation

---

## 15. Sibcall Optimization

Loosens restrictions on sibcall (tail call) optimization under the fastcall ABI. The stock backend conservatively disables sibcalls when parameter registers differ between caller and callee, but under fastcall many of these cases are safe because the arguments are already in the right registers or can be trivially rearranged.

**Code:** `gcc/config/m68k/m68k.cc`

### Implementation history

1. **Initial disable** (`b26508044c3`): Sibcalls were initially disabled entirely with `-mfastcall` because the register-based calling convention made it impossible to guarantee safe register assignments in all cases.
2. **First fix** (`57daa24129a`): Enabled sibcalls for a subset of cases where register assignments were provably safe.
3. **Full relaxation** (`5c57312a773`): Loosened restrictions further. Under fastcall ABI, arguments are passed in registers (`d0`, `d1`, `a0`, `a1`), so many caller→callee transitions can be a simple `jra` jump without any register shuffling.

### Examples

```c
short appl_bvset(short bvdisk, short bvhard) {
    return mt_appl_bvset(bvdisk, bvhard, aes_global);
}
```
```asm
; Before: full call + return
    move.l  aes_global,%a0
    ext.l   %d1
    ext.l   %d0
    jsr     mt_appl_bvset
    rts

; After: tail call (saves jsr+rts overhead)
    move.l  aes_global,%a0
    ext.l   %d1
    ext.l   %d0
    jra     mt_appl_bvset
```

---

## Appendix A: libcmini Real-World Example

The optimizations above combine to produce significant improvements in real library code. This example shows `memcmp` from libcmini, a minimal C library for Atari ST, when compiled with `-Os -mshort -mfastcall`.

**Code:** `libcmini/sources/memcmp.c`

```c
int memcmp(const void *s1, const void *s2, size_t n) {
    const unsigned char *p1 = s1, *p2 = s2;
    while (n--) {
        if (*p1 != *p2) return *p1 - *p2;
        p1++; p2++;
    }
    return 0;
}
```
```asm
; Before: indexed addressing with counter (56 cycles/byte, 40 bytes)
        moveq   #0,d2
.loop:  move.b  (a0,d2.l),d1        ; 16 cycles - indexed addressing
        addq.l  #1,d2               ;  8 cycles - increment counter
        move.b  -1(a1,d2.l),d3      ; 16 cycles - indexed with offset
        cmp.b   d1,d3               ;  4 cycles
        beq.s   .loop               ; 12 cycles (taken)
                           Total:     56 cycles/byte

; After: post-increment addressing (32 cycles/byte, 28 bytes)
.loop:  move.b  (a0)+,d0            ;  8 cycles - post-increment
        move.b  (a1)+,d1            ;  8 cycles - post-increment
        cmp.b   d0,d1               ;  4 cycles
        beq.s   .check              ; 12 cycles (taken)
                           Total:     32 cycles/byte
```

**Optimizations applied:**

1. **Induction Variable (§2):** IVOPTS selects separate pointer IVs instead of a single integer counter, enabling post-increment
2. **Autoincrement Pass (§3):** Converts `(a0,d2.l)` indexed addressing to `(a0)+` post-increment
3. **IRA Register Class (§9):** Keeps pointers in address registers, avoiding `move.l dN,aM` copies

**Result:** 43% faster, 30% smaller code.

---

## Appendix B: Known Missing Optimizations

The following optimizations are not yet implemented but would further improve m68k code generation.

### B.1 Cross-Basic-Block ANDI Hoisting

The current ANDI hoisting optimization (§7) only works within a single basic block. When the same zero-extension pattern appears across multiple basic blocks (e.g., in different branches of an if-else), each block gets its own `moveq #0` instead of hoisting a single `moveq #0` to a dominating block.

```c
if (cond) {
    use(bytes[i] & 0xFF);
} else {
    use(bytes[j] & 0xFF);
}
```
```asm
; Current: repeated zero register in each branch
.then:  moveq   #0,d2
        move.b  (a0),d2
        ...
.else:  moveq   #0,d2
        move.b  (a1),d2

; Desired: hoisted zero register
        moveq   #0,d2           ; once, before branch
.then:  move.b  (a0),d2
        ...
.else:  move.b  (a1),d2
```

### B.2 Redundant TST Elimination

The m68k `move` instruction sets condition codes, but GCC often generates redundant `tst` instructions before branches. The `m68k-reorder-cc` pass (§14) addresses the common case where loads can be reordered so the tested register is loaded last, but the general case — where `move` and branch are separated by register allocation or instruction scheduling — remains.

```c
short x = get_value();
if (x == 0) handle_zero();
```
```asm
; Current: redundant tst
        jsr     get_value
        move.w  d0,d1           ; sets Z flag
        tst.w   d1              ; redundant
        beq.s   .handle_zero

; Desired: tst eliminated
        jsr     get_value
        move.w  d0,d1           ; sets Z flag
        beq.s   .handle_zero
```

### B.3 16-bit Register Spills (RESOLVED)

**Spill slot sizing** is handled by the `TARGET_LRA_SPILL_SLOT_MODE` hook. HImode/QImode pseudos now get narrow stack slots.

**Swap-based spill replacement** was investigated and rejected. The idea: replace a spill/reload pair with two `swap` instructions, parking the 16-bit value in the upper half of the same data register.

```asm
; Before (~32 cycles)               ; Proposed (8 cycles)
        move.w  d2,offset(sp)               swap    d2
        ... use d2.w ...                     ... use d2.w ...
        move.w  offset(sp),d2               swap    d2
```

A prototype pass was implemented and tested against all of libcmini — zero matches. The pattern never occurs because:

1. **The RA spills for width, not pressure.** It frees a register to use it in SImode (32-bit pointer math, float ops, `move.l`), which clobbers the upper half.
2. **m68k has too many registers.** 8 data + 5 address registers all hold HImode. Within-BB pressure rarely forces narrow spills.
3. **Cross-BB reloads use different registers.** The RA assigns spill and reload to different hard registers.
