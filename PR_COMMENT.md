# m68k Backend Optimizations

The m68k backend has received little attention since GCC 3. These optimizations address inefficient memory access patterns, underused `dbra` loops, and wasteful instruction sequences. Primary target: 68000 with `-mshort -mfastcall`; 32-bit int and 68020+ verified not to regress.

## 1. RTX and Address Cost Calculations

Rewritten cost model with actual cycle counts per CPU generation (68000, 68020-030, 68040+). `TARGET_ADDRESS_COST` distinguishes per-mode costs, `TARGET_NEW_ADDRESS_PROFITABLE_P` prevents replacing post-increment with indexed addressing, `TARGET_INSN_COST` costs whole instructions including memory destinations.

**Hooks:** `TARGET_RTX_COSTS` (rewritten), `TARGET_ADDRESS_COST` (new), `TARGET_NEW_ADDRESS_PROFITABLE_P` (new), `TARGET_INSN_COST` (new)

**Code:** `gcc/config/m68k/m68k.cc`, `gcc/config/m68k/m68k_costs.cc`

## 2. Induction Variable Optimization

Discounts IV step costs to zero when the step matches a memory access size, so IVOPTS prefers separate pointer IVs with post-increment over fewer IVs with indexed addressing. Also prefers fewer IV registers when cost is equal.

Disable step discount with: `-fno-ivopts-autoinc-step`

**Pass:** `ivopts` (modified)

**Code:** `gcc/tree-ssa-loop-ivopts.cc`

## 3. Autoincrement Optimization Pass

Converts indexed memory accesses with incrementing offsets to post-increment addressing, both within and across basic blocks. Suppresses PRE self-loop edge splitting to keep tight loops in a single BB. All POST_INC creation points validate with `constrain_operands(1)` after `recog_memoized()`, since predicates accept POST_INC but constraint letters may not (e.g. `extendsidi2` allows `<` but not `>`).

Disable with: `-mno-m68k-autoinc`

**Passes:** `m68k-autoinc-split` (new GIMPLE pass), `m68k-autoinc` (new RTL pass), `m68k-normalize-autoinc` (new RTL pass)

**Code:** `gcc/config/m68k/m68k-gimple-passes.cc`, `gcc/config/m68k/m68k-rtl-passes.cc`, `gcc/gcse.cc`

## 4. Memory Access Merge Peepholes

Combines adjacent small memory accesses into larger ones (e.g. two `move.w` into one `move.l`), and eliminates register intermediates in load+store+branch sequences by using mem-to-mem moves (68000 only).

**Patterns:** `define_peephole2` in machine description

**Code:** `gcc/config/m68k/m68k.md`

## 5. DBRA Loop Optimization

Uses `dbra` for loop counters via GCC's doloop infrastructure. VRP determines if the counter fits in 16 bits; when safe, 32-bit counters are narrowed. `TARGET_DOLOOP_COST_FOR_COMPARE` credits `dbra` in the IVOPTS cost model.

Disable with: `-mno-m68k-doloop`

**Code:** `gcc/config/m68k/m68k.cc`, `gcc/config/m68k/m68k.md`, `gcc/tree-ssa-loop-ivopts.cc`

## 6. Multiplication Optimization

Narrows 32-bit multiplications to 16-bit `muls.w` when operand ranges are known to fit (avoiding a library call on 68000), and removes redundant sign extension after 16-bit multiply since `muls.w` already produces a 32-bit signed result.

Disable with: `-mno-m68k-narrow-index-mult`

**Pass:** `m68k-narrow-index-mult` (new GIMPLE pass)

**Patterns:** `define_peephole2` for sign extension elimination

**Code:** `gcc/config/m68k/m68k-gimple-passes.cc`, `gcc/config/m68k/m68k.md`

## 7. ANDI Hoisting

Replaces repeated `andi.l #mask` for zero-extension with a hoisted `moveq #0` and register moves. The `moveq` is placed outside the loop, and each zero-extension becomes a simple `move.b` into the pre-cleared register. Also handles `clr.w`+`move.b` sequences (widen `clr.w` to `moveq #0`) and widens `and.w #N` to `and.l #N` when that eliminates a later `andi.l #65535`. A peephole2 combines `andi.l #$ffff` + `clr.w` into a single `moveq #0` for struct zeroing patterns.

Disable with: `-mno-m68k-elim-andi`

**Pass:** `m68k-elim-andi` (new RTL pass)

**Patterns:** `define_peephole2` for `andi.l #$ffff` + `clr.w` → `moveq #0`

**Code:** `gcc/config/m68k/m68k-rtl-passes.cc`, `gcc/config/m68k/m68k.md`

## 8. Word Packing and Insert Patterns

Improves code for packing 16-bit values into 32-bit registers. Folds `andi.l #$ffff` + `ori.l` sequences into `swap`+`move.w`+`swap`, and optimizes struct return of two short fields.

Disable with: `-mno-m68k-highword-opt`

**Pass:** `m68k-highword-opt` (new RTL pass)

**Patterns:** `define_peephole2` for andi/ori folding

**Code:** `gcc/config/m68k/m68k-rtl-passes.cc`, `gcc/config/m68k/m68k.md`

## 9. IRA Register Allocation Improvements

Promotes pointer pseudos from DATA_REGS to ADDR_REGS when used as memory base addresses. Extended with deeper pointer-derivation analysis for LRA mode (`pseudo_pointer_derived_p`, `pseudo_only_addr_ops_p`), disabled on ColdFire where it causes LRA to corrupt the dominator tree. `TARGET_REGISTER_MOVE_COST` penalizes DATA→ADDR moves, guiding IRA to prefer data registers for arithmetic. IRA duplicate use dedup prevents frequency inflation from `add.w %dN,%dN`. On 68000/68010, a peephole2 fixes the NULL-check regression with CC elision.

Budget-based pass-through merge (`-fira-merge-passthrough`, default on for m68k): in IRA's hierarchical allocator, pass-through allocnos (zero refs at child loop level) are merged with their parent to eliminate loop-boundary copies, but limited by a budget so enough remain as cheap spill candidates under register pressure.

Disable promotion with: `-mno-m68k-ira-promote`

Disable pass-through merge with: `-fno-ira-merge-passthrough`

**Hooks:** `TARGET_IRA_CHANGE_PSEUDO_ALLOCNO_CLASS`, `TARGET_REGISTER_MOVE_COST`

**Patterns:** `*cbranchsi4_areg_zero` (`define_insn`), address register zero test (`define_peephole2`)

**Code:** `gcc/config/m68k/m68k.cc`, `gcc/config/m68k/m68k_costs.cc`, `gcc/config/m68k/m68k.md`, `gcc/ira-build.cc`, `gcc/ira-color.cc`, `gcc/common.opt`

## 10. Improved Loop Unrolling

`TARGET_PREFER_RUNTIME_UNROLL_TABLEJUMP` replaces the compare cascade with a jump table for remainder dispatch. Constant-iteration loops consolidate decrement copies into a single `dbra` counter.

**Code:** `gcc/config/m68k/m68k.cc`, `gcc/loop-unroll.cc`, `gcc/loop-doloop.cc`

## 11. Memory Access Reordering

Reorders memory accesses through a base pointer to be sequential by offset, enabling store merging and post-increment addressing. Verifies safety using GCC's alias oracle. Runs before store-merging.

Disable with: `-mno-m68k-reorder-mem`

**Pass:** `m68k-reorder-mem` (new GIMPLE pass)

**Code:** `gcc/config/m68k/m68k-gimple-passes.cc`

## 12. Single-Bit Extraction

Replaces shift+mask for single-bit extraction with `btst`+`sne` on 68000/68010. Shifts cost 6+2N cycles while `btst` is constant time. For unsigned results, `neg.b` converts `sne` to 0/1. Disabled on 68020+ where `bfextu`/`bfexts` handle this.

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

## 16. LRA Register Allocator

Switched m68k to LRA (Local Register Allocator) as default, replacing legacy reload. Fire Flight binary reduced by 1126 bytes (1.6%). Added `m68k_pass_canon_scaled_index` to rewrite 3-register scaled index addresses for LRA, `UNSPEC_TABLEJUMP_LOAD` to avoid constraint conflicts in casesi, and tightened mulhi3 constraints.

Fixed an ICE on 68000/ColdFire where indexed `(d8,An,Xn)` displacement exceeds 8-bit limit after fp elimination. Two `define_insn_and_split` patterns emit a single LEA when in range, or split into two instructions post-reload.

Disable with: `-mno-lra`

**Pass:** `m68k-canon-scaled-index` (new RTL pass)

**Hooks:** `TARGET_LRA_P`

**Patterns:** `*lea_indexed_disp_scaled`, `*lea_indexed_disp` (`define_insn_and_split`)

**Code:** `gcc/config/m68k/m68k.h`, `gcc/config/m68k/m68k.cc`, `gcc/config/m68k/m68k-rtl-passes.cc`, `gcc/config/m68k/m68k.md`

## Appendix A: libcmini Real-World Example

`memcmp` from libcmini (`-Os -mshort -mfastcall`): §2 (IVOPTS) selects separate pointer IVs, §3 (autoinc) converts to `(a0)+`, §9 (IRA) keeps pointers in address registers. Result: 43% faster, 30% smaller vs stock GCC 15.
