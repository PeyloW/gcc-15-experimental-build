# m68k Backend Optimizations

The m68k backend has received little attention since GCC 3. These optimizations address inefficient memory access patterns, underused `dbra` loops, and wasteful instruction sequences. Primary target: 68000 with `-mshort -mfastcall`; 32-bit int and 68020+ verified not to regress.

## 1. Cost Model

Rewritten cost model with actual cycle counts per CPU generation (68000, 68020-030, 68040+). `TARGET_ADDRESS_COST` distinguishes per-mode costs, `TARGET_NEW_ADDRESS_PROFITABLE_P` prevents replacing post-increment with indexed addressing, `TARGET_INSN_COST` costs whole instructions including memory destinations.

New target hooks: `TARGET_IVOPTS_ALLOW_CONST_PTR_ADDRESS_USE` (IVOPTS constant-pointer IV classification), `TARGET_PREFERRED_RELOAD_CLASS_FOR_USE` (use-context IRA class), `TARGET_IV_COMPARE_COST` (IV comparison cost), `TARGET_REGISTER_RENAME_PROFITABLE_P` (reject costly renames).

**Hooks:** `TARGET_RTX_COSTS`, `TARGET_ADDRESS_COST`, `TARGET_NEW_ADDRESS_PROFITABLE_P`, `TARGET_INSN_COST`, `TARGET_REGISTER_MOVE_COST`, `TARGET_MEMORY_MOVE_COST`, `TARGET_IVOPTS_ALLOW_CONST_PTR_ADDRESS_USE`, `TARGET_PREFERRED_RELOAD_CLASS_FOR_USE`, `TARGET_IV_COMPARE_COST`, `TARGET_REGISTER_RENAME_PROFITABLE_P`

**Code:** `gcc/config/m68k/m68k.cc`, `gcc/config/m68k/m68k_costs.cc`, `gcc/tree-ssa-loop-ivopts.cc`, `gcc/ira-costs.cc`, `gcc/regrename.cc`

## 2. Register Allocation

Register allocation improvements: LRA as default allocator and better IRA register class decisions.

### LRA Register Allocator

Switched m68k to LRA as default, replacing legacy reload. Added `m68k_pass_canon_scaled_index` for LRA-compatible scaled index addresses.

Disable with: `-mno-lra`

**Pass:** `m68k-canon-scaled-index` (new RTL pass)

**Hooks:** `TARGET_LRA_P`

**Patterns:** `*lea_indexed_disp_scaled`, `*lea_indexed_disp` (`define_insn_and_split`)

**Code:** `gcc/config/m68k/m68k.h`, `gcc/config/m68k/m68k.cc`, `gcc/config/m68k/m68k-pass-regalloc.cc`, `gcc/config/m68k/m68k.md`

### IRA Improvements

Promotes pointer pseudos to ADDR_REGS when used as memory base addresses. Penalizes DATA→ADDR moves. Peephole2 fixes 68000 NULL-check regression with CC elision. Fixed constraint `*` to prevent regrename from widening classes. Budget-based pass-through merge eliminates loop-boundary copies. Breaks false partial-write live ranges before IRA.

Disable with: `-mno-m68k-ira-promote`, `-fno-ira-merge-passthrough`, `-mno-m68k-break-false-dep`

**Hooks:** `TARGET_IRA_CHANGE_PSEUDO_ALLOCNO_CLASS`

**Passes:** `m68k-break-false-dep` (new pre-IRA RTL pass), `m68k-break-false-dep-cleanup` (new post-RA RTL pass)

**Patterns:** `*cbranchsi4_areg_zero` (`define_insn`), address register zero test (`define_peephole2`)

**Code:** `gcc/config/m68k/m68k.cc`, `gcc/config/m68k/m68k_costs.cc`, `gcc/config/m68k/m68k-pass-regalloc.cc`, `gcc/config/m68k/m68k.md`, `gcc/ira-build.cc`, `gcc/ira-color.cc`, `gcc/common.opt`

## 3. Loop Optimization

Induction variable selection, `dbra` loop counter, and jump-table loop unrolling.

### Induction Variable Optimization

Discounts IV step costs to zero when step matches memory access size, preferring separate pointer IVs with post-increment. `-fivopts-autoinc-multiuse` generates autoinc candidates for the last use too, placing POST_INC on writes.

Disable step discount with: `-fno-ivopts-autoinc-step`

**Pass:** `ivopts` (modified)

**Code:** `gcc/tree-ssa-loop-ivopts.cc`

### DBRA Loop Optimization

Uses `dbra` for loop counters via GCC's doloop infrastructure. VRP + preferred-mode fallback narrows counters to HImode. `TARGET_IV_COMPARE_COST` credits `dbra` in IVOPTS. `TARGET_PREDICT_DOLOOP_P` checks exit IV body uses. Fixed constraint `*` in `*dbne`/`*dbge` patterns.

Disable with: `-mno-m68k-doloop`

**Code:** `gcc/config/m68k/m68k-doloop.cc`, `gcc/config/m68k/m68k.cc`, `gcc/config/m68k/m68k.md`, `gcc/tree-ssa-loop-ivopts.cc`, `gcc/loop-doloop.cc`

### Loop Unrolling

`TARGET_PREFER_RUNTIME_UNROLL_TABLEJUMP` replaces the compare cascade with a jump table for remainder dispatch. Constant-iteration loops consolidate decrement copies into a single `dbra` counter.

**Code:** `gcc/config/m68k/m68k.cc`, `gcc/loop-unroll.cc`, `gcc/loop-doloop.cc`

## 4. Memory Access Reordering

Reorders memory accesses through a base pointer to be sequential by offset, enabling store merging and post-increment addressing. Also normalizes constant-address bases so contiguous accesses share a common base pointer. Runs at `-O1` and above (including `-Os`).

Disable with: `-mno-m68k-reorder-mem`

**Passes:** `m68k-reorder-mem` (new GIMPLE pass), `m68k-reorder-incr` (new pre-RA RTL pass)

**Code:** `gcc/config/m68k/m68k-pass-memreorder.cc`, `gcc/config/m68k/m68k-util.cc`

## 5. Autoincrement Optimization

Post-increment addressing passes and redundant copy cleanup.

### Autoincrement Pass

Converts indexed memory accesses to post-increment within and across BBs. Peephole2 patterns recover POST_INC on RMW. Two RTL passes (`m68k-sink-for-rmw`, `m68k-sink-postinc`) reassemble PRE-split load/store for combine RMW.

Disable with: `-mno-m68k-autoinc`

**Passes:** `m68k-autoinc-split` (new GIMPLE pass), `m68k-autoinc` (new pre-RA RTL pass), `m68k-normalize-autoinc` (new post-RA RTL pass), `m68k-sink-for-rmw` (new RTL pass), `m68k-sink-postinc` (new RTL pass)

**Code:** `gcc/config/m68k/m68k-pass-autoinc.cc`, `gcc/gcse.cc`

### Available Copy Elimination

Removes redundant register-to-register copies that are already established on all incoming paths. Primarily cleans up after `inc_dec`, which reintroduces copies in unrolled loop peels.

Disable with: `-mno-m68k-avail-copy-elim`

**Pass:** `m68k-avail-copy-elim` (new RTL pass, runs after `inc_dec`)

**Code:** `gcc/config/m68k/m68k-pass-autoinc.cc`

## 6. 16/32-bit Optimization

Narrowing multiplications, hoisting zero-extensions, and packing 16-bit values into 32-bit registers.

### Constant Narrowing

Narrows C promotion-widened constants in bitwise/shift operations back to match the truncation type (e.g., 32-bit shift → 16-bit on `-mshort`). Disable with: `-mno-m68k-narrow-const-ops`

**Pass:** `m68k-narrow-const-ops` (new GIMPLE pass)

**Code:** `gcc/config/m68k/m68k-pass-shortopt.cc`

### Multiplication Optimization

Narrows 32-bit multiplications to 16-bit `muls.w` when operand ranges are known to fit (avoiding a library call on 68000), and removes redundant sign extension after 16-bit multiply since `muls.w` already produces a 32-bit signed result.

Disable with: `-mno-m68k-narrow-index-mult`

**Pass:** `m68k-narrow-index-mult` (new GIMPLE pass)

**Patterns:** `define_peephole2` for sign extension elimination

**Code:** `gcc/config/m68k/m68k-pass-shortopt.cc`, `gcc/config/m68k/m68k.md`

### ANDI Hoisting

Replaces `andi.l #mask` zero-extension with hoisted `moveq #0`. Handles `clr.w`+`move.b` widening and `and.w #N` → `and.l #N` to eliminate later `andi.l #65535`. Peephole2 for `andi.l #$ffff` + `clr.w` → `moveq #0`.

Disable with: `-mno-m68k-elim-andi`

**Pass:** `m68k-elim-andi` (new RTL pass)

**Patterns:** `define_peephole2` for `andi.l #$ffff` + `clr.w` → `moveq #0`

**Code:** `gcc/config/m68k/m68k-pass-shortopt.cc`, `gcc/config/m68k/m68k.md`

### Word Packing

Improves code for packing 16-bit values into 32-bit registers. Folds `andi.l #$ffff` + `ori.l` sequences into `swap`+`move.w`+`swap`, and optimizes struct return of two short fields.

Disable with: `-mno-m68k-highword-opt`

**Pass:** `m68k-highword-opt` (new RTL pass)

**Patterns:** `define_peephole2` for andi/ori folding

**Code:** `gcc/config/m68k/m68k-pass-shortopt.cc`, `gcc/config/m68k/m68k.md`

## 7. Various Smaller Optimizations

Adjacent memory merging, constant-time bit extraction, CC-aware load reordering, and sibcall relaxation.

### Merge Peepholes

Combines adjacent small memory accesses into larger ones (e.g. two `move.w` into one `move.l`), and eliminates register intermediates in load+store+branch sequences by using mem-to-mem moves (68000 only).

**Patterns:** `define_peephole2` in machine description

**Code:** `gcc/config/m68k/m68k.md`

### Bit Extraction

Replaces shift+mask for single-bit extraction with `btst`+`sne` on 68000/68010. Shifts cost 6+2N cycles while `btst` is constant time. For unsigned results, `neg.b` converts `sne` to 0/1. Disabled on 68020+ where `bfextu`/`bfexts` handle this.

Disable with: `-mno-m68k-btst-extract`

**Patterns:** `cstore_btst` `define_insn`, `define_peephole2`

**Code:** `gcc/config/m68k/m68k.md`

### CC Reordering

On m68k, `move` sets CC. If the register tested by a branch is not the last one loaded, `final` must emit an explicit `tst`. This pass reorders loads so the tested register is loaded last, eliding the `tst`.

**Pass:** `m68k-reorder-cc` (new RTL pass)

**Code:** `gcc/config/m68k/m68k-pass-miscopt.cc`

### Bit Set Peepholes

Converts variable-position shift sequences to constant-time `bset` on 68000/68010 (`moveq #1` + `lsl` → `moveq #0` + `bset`). Also converts power-of-2 right shifts. Saves 2N cycles per shift.

**Patterns:** `define_peephole2` (guarded by `TUNE_68000_10`)

**Code:** `gcc/config/m68k/m68k.md`

### Tablejump Index Narrowing

Narrows SImode tablejump index to HImode when the table is small, enabling `.w` indexed loads and narrower scaling instructions.

**Patterns:** `define_insn_and_split` with `UNSPEC_TABLEJUMP_LOAD`

**Code:** `gcc/config/m68k/m68k.md`, `gcc/config/m68k/m68k.cc`

### Sibcall

Loosens restrictions on sibcall (tail call) optimization under the fastcall ABI. The stock backend conservatively disables sibcalls when parameter registers differ, but under fastcall many cases are safe.

**Code:** `gcc/config/m68k/m68k.cc`

## Appendix A: libcmini Real-World Example

`memcmp` from libcmini (`-Os -mshort -mfastcall`): §3 (IVOPTS) selects separate pointer IVs, §5 (autoinc) converts to `(a0)+`, §2 (IRA) keeps pointers in address registers. Result: 43% faster, 30% smaller vs stock GCC 15.
