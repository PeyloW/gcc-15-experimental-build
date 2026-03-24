# m68k GCC 15 Optimizations

Since GCC 3, the m68k backend has received little attention while the rest of the compiler infrastructure has evolved significantly. The result is that GCC often generates surprisingly poor code for m68k: inefficient memory access patterns that ignore post-increment addressing, loops that barely ever use `dbra`, and wasteful instruction sequences that a human would never write.

The optimizations in this branch aim to address some of the most glaring missed opportunities.

My target machine is a 68000 with `-mshort` and `-mfastcall`, so that configuration has received the most testing and attention. Many of these optimizations also benefit 32-bit int mode and 68020+, but that is more by luck than deliberate effort—I have only verified that those configurations do not regress.

A PR-ready version of this document is available in [PR_COMMENT.md](PR_COMMENT.md).

## Index

**Optimizations**

1. [Cost Model](#1-cost-model)
2. [Register Allocation](#2-register-allocation)
3. [Loop Optimization](#3-loop-optimization)
4. [Memory Access Reordering](#4-memory-access-reordering)
5. [Autoincrement Optimization](#5-autoincrement-optimization)
6. [16/32-bit Optimization](#6-1632-bit-optimization)
7. [Various Smaller Optimizations](#7-various-smaller-optimizations)
8. [68040 Pipeline and 68060 Superscalar](#8-68040-pipeline-and-68060-superscalar)

**Appendix**

- [A. libcmini Real-World Example](#appendix-a-libcmini-real-world-example)
- [B. Known Missing Optimizations](#appendix-b-known-missing-optimizations)

---

## 1. Cost Model

Rewritten cost model using lookup tables with actual cycle counts per CPU generation (68000, 68020-030, 68040+), inspired by Bebbo's gcc6 work. The stock GCC 15 m68k backend uses flat costs without distinguishing addressing modes, operand sizes, or CPU generations.

`TARGET_ADDRESS_COST` distinguishes per-mode address costs — `(a0)` (4 cycles) vs `8(a0)` (8 cycles) vs `(a0,d0.l)` (10 cycles). `TARGET_NEW_ADDRESS_PROFITABLE_P` prevents the scheduler from replacing post-increment with indexed addressing when it is not cheaper.

`TARGET_INSN_COST` costs whole instructions including the destination operand. GCC's default only costs the source, so memory stores appear cheap. Non-RMW compound operations to memory are costed additively (copy+op+store), preventing combine passes from folding IVs into base+offset form that needs three instructions. On 68020+, address sub-expressions inside MEM are costed once as addressing modes, avoiding double-counting.

`TARGET_IVOPTS_ALLOW_CONST_PTR_ADDRESS_USE` (new, default off) enables IVOPTS to classify constant-base pointer IVs (e.g., `(short*)0xffff8240`) as REFERENCE ADDRESS uses instead of GENERIC. PR66768 made IVOPTS bail out for all unknown-base-object addresses to protect named address spaces, but constant pointers in the default address space are safe. Without this hook, IVOPTS can't evaluate `TARGET_ADDRESS_COST` for these accesses and eliminates the destination IV, using expensive indexed addressing instead of separate IVs with autoincrement.

`TARGET_PREFERRED_RELOAD_CLASS_FOR_USE` (new) extends `TARGET_PREFERRED_RELOAD_CLASS` with use-context flags (`REG_USE_COMPARE`, `REG_USE_ARITH`, `REG_USE_MEM`) so IRA can make finer register class decisions per-use. On m68k, comparison operands prefer DATA_REGS (CMP.W is cheaper than CMPA.W on 68000).

`TARGET_IV_COMPARE_COST` (new) replaces the static `DOLOOP_COST_FOR_COMPARE` with a target hook, giving finer control over IV comparison costing in IVOPTS.

`TARGET_REGISTER_RENAME_PROFITABLE_P` (new) lets targets reject register renames that would create expensive instruction forms. On 68000, renaming a two-operand add (dest == source) into a three-operand form emits `lea (An,Xn),Am` which costs more than `move`+`add`.

The cost model is refactored with `base_cost[2]` arrays indexing word/long separately, `m68k_const_cost()` centralizing immediate constant costing, and IRA register class logic moved from `m68k.cc` to `m68k_costs.cc`.

**Hooks:** `TARGET_RTX_COSTS` (rewritten), `TARGET_ADDRESS_COST` (new), `TARGET_NEW_ADDRESS_PROFITABLE_P` (new), `TARGET_INSN_COST` (new), `TARGET_REGISTER_MOVE_COST` (new), `TARGET_MEMORY_MOVE_COST` (new), `TARGET_IVOPTS_ALLOW_CONST_PTR_ADDRESS_USE` (new), `TARGET_PREFERRED_RELOAD_CLASS_FOR_USE` (new), `TARGET_IV_COMPARE_COST` (new), `TARGET_REGISTER_RENAME_PROFITABLE_P` (new)

**Code:** `gcc/config/m68k/m68k.cc`, `gcc/config/m68k/m68k_costs.cc`, `gcc/tree-ssa-loop-ivopts.cc`, `gcc/ira-costs.cc`, `gcc/regrename.cc`, `gcc/target.def`

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

## 2. Register Allocation

Register allocation quality is critical on m68k, where the split register file (data `d0`–`d7` vs address `a0`–`a6`) means a value in the wrong class forces a copy before every use. These changes switch to the LRA allocator and improve IRA's register class decisions.

### LRA Register Allocator

GCC provides two register allocators that run after IRA's global allocation: **reload** (legacy, constraint-based patching) and **LRA** (Local Register Allocator, constraint-driven with iterative elimination). LRA has been GCC's default for most targets since GCC 5, but m68k was never switched — until now.

**Code:** `gcc/config/m68k/m68k.h` (`-mlra` Init(1)), `gcc/config/m68k/m68k.cc`, `gcc/config/m68k/m68k-pass-regalloc.cc`, `gcc/config/m68k/m68k.md`

### Disable

`-mno-lra` reverts to the legacy reload allocator.

### IRA Improvements

Several changes improve IRA's register allocation quality for the m68k register architecture. Pointer pseudos are promoted from DATA_REGS to ADDR_REGS when used as memory base addresses, with deeper analysis for LRA mode that traces pointer derivation chains. The `TARGET_REGISTER_MOVE_COST` hook penalizes DATA→ADDR moves, guiding IRA's graph coloring to prefer data registers for arithmetic values. A new IRA parameter deduplicates operand references to prevent frequency inflation.

IRA's hierarchical allocator merges parent and child allocnos when the child has zero references (pass-through), eliminating loop-boundary copies. A budget-based mechanism (`-fira-merge-passthrough`) limits how many pass-throughs are merged so that enough remain as cheap spill candidates when register pressure is high.

On 68000/68010, IRA promotion introduces a regression for NULL pointer checks: `tst.l` cannot operate on address registers, so the backend emits `cmp.w #0,%aN` (4 bytes, 12 cycles). A peephole2 fixes this by replacing the compare with `move.l %aN,%dN` (2 bytes, 4 cycles) when a scratch data register is available. The `move.l` sets CC identically to `cmp.w #0`, so the existing CC elision mechanism skips the subsequent `tst.l`. On 68020+ this is unnecessary since `tst.l %aN` is valid (2 bytes).

Disable promotion with: `-mno-m68k-ira-promote`

Disable pass-through merge with: `-fno-ira-merge-passthrough`

**Hooks:** `TARGET_IRA_CHANGE_PSEUDO_ALLOCNO_CLASS`

**Patterns:** `*cbranchsi4_areg_zero`, `*cbranchsi4_areg_zero_rev` (`define_insn`), address register zero test (`define_peephole2`)

**Code:** `gcc/config/m68k/m68k.cc` (`m68k_ira_change_pseudo_allocno_class()`), `gcc/config/m68k/m68k_costs.cc` (`m68k_register_move_cost_impl()`), `gcc/config/m68k/m68k.md`, `gcc/ira-build.cc`, `gcc/ira-color.cc`, `gcc/ira-int.h`, `gcc/common.opt`, `gcc/params.opt`

### How it works

**IRA promotion:** IRA assigns pseudo-registers to register classes based on instruction constraints. However, it sometimes assigns a pointer pseudo to DATA_REGS when address registers are under pressure. On m68k, data registers cannot be used as base registers in memory operands — any `(d3)` would require a `move.l d3,a0` copy first. The hook scans uses of each pseudo and forces address-register allocation when any use is inside a MEM operand.

**Constraint `*` fixes:** Several pre-existing `define_insn` patterns used `*` within a single constraint alternative (e.g. `"d*a"`, `"a*d"`), intending to discourage certain register classes. However, `preprocess_constraints()` ignores `*`, so the class unions to `GENERAL_REGS`, allowing `pass_regrename` (9.16) to rename between data and address registers. Fixed by splitting into separate alternatives: `"d*a"` → `"d,a"`. Affected patterns: `beq0_di`, movqi (both 68k and ColdFire), `ashldi_sexthi`. See [GCC_DEBUG.md §8](GCC_DEBUG.md#8-debugging-regrename).

**Address register zero test (68000/68010):** The peephole2 matches a `cbranchsi4_insn` comparing an address register against zero and adds a clobber, forming a `*cbranchsi4_areg_zero` insn. The output template first checks `m68k_find_flags_value()` — if CC is already valid for the address register (e.g., from a preceding `move.l %aN,<mem>`), the move is skipped entirely and only the branch is emitted. Otherwise, the template calls `output_move_simode` (which sets `flags_valid = FLAGS_VALID_MOVE` and `flags_operand1 = %dN`), then `m68k_output_compare_si` (which finds flags already valid and elides `tst.l`), then `m68k_output_branch_integer`. Net assembly: `move.l %aN,%dN; jCC label` (4 bytes) instead of `cmp.w #0,%aN; jCC label` (6 bytes), or just `jCC label` (2 bytes) when CC is already valid.

### Break False Dependency

When a pseudo is built from partial writes (`bfins` + `strict_low_part`) that collectively cover all 32 bits, dataflow treats each as read-modify-write. Via loop back-edges, the pseudo appears live across calls, forcing IRA to use callee-saved registers. This pass inserts a zero-cost clobber before the first partial write to break the false dependency. A cleanup pass removes the standalone clobbers after register allocation.

Disable with: `-mno-m68k-break-false-dep`

**Passes:** `m68k-break-false-dep` (new pre-IRA RTL pass), `m68k-break-false-dep-cleanup` (new post-RA RTL pass)

**Code:** `gcc/config/m68k/m68k-pass-regalloc.cc`

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

Register move cost (inner loop of `test_matrix_add` at O2):

```asm
; Before (DATA→ADDR cost=2): arithmetic temp allocated to address register
    move.l (%a1),%a2        ; load into ADDR reg
    add.l  %d1,%a2          ; add via addr reg (no CC flags)
    move.l %a2,(%a1)+       ; store back (extra movem.l save for a2)

; After (DATA→ADDR cost=3): IRA prefers data register
    move.l (%a1),%d0        ; load into DATA reg
    add.l  %d1,%d0          ; add sets CC flags
    move.l %d0,(%a1)+       ; store back (no extra save needed)
```

### Test cases

- `test_redundant_move()` — sum loop with pointer in correct register
- `test_loop_moves()` — cast-heavy pointer arithmetic stays in address register
- `test_null_ptr_loop()` — linked list NULL check uses `move.l` instead of `cmp.w #0` on 68000
- `test_areg_zero_elide()` — store sets CC for address register, `move.l aN,dN` elided
- `test_matrix_add()` — register move cost prevents arithmetic in address register
- `test_matrix_mul()` — improved register allocation with dedup
- `test_cm_matrix_mul_matrix_bitextract()` — nested loop register pressure with pass-through merge budget

---

## 3. Loop Optimization

Loops are the highest-value optimization target — even a single saved instruction per iteration multiplies across thousands of executions. These changes improve induction variable selection for auto-increment, enable `dbra` for counted loops, and optimize loop unrolling with jump-table remainder dispatch.

### Induction Variable Optimization

Improves induction variable selection for auto-increment addressing. When the target supports auto-increment, IV step costs are discounted to zero if the step matches a memory access size (1, 2, or 4 bytes). On m68k, the `addq.l #2,a0` that IVOPTS costs for each pointer IV is absorbed into `(a0)+` for free — the same reasoning GCC already applies to doloop decrements. Without this, IVOPTS prefers fewer IVs with indexed addressing over separate pointer IVs that benefit from post-increment.

Also prefers fewer IV registers when cost is equal, and avoids autoincrement in outer loops when the pointer is used in an inner loop.

Disable step discount with: `-fno-ivopts-autoinc-step`

**Pass:** `ivopts` (modified, `tree_ssa_iv_optimize()` in `gcc/tree-ssa-loop-ivopts.cc`)

**Code:** `gcc/tree-ssa-loop-ivopts.cc`

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
- `test_postinc_write()` — POST_INC placed on write instead of read


### Auto-Increment Multi-Use Candidate Generation

When a loop reads and writes through the same pointer (a multi-use address group), IVOPTS normally generates auto-increment candidates only for the first use. The placement of POST_INC then depends on internal use ordering, which varies between `-O2` (rotated loop) and `-Os`. With `-fivopts-autoinc-multiuse`, candidates are generated for the last use too. The cost model correctly costs non-ainc uses with displacement addressing, choosing the better placement — typically POST_INC on the write, since the read can use plain `(aN)` at zero cost.

Disable with: `-fno-ivopts-autoinc-multiuse`

**Pass:** `ivopts` (modified)

**Code:** `gcc/tree-ssa-loop-ivopts.cc`, `gcc/config/m68k/m68k.cc`

```c
void test_postinc_write(short *dst, unsigned int count, int (*p)(short)) {
    for (unsigned int i = 0; i < count; i++)
        dst[i] = p(dst[i]) ? i : 0;
}
```
```asm
; Before: POST_INC on read, negative offset for write
move.w  (%a2)+,%d0          ; read with POST_INC
...
move.w  %d0,-2(%a2)         ; write needs negative offset

; After (-fivopts-autoinc-multiuse): POST_INC on write
move.w  (%a2),%d0           ; read with plain addressing
...
move.w  %d0,(%a2)+          ; write with POST_INC
```


### DBRA Loop Optimization

Uses `dbra` for loop counters via GCC's doloop infrastructure. Value Range Propagation determines if the iteration count fits in 16 bits; when safe, the doloop pass narrows the counter to HImode to enable `dbra`. A preferred-mode fallback in `loop-doloop.cc` handles the common case where the loop IV is SImode (e.g. `long i`) but bounded by a 16-bit value: the pass tries `TARGET_PREFERRED_DOLOOP_MODE` (HImode) when the standard `word_mode` fallback fails. `TARGET_DOLOOP_MIN_ITERATIONS` (set to 1) ensures `dbra` is used even for small trip counts.

IVOPTS can transform count-down loops into pointer-comparison loops, preventing `dbra`. A new `TARGET_DOLOOP_COST_FOR_COMPARE` hook credits `dbra` in the IVOPTS cost model, keeping the counter IV for `dbra` over pointer comparison. For dynamic counts, `__builtin_assume()` can provide the range information needed.

To avoid high register pressure, `TARGET_PREDICT_DOLOOP_P` checks whether the exit IV has uses in the loop body beyond the exit test and its own increment. If it does, the doloop counter would be redundant — adding register pressure without benefit. An RTL-level safety net in the `doloop_end` expand checks whether the exit IV register still has body uses after IVOPTS (which may not have generated autoincrement), blocking `dbra` when it would cause spills.

The pre-existing `*dbne_hi`, `*dbne_si`, `*dbge_hi`, and `*dbge_si` patterns used `*` within a single constraint alternative (e.g. `"+d*g"`), which allowed `pass_regrename` (9.16) to rename the loop counter from a data register to an address register — breaking `dbra`. Fixed by splitting into separate alternatives: `"+d*g"` → `"+d,g"`. See [GCC_DEBUG.md §8](GCC_DEBUG.md#8-debugging-regrename).

Disable with: `-mno-m68k-doloop`

**Code:** `gcc/config/m68k/m68k-doloop.cc`, `gcc/config/m68k/m68k.cc`, `gcc/config/m68k/m68k.md`, `gcc/tree-ssa-loop-ivopts.cc`, `gcc/loop-doloop.cc`

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
- `test_dbra_matching_counter()` — SImode IV with `unsigned short` bound → preferred-mode fallback enables `dbra`
- `test_dbra_mixed_counter()` — mixed sizes prevent `dbra` (negative test)
- `test_doloop_const_small()` — small constant (100) → `dbra`
- `test_doloop_himode()` — `unsigned short` counter with `__builtin_unreachable` bound
- `test_doloop_simode_unbounded()` — unbounded `unsigned int` → no `dbra` (negative test)
- `test_doloop_const_large()` — 100000 iterations → no `dbra` (negative test)
- `test_matrix_add()` — nested loops, both using `dbra`
- `test_matrix_mul()` — matrix-vector multiply with `dbra` inner loop


### Loop Unrolling

`TARGET_PREFER_RUNTIME_UNROLL_TABLEJUMP` hook replaces the default compare cascade with a jump table, dispatching the remainder in constant time (~3 instructions + 2N bytes of data). Constant-iteration loops get their decrement copies consolidated into a single counter for `dbra`. Disables IV splitting so unrolled copies chain post-increments instead of using base+offset. Register renaming is enabled at -O2+ since m68k has no register encoding differences.

**Code:** `gcc/config/m68k/m68k.cc`, `gcc/loop-unroll.cc`, `gcc/loop-doloop.cc`

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

## 4. Memory Access Reordering

Reorders memory accesses through a base pointer to be sequential by offset, enabling store merging and post-increment addressing. Also normalizes constant-address bases so contiguous accesses to absolute addresses share a common base pointer. Verifies reordering safety using GCC's alias oracle. Runs before store-merging at `-O1` and above (including `-Os`).

A pre-RA pass (`m68k-reorder-incr`) performs two transformations: (1) moves pointer increment instructions past negative-offset memory accesses, adjusting offsets to be positive; (2) detects sequential base+offset memory accesses on the same hard register and synthesizes a `lea` to a pseudo with sequential offsets and an `addq` increment, enabling the downstream `opt_autoinc` pass to convert them to POST_INC. Combined insns with multiple MEMs at consecutive offsets (e.g., from `combine`) are split before conversion. Runs after scheduling, before IRA.

**Passes:** `m68k-reorder-mem` (new GIMPLE pass), `m68k-reorder-incr` (new pre-RA RTL pass)

Disable with: `-mno-m68k-reorder-mem` (reorder), `-mno-m68k-autoinc` (increment normalization)

**Code:** `gcc/config/m68k/m68k-pass-memreorder.cc`, `gcc/config/m68k/m68k-util.cc`

### Examples

Pointer-based reordering:

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

Constant-address normalization (unrolled copy to hardware registers):

```c
copyn(pal, 4, (short*)0xffff8258);
```
```asm
; Before: split bases prevent full merge
move.w  (%a0)+,$8258.w     ; stranded absolute store
move.w  #$825a,%a1
move.l  (%a0)+,(%a1)+      ; 2 stores merged
move.w  (%a0)+,(%a1)+

; After: common base enables 2x move.l
move.w  #$8258,%a1
move.l  (%a0)+,(%a1)+      ; stores 1+2 merged
move.l  (%a0)+,(%a1)+      ; stores 3+4 merged
```

Sequential access detection (stack clears followed by a function call and reads):

```c
struct large_struct { short a, b, c, d, e, f; };
int test_clear_and_read_struct(void(*f)(struct large_struct*)) {
    struct large_struct s = {};
    f(&s);
    return s.a + s.b + s.c + s.d + s.e + s.f;
}
```
```asm
; Before: base+offset addressing (no autoinc possible)
clr.w   (%sp)
clr.w   2(%sp)
clr.w   4(%sp)
...
move.w  (%sp),%d0
add.w   2(%sp),%d0
add.w   4(%sp),%d0
...

; After: reorder-incr synthesizes lea + sequential → opt_autoinc → POST_INC
lea     (%sp),%a0
clr.w   (%a0)+
clr.w   (%a0)+
clr.w   (%a0)+
...
lea     (%sp),%a0
move.w  (%a0)+,%d0
add.w   (%a0)+,%d0
add.w   (%a0)+,%d0
...
```

### Test cases

- `test_clear_struct_unorderred()` — out-of-order field clears → reordered → merged
- `test_clear_struct()` — already-ordered clears (no reorder needed, just merge)
- `test_fire_flicker_callback()` — unrolled copy to constant address → base normalization → full merge
- `test_clear_and_read_struct()` — sequential access detection → lea + POST_INC for both clears and reads

---

## 5. Autoincrement Optimization

Post-increment addressing (`(a0)+`) saves both an instruction and cycles by folding the pointer advance into the memory access. These passes convert indexed memory accesses to post-increment form, both within and across basic blocks, and clean up redundant copies left over from loop unrolling.

### Autoincrement Pass

Converts indexed memory accesses with incrementing offsets to post-increment addressing. Also works across basic block boundaries: when a load in a predecessor BB has its pointer incremented at the top of the fall-through BB, and the register is dead on the other edge, the pass combines them into post-increment. PRE self-loop edge splitting is suppressed (`--param=gcse-no-selfloop-split=1`) to keep tight loops in a single BB where auto-increment works naturally.

Two `define_peephole2` patterns recover POST_INC on read-modify-write instructions when `auto_inc_dec` cannot — the address register appears twice in RMW, preventing standard auto-increment detection. Pattern: `OP.x Dn,(An)` + `addq #size,An` → `OP.x Dn,(An)+`.

Two additional RTL passes handle cases where PRE and `pass_inc_dec` split load/modify/store across BBs, preventing combine from creating RMW instructions:

- `m68k-sink-for-rmw` sinks a hoisted load and duplicates the merge-block store into branch BBs, so combine can merge `load+modify+store` → `OP.x Dn,(An)+`.
- `m68k-sink-postinc` strips POST_INC from loads that PRE hoisted, inserting an explicit `addq` before the compensating-offset store. This lets `m68k-normalize-autoinc` merge the `addq` + offset store into a POST_INC store.

**Passes:** `m68k-autoinc-split` (new GIMPLE pass), `m68k-autoinc` (new pre-RA RTL pass), `m68k-normalize-autoinc` (new post-RA RTL pass), `m68k-sink-for-rmw` (new pre-RA RTL pass), `m68k-sink-postinc` (new post-RA RTL pass)

**Patterns:** RMW+POST_INC recovery (`define_peephole2`)

Disable with: `-mno-m68k-autoinc`

**Code:** `gcc/config/m68k/m68k-pass-autoinc.cc`, `gcc/config/m68k/m68k-util.cc`, `gcc/gcse.cc`, `gcc/config/m68k/m68k.md`

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
- `test_matrix_add()` — RMW+POST_INC recovery via peephole2


### Available Copy Elimination

Removes redundant register-to-register copies that are already established on all incoming paths. Primarily cleans up after `inc_dec`, which reintroduces copies in unrolled loop peels. Eliminating these before IRA allows the register allocator to coalesce registers.

Disable with: `-mno-m68k-avail-copy-elim`

**Pass:** `m68k-avail-copy-elim` (new RTL pass, runs after `inc_dec`)

**Code:** `gcc/config/m68k/m68k-pass-autoinc.cc`

### How it works

The pass performs a forward dataflow analysis tracking which register copies (`reg_A = reg_B`) are available at each program point. At basic block entries, it intersects the available copies from all predecessors. When it finds a copy instruction whose source-destination pair is already available (i.e., the copy is redundant), it deletes the instruction.

This is particularly effective for unrolled loops where each peel iteration has its own copy of the loop's register setup, but `inc_dec` has already merged the increments into post-increment addressing — making the separate copies redundant.

---

## 6. 16/32-bit Optimization

The m68k's word-oriented architecture means 16-bit operations are often cheaper than 32-bit equivalents, and upper register bits require explicit management. These passes narrow multiplications, hoist zero-extension operations, and optimize 16-bit value packing into 32-bit registers.

### Constant Narrowing

C integer promotion widens `short` operands to `int` before bitwise and shift operations. `forwprop`+`fold` narrows AND back but not shifts, OR, or XOR. This GIMPLE pass narrows the constants to match the truncation type, making entire operations narrow (e.g., 32-bit shift becomes 16-bit shift on `-mshort`).

Disable with: `-mno-m68k-narrow-const-ops`

**Pass:** `m68k-narrow-const-ops` (new GIMPLE pass, runs after `forwprop1`)

**Code:** `gcc/config/m68k/m68k-pass-shortopt.cc`

### Multiplication Optimization

Narrows 32-bit multiplications to 16-bit `muls.w` when operand ranges are known to fit, and removes redundant sign extension after 16-bit multiply since `muls.w` already produces a 32-bit signed result.

**Pass:** `m68k-narrow-index-mult` (new GIMPLE pass)

Disable with: `-mno-m68k-narrow-index-mult`

**Patterns:** `define_peephole2` for sign extension elimination

**Code:** `gcc/config/m68k/m68k-pass-shortopt.cc`, `gcc/config/m68k/m68k.md`

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


### ANDI Hoisting

Replaces `andi.l #mask` or `andi.w #mask` for zero-extension with a hoisted `moveq #0` and register moves. This also optimizes explicit masking operations. A peephole2 combines `andi.l #$ffff` + `clr.w` into a single `moveq #0`.

**Pass:** `m68k-elim-andi` (new RTL pass)

**Patterns:** `define_peephole2` for `andi.l #$ffff` + `clr.w` → `moveq #0`

Disable with: `-mno-m68k-elim-andi`

**Code:** `gcc/config/m68k/m68k-pass-shortopt.cc`, `gcc/config/m68k/m68k.md`

### How it works

On m68k, word (`.w`) and byte (`.b`) operations only modify the lower bits, leaving upper bits unchanged. When GCC needs a 32-bit value from a 16-bit operation, it generates `andi.l #65535` to zero-extend. This costs 6 bytes and 16 cycles on 68000.

The pass instead inserts `moveq #0,dN` before the register's first definition, pre-clearing the upper bits. Since subsequent `.w`/`.b` operations don't touch the upper bits, they remain zero — making the `andi` redundant.

**Constraint:** The pass must verify that no instruction between the `moveq #0` and the `andi` writes to bits wider than the extension width. A `muls.w` or `ext.l` would clobber the upper bits, invalidating the optimization.

**strict_low_part safety:** GCC's RTL treats `(set (reg:HI) ...)` as a full register write, so liveness-based passes (including sched2's fast DCE) see the hoisted `moveq #0` as dead — killed by the subsequent `.w` operation. To prevent this, the pass rewrites all intermediate sub-word operations between the `moveq` and the deleted `andi` to use `strict_low_part`, which tells GCC's dataflow that only the low bits are written and the upper bits are preserved. This allows the pass to run before sched2, where the 68060 scheduler can reorder the `moveq` for better pipelining.

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
- `test_clr_struct_arg()` — regression test: struct zero arg must clear all 32 bits, not just low word


### Word Packing

Improves code for packing 16-bit values into 32-bit registers. Folds `andi.l #$ffff` + `ori.l` sequences into `swap`+`move.w`+`swap`.

**Pass:** `m68k-highword-opt` (new RTL pass)

Disable with: `-mno-m68k-highword-opt`

**Patterns:** `define_peephole2` for andi/ori folding

**Code:** `gcc/config/m68k/m68k-pass-shortopt.cc`, `gcc/config/m68k/m68k.md`

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

## 7. Various Smaller Optimizations

Several independent optimizations that each target a specific code pattern: merging adjacent memory accesses, replacing shifts with constant-time bit tests, reordering loads for condition code tracking, and relaxing tail call restrictions under the fastcall ABI.

### Merge Peepholes

Combines adjacent small memory accesses into larger ones, and eliminates register intermediates in load+store+branch sequences by using mem-to-mem moves (68000 only).

**Patterns:** `define_peephole2` in machine description

**Code:** `gcc/config/m68k/m68k.md`

### Examples

```asm
; Before (word merge)           ; After
    move.w  #1,(a0)+                move.l  #$10002,(a0)+
    move.w  #2,(a0)+

; Before (mem-to-mem)           ; After (68000 only)
    move.b  (a1)+,d0                move.b  (a1)+,(a0)+
    move.b  d0,(a0)+                jne     .L
    jne     .L

; Before (RMW postinc)          ; After (68000 only)
    move.w  (a0),d1                 add.w   d0,(a0)+
    add.w   d0,d1
    move.w  d1,(a0)+
```

### Test cases

- `test_clear_struct()` — adjacent field clears merge into `clr.l`
- `test_clear_struct_unorderred()` — requires reordering (§4) before merge
- `test_clear_mixed_sizes()` — mixed-size clears
- `test_copyn_16()` — constant-count copy merges word moves to long


### Bit Extraction

Replaces shift+mask for single-bit extraction with `btst`+`sne` on 68000/68010. Shifts cost 6+2N cycles, while `btst` tests any bit in constant time. For unsigned extraction (result 0 or 1), `neg.b` converts the `sne` output from 0xFF to 0x01. For signed 1-bit fields, `sne` already produces the correct -1/0 result, saving one instruction. Disabled on 68020+ where `bfextu`/`bfexts` handle this natively.

Disable with: `-mno-m68k-btst-extract`

**Patterns:** `cstore_btst` `define_insn`, `*cbranchsi4_btst_shifted_hi` `define_insn`, `define_peephole2`

**Code:** `gcc/config/m68k/m68k.md`

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
- `test_put_pixel()` — `-mshort` shifted bit-test via `*cbranchsi4_btst_shifted_hi` pattern
- `test_bit_struct_active()` through `test_bit_struct_hidden()` — bitfield operations at various positions


### CC Reordering

On m68k, `move` sets CC. If the register tested by a branch is not the last one loaded, `final` must emit an explicit `tst`. This pass reorders loads so the tested register is loaded last, allowing `final` to elide the `tst`.

**Pass:** `m68k-reorder-cc` (new RTL pass)

**Code:** `gcc/config/m68k/m68k-pass-miscopt.cc`

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


### Bit Set Peepholes

Converts variable-position shift sequences to constant-time `bset` on 68000/68010 where `lsl`/`lsr` cost 8+2N cycles:

- `moveq #1` + `lsl.l Dn,Dm` → `moveq #0` + `bset Dn,Dm` (saves 2N cycles)
- HImode variant for `-mshort`: `moveq #1` + `lsl.w` → `moveq #0` + `bset` (widens to SImode for bset)
- `move #POW2` + `lsr.l Dn,Dm` → constant-time `bset` sequence (replaces 20+2N cycle shift)

**Patterns:** `define_peephole2` in machine description (guarded by `TUNE_68000_10`)

**Code:** `gcc/config/m68k/m68k.md`

### Tablejump Index Narrowing

Narrows SImode tablejump index to HImode when the table is small enough, enabling `.w` indexed loads instead of `.l`. This also narrows preceding scaling instructions (`add.l` → `add.w`, `ashift.l` → `ashift.w`), saving cycles on 68000 where word operations are cheaper.

**Patterns:** `define_insn_and_split` with `UNSPEC_TABLEJUMP_LOAD`

**Code:** `gcc/config/m68k/m68k.md`, `gcc/config/m68k/m68k.cc`

### Sibcall

Loosens restrictions on sibcall (tail call) optimization under the fastcall ABI. The stock backend conservatively disables sibcalls when parameter registers differ between caller and callee, but under fastcall many of these cases are safe because the arguments are already in the right registers or can be trivially rearranged.

**Code:** `gcc/config/m68k/m68k.cc`

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

## 8. 68040 Pipeline and 68060 Superscalar

The 68040 has a pipelined integer unit where back-to-back instructions that write and then read the same register stall the pipeline. The 68060 is superscalar with dual execution pipelines (pOEP + sOEP) that can execute two instructions per cycle when pairing rules are satisfied. These optimizations target each CPU's specific characteristics without affecting 68000/020/030 code generation.

### POST_INC Straight-Line Guard (68040)

On 68040, consecutive POST_INC accesses to the same address register cause a 1-cycle pipeline interlock per instruction — the address register writeback hasn't completed before the next instruction reads it. Offset addressing (base+displacement) avoids the stall. The 68060 does not stall here — POST_INC is a zero-stall producer on 68060 (MC68060UM §4.2), and dual-issue is already impossible for consecutive memory ops (dispatch test 4: at most one data access per pair).

The `opt_autoinc` pass skips the POST_INC conversion on 68040 when all fixup instructions are immediately consecutive with no intervening work, identifying straight-line memory sequences. Loop autoincrements are unaffected — the loop body provides enough separation between iterations.

```asm
; 68040 without guard: 4 pipeline stalls (3 inter-instruction)
    clr.l   (%a0)+          ; writeback to a0
    clr.l   (%a0)+          ; stall: a0 not ready
    clr.l   (%a0)+          ; stall
    clr.l   (%a0)+          ; stall

; 68040 with guard: offset addressing, no stalls
    clr.l   (%a0)
    clr.l   4(%a0)
    clr.l   8(%a0)
    clr.l   12(%a0)
```

**Code:** `gcc/config/m68k/m68k-pass-autoinc.cc`

### Immediate ALU Operands (68040+)

On 68000, `and.l #7,%d0` costs 16 cycles (4-byte immediate fetched over the slow bus). Loading the constant into a register first — `moveq #7,%d1` + `and.l %d1,%d0` = 12 cycles — is faster. The `andsi3_internal`, `iorsi3_internal`, and `addsi3_internal` patterns exclude moveq-range constants from the immediate constraint, forcing them into registers. This is correct for 68000 but counterproductive on 68040+, where instruction cache makes immediate fetch free: `and.l #7,%d0` = 1 cycle vs `moveq #7,%d1` + `and.l %d1,%d0` = 3 cycles (data dependency stall).

A new constraint `Cp` matches any `const_int` when `TUNE_68040_60`, allowing the immediate form on pipelined CPUs. On 68000/020/030, `Cp` never matches — behavior unchanged.

```asm
; 68040 before: moveq adds dependency stall
    moveq   #7,%d1          ; 1 cycle
    and.l   %d1,%d0         ; 2 cycles (stall on d1)

; 68040 after: immediate form, no dependency
    and.l   #7,%d0          ; 1 cycle
```

**Patterns:** `Cp` constraint in `andsi3_internal`, `iorsi3_internal`, `addsi3_internal`

**Code:** `gcc/config/m68k/constraints.md`, `gcc/config/m68k/m68k.md`

### 68060 Scheduling Automaton

A new scheduling description (`m68060.md`) models the 68060's dual-issue pipelines so GCC's `sched2` pass can reorder post-RA instructions to maximize pairing. The automaton defines two CPU units — `m68060_pOEP` (primary) and `m68060_sOEP` (secondary) — plus a `m68060_mem` unit enforcing the one-memory-access-per-pair constraint (dispatch test 4).

Instruction reservations classify each insn type by its superscalar dispatch class:

- **`pOEP|sOEP`** (register-only ALU, moves, compares, shifts, `clr`, `tst`, `lea`, `moveq`, `ext`): can execute in either pipeline. With no memory access, two such instructions pair freely. With one memory access, pairing still works via the memory unit.
- **`pOEP|sOEP` with indexed EA or RMW**: forced to single-issue because sOEP rejects indexed/base-displacement addressing (dispatch test 3).
- **`pOEP-only`** (multiply, divide, branches, `dbra`, bit ops, `link`/`unlk`): block the sOEP entirely.
- **`pOEP-but-allows-sOEP`** (`Scc`, `Bcc`): occupy pOEP but leave sOEP open for a `pOEP|sOEP` instruction.
- **FPU** instructions: occupy pOEP but allow integer sOEP pairing, enabling FPU/integer overlap.

The issue rate is 2 for 68060 (`m68k_sched_issue_rate`), enabling the scheduler's multi-issue logic. The scheduler uses the automaton to determine which instruction pairs can dispatch simultaneously, reordering within basic blocks to place pairable instructions adjacent.

Only `sched2` (post-RA) is enabled — `sched1` (pre-RA) is disabled because it would separate loads from address increments before `auto_inc_dec` has a chance to form POST_INC patterns.

Scheduling is enabled automatically when tuning for 68060 (`-m68060`). The `-msched=` option allows enabling 68060 scheduling independently of the tuning target (e.g., `-m68040 -msched=68060`).

**Code:** `gcc/config/m68k/m68060.md`, `gcc/config/m68k/m68k.cc`, `gcc/config/m68k/m68k.opt`

### Superscalar-Aware Cost Model (68060)

The 68060 cost table inflates indexed addressing costs (`MEM_INDEX`: 5-6 vs `MEM_REG`: 2) to reflect the real-world superscalar penalty: indexed modes force `pOEP-only` dispatch (dispatch test 3), preventing dual-issue and halving throughput in loop bodies where simple modes would allow pairing. This guides IVOPTS to prefer separate pointer IVs with `(a0)+` over fewer IVs with `(a0,d0.l)`. LEA carries no penalty on 68060 (it is `pOEP|sOEP`), unlike 68000 where `lea (An,Dn.l),Am` is expensive.

**Code:** `gcc/config/m68k/m68k_costs.cc`

### Loop Header Copying at -Os

GCC's `ch` (copy headers) pass rotates while-style loops into do-while form by duplicating the loop header before the loop entry. Stock GCC disables this at `-Os` (zero insns allowed). A new parameter `--param=max-loop-header-insns-for-size` (default 0) makes this configurable. The default of 0 allows rotation of simple loops where the header contains only the exit condition (no extra instructions to duplicate), enabling `dbra` at the loop bottom without code size increase.

**Code:** `gcc/tree-ssa-loop-ch.cc`, `gcc/params.opt`

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

1. **Induction Variable (§3):** IVOPTS selects separate pointer IVs instead of a single integer counter, enabling post-increment
2. **Autoincrement Pass (§5):** Converts `(a0,d2.l)` indexed addressing to `(a0)+` post-increment
3. **IRA Register Class (§2):** Keeps pointers in address registers, avoiding `move.l dN,aM` copies

**Result:** 43% faster, 30% smaller code.

---

## Appendix B: Known Missing Optimizations

The following optimizations are not yet implemented but would further improve m68k code generation. A comprehensive analysis is in [notes/remaining-inefficiencies.md](notes/remaining-inefficiencies.md).

### B.1 Residual `and.l #65535` After Word Operations

The ANDI hoisting pass (§6) handles single-BB cases well, but several patterns remain:

- **Cross-BB duplication:** When both branches of a conditional end with `and.l #65535` (e.g., `test_cross_bb_cond`), hoisting `moveq #0` before the branch point would eliminate both.
- **Sequential word ops:** `subq.w` after a `move.w` load re-dirties bits 16-31, requiring a second `and.l #65535` that the backward scan does not eliminate because it stops at the word operation.
- **MODIFIES_WORD barrier:** The backward scan stops at `add.w` even when an earlier `clr.w` could be widened to `moveq #0`.

### B.2 Redundant TST Elimination

The m68k `move` instruction sets condition codes, but GCC often generates redundant `tst` instructions before branches. The `m68k-reorder-cc` pass (§7) addresses the common case where loads can be reordered so the tested register is loaded last, but the general case — where `move` and branch are separated by register allocation or instruction scheduling — remains.

### B.3 32-bit Loop Down-Counting

When `int` is 32 bits, GCC generates up-counting loops with three loop-control instructions (`addq.l #1 / cmp.l / jne`) instead of the optimal two (`subq.l #1 / jne`). This is GCC's internal loop canonicalization choosing an up-counting IV — the m68k backend has no hook to influence this choice. Affects 6+ functions at O2 without `-mshort`. The `-mshort` variants avoid this entirely because 16-bit counters use `dbra`.

### B.4 Read-Modify-Write with Auto-Increment (RESOLVED)

Resolved in §7 Merge Peepholes (`5713692f644`) and §5 Autoincrement (`9daff73b8e0`). Added `define_insn` and `define_peephole2` patterns for `add/sub/and/or/eor.x dN,(aN)+`.

### B.5 16-bit Register Spills

**Spill slot sizing:** LRA widens HImode/QImode spill slots to SImode. A `TARGET_LRA_SPILL_SLOT_MODE` hook could give narrow pseudos narrow stack slots, reducing frame size.

**Swap-based spill replacement** was investigated and rejected. A prototype pass tested against all of libcmini produced zero matches — the RA spills for width (not pressure), m68k has enough registers, and cross-BB reloads use different registers.

### B.6 Dead Zero-Extension Elimination (Forward Scan)

When an `andi.l #65535` zero-extends a register that is only used in HImode afterwards (e.g., as a `dbra` counter), the andi is dead — the upper bits are never read. A forward-scan pass was prototyped that follows the register through successor BBs via a worklist, checking `df_get_live_out` / `df_get_live_in` to determine if all uses are narrow.

The approach proved **too fragile for production use**:

- GCC's RTL uses `(subreg:SI (reg:HI N) 0)` to widen a narrow register to SImode. The inner `(reg:HI)` fools the mode check into thinking the use is narrow, when the outer subreg reads all 32 bits.
- Cross-BB analysis via DF live bitmaps does not carry mode information — a register marked live-out could be used in any mode by successors.
- Multiple edge cases caused miscompilation in real-world code: `lsl.l` reading all 32 bits through a same-register redef, address-register sources in `movstrict` patterns, function call return values.

A correct implementation would require **DU-chain analysis** (`df_chain_add_problem(DF_DU_CHAIN)`) to enumerate every use of the andi's output and check each one's mode, rather than walking BBs and inferring from liveness bitmaps. The `ext-dce` pass (`gcc/ext-dce.cc`) solves a related problem with per-bit-group liveness tracking and could serve as a model.
