# m68k Backend Optimizations

Since GCC 3, the m68k backend has received little attention while the rest of the compiler infrastructure has evolved significantly. The result is that GCC often generates surprisingly poor code for m68k: inefficient memory access patterns that ignore post-increment addressing, loops that barely ever use `dbra`, and wasteful instruction sequences that a human would never write.

The optimizations in this branch aim to address some of the most glaring missed opportunities.

My target machine is a 68000 with `-mshort` and `-mfastcall`, so that configuration has received the most testing and attention. Many of these optimizations also benefit 32-bit int mode and 68020+, but that is more by luck than deliberate effort—I have only verified that those configurations do not regress.

## 1. RTX and Address Cost Calculations

Rewritten cost model using lookup tables with actual cycle counts per CPU generation (68000, 68020-030, 68040+), inspired by Bebbo's gcc6 work. `TARGET_ADDRESS_COST` distinguishes per-mode costs, `TARGET_NEW_ADDRESS_PROFITABLE_P` prevents replacing post-increment with indexed addressing, and `TARGET_INSN_COST` costs whole instructions including memory destinations — non-RMW compound operations are costed additively to prevent combine from folding IVs into base+offset form.

**Hooks:** `TARGET_RTX_COSTS` (rewritten), `TARGET_ADDRESS_COST` (new), `TARGET_NEW_ADDRESS_PROFITABLE_P` (new), `TARGET_INSN_COST` (new)

**Code:** `gcc/config/m68k/m68k.cc`, `gcc/config/m68k/m68k_costs.cc`

## 2. Induction Variable Optimization

Discounts IV step costs to zero when the step matches a memory access size (1, 2, or 4 bytes), so IVOPTS prefers separate pointer IVs that benefit from post-increment over fewer IVs with indexed addressing. Also prefers fewer IV registers when cost is equal, and avoids autoincrement in outer loops.

Disable step discount with: `-fno-ivopts-autoinc-step`

**Pass:** `ivopts` (modified)

**Code:** `gcc/tree-ssa-loop-ivopts.cc`

## 3. Autoincrement Optimization Pass

Converts indexed memory accesses with incrementing offsets to post-increment addressing, both within and across basic blocks. PRE self-loop edge splitting is suppressed to keep tight loops in a single BB where auto-increment works naturally.

Disable with: `-mno-m68k-autoinc`

**Passes:** `m68k-autoinc-split` (new GIMPLE pass), `m68k-autoinc` (new RTL pass), `m68k-normalize-autoinc` (new RTL pass)

**Code:** `gcc/config/m68k/m68k-gimple-passes.cc`, `gcc/config/m68k/m68k-rtl-passes.cc`, `gcc/gcse.cc`

## 4. Memory Access Merge Peepholes

Combines adjacent small memory accesses into larger ones (e.g. two `move.w` into one `move.l`), and eliminates register intermediates in load+store+branch sequences by using mem-to-mem moves (68000 only).

**Patterns:** `define_peephole2` in machine description

**Code:** `gcc/config/m68k/m68k.md`

## 5. DBRA Loop Optimization

Uses `dbra` for loop counters via GCC's doloop infrastructure. VRP determines if the counter fits in 16 bits; when safe, 32-bit counters are narrowed. A new `TARGET_DOLOOP_COST_FOR_COMPARE` hook credits `dbra` in the IVOPTS cost model, keeping the counter IV over pointer comparison. For dynamic counts, `__builtin_assume()` provides range information.

Disable with: `-mno-m68k-doloop`

**Code:** `gcc/config/m68k/m68k.cc`, `gcc/config/m68k/m68k.md`, `gcc/tree-ssa-loop-ivopts.cc`

## 6. Multiplication Optimization

Narrows 32-bit multiplications to 16-bit `muls.w` when operand ranges are known to fit (avoiding a library call on 68000), and removes redundant sign extension after 16-bit multiply since `muls.w` already produces a 32-bit signed result.

Disable with: `-mno-m68k-narrow-index-mult`

**Pass:** `m68k-narrow-index-mult` (new GIMPLE pass)

**Patterns:** `define_peephole2` for sign extension elimination

**Code:** `gcc/config/m68k/m68k-gimple-passes.cc`, `gcc/config/m68k/m68k.md`

## 7. ANDI Hoisting

Replaces repeated `andi.l #mask` for zero-extension with a hoisted `moveq #0` and register moves. The `moveq` is placed outside the loop, and each zero-extension becomes a simple `move.b` into the pre-cleared register.

Disable with: `-mno-m68k-elim-andi`

**Pass:** `m68k-elim-andi` (new RTL pass)

**Code:** `gcc/config/m68k/m68k-rtl-passes.cc`

## 8. Word Packing and Insert Patterns

Improves code for packing 16-bit values into 32-bit registers. Folds `andi.l #$ffff` + `ori.l` sequences into `swap`+`move.w`+`swap`, and optimizes struct return of two short fields.

Disable with: `-mno-m68k-highword-opt`

**Pass:** `m68k-highword-opt` (new RTL pass)

**Patterns:** `define_peephole2` for andi/ori folding

**Code:** `gcc/config/m68k/m68k-rtl-passes.cc`, `gcc/config/m68k/m68k.md`

## 9. IRA Register Class Promotion

Promotes pointer pseudos from DATA_REGS to ADDR_REGS when used as memory base addresses. Without this, IRA may allocate pointers to data registers, requiring expensive register-to-register moves on every memory access.

Disable with: `-mno-m68k-ira-promote`

**Hook:** `TARGET_IRA_CHANGE_PSEUDO_ALLOCNO_CLASS`

**Code:** `gcc/config/m68k/m68k.cc`

## 10. Improved Loop Unrolling

`TARGET_PREFER_RUNTIME_UNROLL_TABLEJUMP` replaces the default compare cascade with a jump table for remainder dispatch. Constant-iteration loops consolidate decrement copies into a single `dbra` counter. IV splitting is disabled so unrolled copies chain post-increments.

**Code:** `gcc/config/m68k/m68k.cc`, `gcc/loop-unroll.cc`, `gcc/loop-doloop.cc`

## 11. Memory Access Reordering

Reorders memory accesses through a base pointer to be sequential by offset, enabling store merging and post-increment addressing. Verifies safety using GCC's alias oracle. Runs before store-merging.

Disable with: `-mno-m68k-reorder-mem`

**Pass:** `m68k-reorder-mem` (new GIMPLE pass)

**Code:** `gcc/config/m68k/m68k-gimple-passes.cc`

## 12. Single-Bit Extraction

Replaces shift+mask for single-bit extraction with `btst`+`sne` on 68000/68010. Shifts cost 6+2N cycles while `btst` is constant time. For unsigned results, `neg.b` converts `sne` to 0/1; for signed 1-bit fields, `sne` produces -1/0 directly. Disabled on 68020+ where `bfextu`/`bfexts` handle this.

Disable with: `-mno-m68k-btst-extract`

**Patterns:** `cstore_btst` `define_insn`, `define_peephole2`

**Code:** `gcc/config/m68k/m68k.md`

## 13. Available Copy Elimination

Removes redundant register-to-register copies that are already established on all incoming paths. Primarily cleans up after `inc_dec`, which reintroduces copies in unrolled loop peels.

Disable with: `-mno-m68k-avail-copy-elim`

**Pass:** `m68k-avail-copy-elim` (new RTL pass, runs after `inc_dec`)

**Code:** `gcc/config/m68k/m68k-rtl-passes.cc`

## 14. Load Reordering for CC Tracking

On m68k, `move` sets CC. If the register tested by a branch is not the last one loaded, `final` must emit an explicit `tst`. This pass reorders loads so the tested register is loaded last, eliding the `tst`.

**Pass:** `m68k-reorder-cc` (new RTL pass)

**Code:** `gcc/config/m68k/m68k-rtl-passes.cc`

## 15. Sibcall Optimization

Loosens restrictions on sibcall (tail call) optimization under the fastcall ABI. The stock backend conservatively disables sibcalls when parameter registers differ, but under fastcall many cases are safe.

**Code:** `gcc/config/m68k/m68k.cc`

## Appendix A: libcmini Real-World Example

`memcmp` from libcmini compiled with `-Os -mshort -mfastcall`:

```asm
; Post-increment addressing (32 cycles/byte, 28 bytes)
.loop:  move.b  (a0)+,d0
        move.b  (a1)+,d1
        cmp.b   d0,d1
        beq.s   .check
```

**Optimizations applied:**

1. **Induction Variable (§2):** IVOPTS selects separate pointer IVs instead of a single integer counter
2. **Autoincrement Pass (§3):** Converts indexed `(a0,d2.l)` to post-increment `(a0)+`
3. **IRA Register Class (§9):** Keeps pointers in address registers

**Result:** 43% faster, 30% smaller code vs stock GCC 15.
