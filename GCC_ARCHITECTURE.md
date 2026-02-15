# GCC Internals — From C to m68k Assembly

A conceptual guide to how GCC transforms C source code into machine instructions, using the m68k backend as a running example. Complements [GCC_PASSES.md](GCC_PASSES.md) (pass-by-pass reference), [M68K_OPTIMIZATIONS.md](M68K_OPTIMIZATIONS.md) (m68k-specific changes in this branch), and [GCC_GLOSSARY.md](GCC_GLOSSARY.md) (terminology).

## Contents

**Chapters**

1. [From C to Assembly — Overview](#chapter-1-from-c-to-assembly--overview)
2. [The Compilation Stages in Detail](#chapter-2-the-compilation-stages-in-detail)
   1. [Parsing and GENERIC](#1-parsing-and-generic)
   2. [Gimplification](#2-gimplification)
   3. [SSA Construction](#3-ssa-construction)
   4. [GIMPLE Optimization](#4-gimple-optimization)
   5. [RTL Expansion](#5-rtl-expansion)
   6. [RTL Optimization (Pre-RA)](#6-rtl-optimization-pre-ra)
   7. [Register Allocation](#7-register-allocation)
   8. [Post-RA Optimization](#8-post-ra-optimization)
   9. [Final Assembly](#9-final-assembly)
3. [Foundation Passes](#chapter-3-foundation-passes)
   1. [RTX Cost Model](#1-rtx-cost-model)
   2. [SSA and PHI Nodes](#2-ssa-and-phi-nodes)
   3. [Dominator-Based Optimization](#3-dominator-based-optimization)
   4. [Dataflow Analysis (DF)](#4-dataflow-analysis-df)
   5. [Combine](#5-combine)
   6. [IRA](#6-ira-register-allocation)
   7. [PRE/FRE](#7-prefre)

**See also:** [GCC_GLOSSARY.md](GCC_GLOSSARY.md) — terminology reference

---

## Chapter 1: From C to Assembly — Overview

GCC compiles C through a series of intermediate representations ([IR](GCC_GLOSSARY.md#ir)), each lower-level than the last:

```
C source
  │
  ▼
GENERIC (AST)          ← parser output: full type info, nested expressions
  │
  ▼
GIMPLE                 ← three-address code: at most one operation per statement
  │
  ▼
GIMPLE-SSA             ← every variable assigned exactly once: enables dataflow opts
  │
  ▼  [~200 GIMPLE optimization passes]
  │
  ▼
RTL (virtual regs)     ← register transfer language: explicit machine operations
  │
  ▼  [~30 pre-RA RTL passes]
  │
  ▼
IRA + Reload           ← virtual → physical registers (d0-d7, a0-a6)
  │
  ▼  [~20 post-RA passes]
  │
  ▼
Assembly (.s)          ← final output: m68k instructions
```

### Running Example

A simple byte-fill loop shows how each stage transforms the code:

```c
void fill(char *dst, char val, int n) {
    for (int i = 0; i < n; i++)
        dst[i] = val;
}
```

| Stage | Representation |
|-------|----------------|
| [GENERIC](#1-parsing-and-generic) | `FOR_STMT { MODIFY_EXPR(ARRAY_REF(dst, i), val); POSTINCREMENT_EXPR(i) }` |
| [GIMPLE](#2-gimplification) | `_1 = dst + i; *_1 = val; i = i + 1;` |
| [SSA](#3-ssa-construction) | `i_3 = PHI(0, i_5); _1 = dst_2(D) + i_3; *_1 = val_4(D); i_5 = i_3 + 1;` |
| [After GIMPLE opts](#4-gimple-optimization) | `dst_7 = PHI(dst, dst_8); *dst_7 = val; dst_8 = dst_7 + 1;` (IV → pointer) |
| [RTL (pre-RA)](#5-rtl-expansion) | `(set (mem (reg:SI 42)) (reg:QI 44))` with virtual registers |
| [RTL (post-RA)](#7-register-allocation) | `(set (mem (post_inc (reg:SI a0))) (reg:QI d0))` |
| [Assembly](#9-final-assembly) | `move.b d0,(a0)+` / `dbra d1,.loop` |

Each stage is detailed in [Chapter 2](#chapter-2-the-compilation-stages-in-detail).

---

## Chapter 2: The Compilation Stages in Detail

### 1. Parsing and GENERIC

**What happens:** The C frontend (`gcc/c/`) parses source into [GENERIC](GCC_GLOSSARY.md#generic) — GCC's language-independent [AST](GCC_GLOSSARY.md#ast). Types are resolved, implicit conversions inserted, and syntax errors reported.

**What it looks like:** GENERIC is a tree of `_EXPR` nodes. For our fill loop:

```
MODIFY_EXPR
├── ARRAY_REF
│   ├── dst    (PARM_DECL, char*)
│   └── i      (VAR_DECL, int)
└── val        (PARM_DECL, char)
```

**Key point:** GENERIC preserves source-level structure — nested expressions, for/while loops, switch statements. The next stage flattens all of this.

**Files:** `gcc/c/c-parser.cc` (parser), `gcc/c/c-typeck.cc` (type checking), `gcc/tree.h` (tree node types)

**Cross-ref:** [GCC_PASSES.md Phase 1](GCC_PASSES.md#phase-1-lowering-passes) — lowering passes that process GENERIC

### 2. Gimplification

**What happens:** GENERIC trees are lowered to [GIMPLE](GCC_GLOSSARY.md#gimple) — a three-address code where each statement has at most one operation. Nested expressions are broken into temporaries, loops become `goto`+labels, and the [CFG](GCC_GLOSSARY.md#cfg) (control flow graph) is built from [basic blocks](GCC_GLOSSARY.md#bb).

**What it looks like** (`-fdump-tree-gimple`):

```
fill (char * dst, char val, int n)
{
  int i;
  char * _1;

  i = 0;
  goto <check>;
loop:
  _1 = dst + (long)i;
  *_1 = val;
  i = i + 1;
check:
  if (i < n) goto loop; else goto done;
done:
  return;
}
```

Every statement is one of: assignment, call, conditional, goto, return, or label. No nested sub-expressions.

**Key point:** GIMPLE is the IR where most high-level optimizations happen. The ~200 [GIMPLE-SSA](GCC_GLOSSARY.md#ssa) passes in [Phase 5](GCC_PASSES.md#phase-5-all-optimizations-per-function) all work on this representation.

**Files:** `gcc/gimplify.cc` (GENERIC→GIMPLE), `gcc/gimple.h` (GIMPLE IR)

### 3. SSA Construction

**What happens:** GIMPLE is converted to [SSA](GCC_GLOSSARY.md#ssa) form: every variable gets a unique version number at each definition point. Where control flow merges, [PHI](GCC_GLOSSARY.md#phi) nodes select between versions.

**What it looks like** (`-fdump-tree-ssa`):

```
loop:
  # i_3 = PHI <0(entry), i_5(loop)>
  _1 = dst_2(D) + (long)i_3;
  *_1 = val_4(D);
  i_5 = i_3 + 1;
  if (i_5 < n_6(D)) goto loop; else goto done;
```

`i_3` and `i_5` are different SSA versions of `i`. The PHI node at the loop header selects `0` on first entry or `i_5` on back edges.

**Key point:** SSA makes def-use chains trivial to compute — each use points to exactly one definition. This enables [CCP](GCC_GLOSSARY.md#ccp), [PRE](GCC_GLOSSARY.md#pre), [DCE](GCC_GLOSSARY.md#dce), and virtually every other optimization in the pipeline.

**Files:** `gcc/tree-into-ssa.cc` (SSA construction), `gcc/tree-ssa.h` (SSA utilities)

**Cross-ref:** [Foundation Passes: SSA and PHI nodes](#2-ssa-and-phi-nodes)

### 4. GIMPLE Optimization

**What happens:** The bulk of high-level optimization — [CCP](GCC_GLOSSARY.md#ccp), [FRE](GCC_GLOSSARY.md#fre)/[PRE](GCC_GLOSSARY.md#pre), [DCE](GCC_GLOSSARY.md#dce), [DSE](GCC_GLOSSARY.md#dse), [VRP](GCC_GLOSSARY.md#vrp), [SRA](GCC_GLOSSARY.md#sra), loop optimizations, [IVOPTS](GCC_GLOSSARY.md#ivopts), inlining, and many more. These passes run in [Phase 5](GCC_PASSES.md#phase-5-all-optimizations-per-function) and transform GIMPLE-SSA extensively.

Several passes in this phase are critical for understanding the m68k optimizations:

**[VRP](GCC_GLOSSARY.md#vrp)** (Value Range Propagation, 5.26/5.114, `execute_ranger_vrp()` in `gcc/tree-vrp.cc`) tracks the possible range of every [SSA](GCC_GLOSSARY.md#ssa) variable through the program. At each branch, VRP narrows ranges: after `if (x > 0)`, VRP knows `x ∈ [1, INT_MAX]` on the true edge. Ranges propagate through arithmetic: `y = x & 0xFF` gives `y ∈ [0, 255]`.

On m68k, VRP is essential for two optimizations:

- **DBRA** ([M68K_OPTIMIZATIONS.md §5](M68K_OPTIMIZATIONS.md#5-dbra-loop-optimization)): `dbra` only works with 16-bit counters. VRP proves that a loop counter fits in `[0, 65535]`, enabling the doloop pass to narrow 32-bit `subq.l`+`bne` to `dbra`.
- **Multiply narrowing** ([M68K_OPTIMIZATIONS.md §6](M68K_OPTIMIZATIONS.md#6-multiplication-optimization)): `muls.w` requires 16-bit operands. VRP proves that both operands fit in `[-32768, 32767]`, enabling `m68k_pass_narrow_index_mult` to replace a 32-bit library call with a single instruction.

**[IVOPTS](GCC_GLOSSARY.md#ivopts)** (pass 5.95, `tree_ssa_iv_optimize()` in `gcc/tree-ssa-loop-ivopts.cc`) selects the best set of [induction variables](GCC_GLOSSARY.md#iv) for each loop. It works in three phases:

1. **Find candidates** (`find_induction_variables()`) — enumerate possible IVs: the original source IVs, pointer-based alternatives, derived expressions
2. **Compute costs** (`iv_ca_cost()`) — for each candidate at each use point, estimate the instruction cost of expressing that use with that IV. Step costs (the per-iteration increment) and use costs (the addressing mode needed) are both considered.
3. **Select cheapest set** (`find_optimal_iv_set()`) — choose the combination of IVs with the lowest total cost

On m68k, two modifications to the cost model are critical:

- **Step cost discount** ([M68K_OPTIMIZATIONS.md §2](M68K_OPTIMIZATIONS.md#2-induction-variable-optimization)): When a target supports auto-increment, a pointer IV's step cost (e.g. `addq.l #2,a0`) is discounted to zero because `(a0)+` absorbs the increment for free. Without this, IVOPTS prefers a single integer counter with indexed addressing `(a0,d0.l)` (10 cycles on 68000) over separate pointer IVs with `(a0)+` (4 cycles).
- **Doloop cost credit** ([M68K_OPTIMIZATIONS.md §5](M68K_OPTIMIZATIONS.md#5-dbra-loop-optimization)): IVOPTS may eliminate a loop counter in favor of pointer comparison (`ptr != end`). The `TARGET_DOLOOP_COST_FOR_COMPARE` hook adds a cost penalty for eliminating the counter IV when `dbra` is available, keeping the counter alive.

For our fill loop, IVOPTS replaces the integer IV `i` with a pointer IV:

**Before IVOPTS:**

```
  # i_3 = PHI <0(entry), i_5(loop)>
  _1 = dst_2(D) + (long)i_3;
  *_1 = val_4(D);
  i_5 = i_3 + 1;
  if (i_5 < n_6(D)) goto loop;
```

**After IVOPTS:**

```
  _end = dst_2(D) + (long)n_6(D);
  # _ptr_7 = PHI <dst_2(D)(entry), _ptr_8(loop)>
  *_ptr_7 = val_4(D);
  _ptr_8 = _ptr_7 + 1;
  if (_ptr_8 != _end) goto loop;
```

The integer counter is gone — replaced by a pointer that advances through memory. This is exactly what the m68k `(a0)+` addressing mode does for free.

**[Store merging](GCC_GLOSSARY.md#store-merging)** (5.124, `pass_store_merging::execute()` in `gcc/gimple-ssa-store-merging.cc`) combines adjacent stores to memory into wider operations. `clr.w (a0); clr.w 2(a0)` → `clr.l (a0)`. This pass operates on GIMPLE and needs stores to be in offset order — which is why `m68k_pass_reorder_mem` ([M68K_OPTIMIZATIONS.md §11](M68K_OPTIMIZATIONS.md#11-memory-access-reordering)) runs immediately before it.

**[Tail calls / sibcalls](GCC_GLOSSARY.md#sibcall)** (5.127, `tree_optimize_tail_calls_1()` in `gcc/tree-tailcall.cc`) replace `call` + `return` with a single jump when the callee's return value is the caller's return value. On m68k: `jsr func; rts` → `jra func`. This saves the call/return overhead and one stack frame. The m68k backend loosens sibcall restrictions under fastcall ABI where arguments are already in registers. See [M68K_OPTIMIZATIONS.md §15](M68K_OPTIMIZATIONS.md#15-sibcall-optimization).

**Key m68k passes at this stage:**

- `m68k_pass_narrow_index_mult` (5.26a) — narrows 32-bit multiplies to 16-bit `muls.w`
- `m68k_pass_autoinc_split` (5.95a) — re-splits combined pointer increments for post-increment
- `m68k_pass_reorder_mem` (5.123a) — reorders struct field accesses by offset

**Files:** `gcc/tree-ssa-loop-ivopts.cc` (IVOPTS), `gcc/tree-ssa-pre.cc` (PRE), `gcc/tree-ssa-dce.cc` (DCE), `gcc/tree-ssa-dom.cc` (dominator opts), `gcc/tree-vrp.cc` (VRP), `gcc/gimple-ssa-store-merging.cc` (store merging)

### 5. RTL Expansion

**What happens:** GIMPLE is lowered to [RTL](GCC_GLOSSARY.md#rtl) (Register Transfer Language) — a low-level IR that explicitly represents machine operations. The `expand` pass ([Phase 6](GCC_PASSES.md#phase-6-rtl-generation)) matches GIMPLE operations against `define_insn` and `define_expand` patterns in the machine description (`gcc/config/m68k/m68k.md`).

**What it looks like** (`-fdump-rtl-expand`):

```
(insn (set (mem:QI (reg:SI 42))      ;; *_ptr = val
           (reg:QI 44)))
(insn (set (reg:SI 45)               ;; _ptr_8 = _ptr_7 + 1
           (plus:SI (reg:SI 42)
                    (const_int 1))))
```

Virtual register numbers (42, 44, 45) are pseudo-registers — unlimited in number, to be mapped to real hardware registers by [IRA](GCC_GLOSSARY.md#ira).

**Key point:** This is where target-specific instruction selection begins. The `.md` file's `define_insn` patterns determine which RTL shapes are valid m68k instructions. A pattern like:

```lisp
(define_insn ""
  [(set (mem:QI (post_inc:SI (match_operand:SI 0 "register_operand" "+a")))
        (match_operand:QI 1 "register_operand" "d"))]
  ""
  "move.b %1,(%0)+")
```

tells GCC that `(set (mem (post_inc reg)) reg)` is a single `move.b` instruction.

**Files:** `gcc/cfgexpand.cc` (`pass_expand::execute()` → `expand_gimple_basic_block()`), `gcc/config/m68k/m68k.md` (patterns)

### 6. RTL Optimization (Pre-RA)

**What happens:** [Phase 7](GCC_PASSES.md#phase-7-rtl-optimization-pre-register-allocation) runs ~30 passes on RTL while registers are still virtual. Key passes:

| Pass | What it does |
|------|-------------|
| [CSE](GCC_GLOSSARY.md#cse) (7.6) | Eliminates common subexpressions within extended basic blocks |
| [Combine](GCC_GLOSSARY.md#combine) (7.33) | Merges 2–4 adjacent [insns](GCC_GLOSSARY.md#insn) into one — the single most impactful RTL pass |
| [inc_dec](GCC_GLOSSARY.md#postinc) (7.29) | Detects address+increment patterns → [POST_INC](GCC_GLOSSARY.md#postinc)/[PRE_DEC](GCC_GLOSSARY.md#postinc) |
| [doloop](GCC_GLOSSARY.md#doloop) (7.21) | Converts counted loops to hardware loop instructions (`dbra` on m68k) |
| [Loop unrolling](GCC_GLOSSARY.md#loop-unrolling) (7.20) | Replicates loop body to reduce branch overhead |
| `ext_dce` (7.32) | Removes sign/zero extensions whose upper bits are never used |

**`inc_dec`** (7.29, `merge_in_block()` in `gcc/auto-inc-dec.cc`) scans each [BB](GCC_GLOSSARY.md#bb) looking for a memory access through a register followed by an increment/decrement of that same register. When found, it folds both into a single [POST_INC](GCC_GLOSSARY.md#postinc) or [PRE_DEC](GCC_GLOSSARY.md#postinc) operation:

```
;; Before inc_dec: two insns
(set (mem:QI (reg:SI 42)) (reg:QI 44))    ;; store through ptr
(set (reg:SI 42) (plus:SI (reg:SI 42) (const_int 1)))  ;; ptr++

;; After inc_dec: one insn with POST_INC
(set (mem:QI (post_inc:SI (reg:SI 42))) (reg:QI 44))   ;; move.b d0,(a0)+
```

This is the standard GCC pass for auto-increment. On m68k, the custom `m68k_pass_opt_autoinc` (9.14b) runs *after* RA to catch additional opportunities that `inc_dec` misses — particularly cross-BB patterns and cases where register allocation reveals new merging opportunities. See [M68K_OPTIMIZATIONS.md §3](M68K_OPTIMIZATIONS.md#3-autoincrement-optimization-pass).

**`doloop`** (7.21, `doloop_optimize_loops()` in `gcc/loop-doloop.cc`) transforms counted loops into hardware loop instructions. It recognizes loops with a trip count computable at entry, generates a `doloop_end` pattern that decrements and branches in one instruction, and eliminates the original compare+branch. On m68k, `doloop_end` maps to `dbra`:

```
;; Before doloop: two insns — subq.l #1,d0; bne .loop
(set (reg:SI 50)
  (plus:SI (reg:SI 50) (const_int -1)))
(set (pc)
  (if_then_else
    (ne (reg:SI 50) (const_int 0))
    (label_ref loop)
    (pc)))

;; After doloop: single doloop_end_hi — dbra d0,.loop
(parallel [
  (set (pc)
    (if_then_else
      (ne (reg:HI 50) (const_int 0))
      (label_ref loop)
      (pc)))
  (set (reg:HI 50)
    (plus:HI (reg:HI 50) (const_int -1)))])
```

The key constraint: `dbra` operates on 16-bit registers (word decrement, branch on ≥ 0). The pass can only use `dbra` when [VRP](GCC_GLOSSARY.md#vrp) has proven the counter fits in 16 bits. See [M68K_OPTIMIZATIONS.md §5](M68K_OPTIMIZATIONS.md#5-dbra-loop-optimization).

**Loop unrolling** (7.20, `unroll_loop_runtime_iterations()` in `gcc/loop-unroll.cc`) replicates the loop body N times, reducing branch overhead from once-per-iteration to once-per-N-iterations. For a loop with a runtime trip count, the unroller must handle the *remainder* — the leftover iterations when the count isn't divisible by N.

Stock GCC generates a compare cascade for the remainder: `cmp #1; beq .peel1; cmp #2; beq .peel2; ...` — this costs N-1 branches, each a compare+branch pair. On m68k, `TARGET_PREFER_RUNTIME_UNROLL_TABLEJUMP` replaces this with a jump table: `move.w .tab(pc,d0.w),d0; jmp (pc,d0.w)` — constant-time dispatch regardless of remainder value.

The unroller also controls *IV splitting*: by default, unrolled copies use base+offset addressing (`0(a0)`, `2(a0)`, `4(a0)`...) instead of chaining increments (`(a0)+`, `(a0)+`, `(a0)+`...). On m68k, IV splitting is disabled so that each unrolled copy chains auto-increment naturally. See [M68K_OPTIMIZATIONS.md §10](M68K_OPTIMIZATIONS.md#10-improved-loop-unrolling).

**Key m68k pass:** `m68k_pass_avail_copy_elim` (7.29a) — removes redundant copies left over from loop unrolling, before [IRA](GCC_GLOSSARY.md#ira) can see them. See [M68K_OPTIMIZATIONS.md §13](M68K_OPTIMIZATIONS.md#13-available-copy-elimination).

**Files:** `gcc/cse.cc`, `gcc/combine.cc`, `gcc/auto-inc-dec.cc` (inc_dec), `gcc/loop-doloop.cc` (doloop), `gcc/loop-unroll.cc` (unrolling)

**Cross-ref:** [Foundation Passes: Combine](#5-combine), [Foundation Passes: Dataflow Analysis](#4-dataflow-analysis-df)

### 7. Register Allocation

**What happens:** [IRA](GCC_GLOSSARY.md#ira) (Integrated Register Allocator, [Phase 8](GCC_PASSES.md#phase-8-register-allocation)) maps virtual registers to physical ones. On m68k: `d0`–`d7` (data), `a0`–`a6` (address), `fp0`–`fp7` (float). When there aren't enough registers, values are *spilled* to the stack.

This is the hardest constraint in the entire pipeline. Every optimization before RA works with unlimited registers; after RA, everything must fit in 15 integer registers (8 data + 7 address, since `a7` is SP).

**Pre-RA vs post-RA optimization:** Optimizations that reduce register pressure — eliminating copies, folding increments into addressing modes, removing dead values — are far more effective when run *before* RA. Pre-RA, removing a pseudo-register directly reduces the number of values IRA must fit into physical registers, which can be the difference between a clean allocation and a spill. Post-RA, the allocation is already committed: even if an optimization removes a register use, the spill slot and save/restore code are already in place. At best a post-RA optimization can free a register for use as a scratch, but it cannot undo a spill decision. This is why `m68k_pass_avail_copy_elim` (7.29a) runs before IRA — eliminating redundant copies early lets IRA coalesce the registers instead of allocating separate physical registers that might cause spills.

**For our fill loop:**

```
;; Before IRA (virtual registers)
(set (mem:QI (post_inc:SI (reg:SI 42))) (reg:QI 44))

;; After IRA (physical registers)
(set (mem:QI (post_inc:SI (reg:SI a0))) (reg:QI d0))
```

Register 42 → `a0` (address register, because it's used as a memory base), register 44 → `d0` (data register, because it holds a byte value).

**m68k constraint:** Only address registers (`a0`–`a6`) can be used as base registers in memory operands. IRA must respect this — a pointer in `d3` would require an extra `move.l d3,a0` before every memory access. The `m68k_ira_change_pseudo_allocno_class` hook promotes pointer pseudos to `ADDR_REGS` to avoid this. See [M68K_OPTIMIZATIONS.md §9](M68K_OPTIMIZATIONS.md#9-ira-register-class-promotion).

**Files:** `gcc/ira.cc` (IRA), `gcc/lra.cc` ([LRA](GCC_GLOSSARY.md#lra) — reload), `gcc/ira-costs.cc` (cost computation)

**Cross-ref:** [Foundation Passes: IRA](#6-ira-register-allocation)

### 8. Post-RA Optimization

**What happens:** [Phase 9](GCC_PASSES.md#phase-9-post-register-allocation) optimizes with hard registers. Passes here know exactly which physical registers are in use and can exploit target-specific patterns:

| Pass | What it does |
|------|-------------|
| `cprop_hardreg` (9.18) | Copy propagation with real registers |
| `peephole2` (9.14) | Pattern-match 2–5 adjacent insns → replacement sequence |
| `compare_elim` (9.7) | Remove redundant `tst`/`cmp` when a previous insn already set [CC](GCC_GLOSSARY.md#cc) |
| `prologue/epilogue` (9.8) | Insert `movem.l d3-d7/a2-a6,-(sp)` for callee-saved registers |
| `regrename` (9.16) | Rename registers to break false dependencies |

**m68k custom passes in this phase:**

| Pass | Purpose |
|------|---------|
| `m68k_pass_normalize_autoinc` (9.13a) | Canonicalize autoinc patterns before peephole2 |
| `m68k_pass_reorder_for_cc` (9.14a) | Reorder loads so tested register is loaded last → elide `tst` |
| `m68k_pass_opt_autoinc` (9.14b) | Post-RA indexed → `(a0)+` conversion, including cross-BB |
| `m68k_pass_highword_opt` (9.19a) | Word packing: `andi.l`+`ori.l` → `swap`+`move.w` |
| `m68k_pass_elim_andi` (9.19b) | Hoist `moveq #0` for zero-extension |

**Example — peephole2 store merging:**

```asm
; Before peephole2           ; After
  move.w  #1,(a0)+             move.l  #$10002,(a0)+
  move.w  #2,(a0)+
```

**Files:** `gcc/cprop.cc` (cprop_hardreg), `gcc/recog.cc` (peephole2), `gcc/config/m68k/m68k-rtl-passes.cc` (m68k passes)

### 9. Final Assembly

**What happens:** [Phase 10](GCC_PASSES.md#phase-10-late-compilation) and [Phase 11](GCC_PASSES.md#phase-11-final-assembly-generation) convert RTL to text assembly. The `final` pass walks each [insn](GCC_GLOSSARY.md#insn), calls the output template from `.md` patterns, and emits the `.s` file.

Key tasks at this stage:

- **[CC](GCC_GLOSSARY.md#cc) tracking:** `final_scan_insn()` (in `gcc/final.cc`) tracks which condition codes are live, suppressing redundant `tst`/`cmp` instructions when a preceding `move` already set the flags
- **Branch shortening** (10.12): replaces `jmp label` with `bra.s label` when the target is within ±128 bytes, or `bra.w` for ±32K
- **Prologue/epilogue:** emits `movem.l` register save/restore and stack frame setup
- **Debug info:** generates DWARF for source-level debugging

**Final output for our fill loop** (with `-O2 -mfastcall`):

```asm
fill:
        subq.l  #1,%d1
.loop:
        move.b  %d0,(%a0)+
        dbra    %d1,.loop
        rts
```

Two instructions in the loop body — one store with auto-increment, one `dbra`. Every stage of the pipeline contributed to reaching this result.

**Files:** `gcc/final.cc` (final pass), `gcc/config/m68k/m68k.cc` (`m68k_output_*` functions)

---

## Chapter 3: Foundation Passes

These passes underpin the entire optimization pipeline. Understanding them is essential for working on the backend.

### 1. RTX Cost Model

**What:** The target cost model is a set of hooks that every optimization pass queries to decide whether a transformation is profitable. These hooks are the primary mechanism through which backend-specific knowledge influences the entire optimization pipeline — they are called hundreds of times per function by combine, IVOPTS, CSE, and the scheduler.

**Why it matters:** Without accurate costs, passes make decisions based on generic heuristics — counting operations rather than cycles. On m68k, where addressing modes vary from 4 to 14 cycles, the difference between `(a0)` and `8(a0,d0.l)` is larger than many entire instructions. The cost model is what prevents combine from folding pointer IVs into expensive indexed addressing, and what makes IVOPTS prefer separate pointer IVs with `(a0)+` over a single counter with `(a0,d0.l)`.

**Key hooks and their inputs:**

| Hook | Callers | Input form | What it answers |
|------|---------|------------|----------------|
| `TARGET_RTX_COSTS` | combine, late_combine, IVOPTS, expand, CSE | RTX sub-expression with pseudo-regs (pre-RA) or hard regs (post-RA). No instruction context — just the expression tree. Cannot distinguish addressing modes inside MEM from standalone arithmetic. | "How expensive is this RTX expression?" |
| `TARGET_INSN_COST` | combine, late_combine, scheduler | Complete insn pattern `(set dst src)` with full context. Pre-RA: pseudo-regs, so exact cycle counts are approximate. Post-RA: hard regs, exact costing possible. | "How expensive is this complete instruction?" |
| `TARGET_ADDRESS_COST` | IVOPTS, combine, scheduler | Address expression inside a MEM — always an addressing mode candidate. May contain pseudos (pre-RA) so the final register class is unknown. | "How expensive is this addressing mode?" |
| `TARGET_NEW_ADDRESS_PROFITABLE_P` | scheduler | Two address expressions (old and new) for the same MEM, with hard regs (post-RA only). | "Is the new addressing mode cheaper?" |

**Costing with pseudo-registers:** Pre-RA, cost hooks receive pseudo-register numbers, not `d0`/`a0`. This means the cost model cannot know the exact register class — a pseudo might end up in either a data or address register. The m68k cost model handles this by costing register-class-agnostic patterns (e.g. `(plus reg reg)`) at their cheapest valid form, and relying on operand constraints in the `.md` patterns to prevent invalid allocations. The main risk is *overcosting*: if the model assumes the worst-case register class, it might reject a combine that would have been profitable. The m68k model errs on the side of accurate costing for the common case.

**How combine uses costs:** When combine tries to merge two insns into one, it compares the cost of the original sequence against the cost of the merged result (`combine_validate_cost()` in `gcc/combine.cc`). If the merged insn is not cheaper, combine rejects the transformation:

```
;; combine tries: move.l d0,(a0) + addq.l #4,a0  →  move.l d0,(a0)+
;; Cost check: 12 + 8 = 20 cycles  vs  12 cycles  →  accept (cheaper)

;; combine tries: folding IV into indexed addressing
;; Cost check: addq.l #2,a0 + move.w (a0),d0  vs  move.w (a0,d0.l),d0
;; Cost check: 8 + 8 = 16 cycles  vs  14 cycles  →  reject on m68k
;; (because move.w (a0),d0 becomes (a0)+ which is only 8 cycles total)
```

**Why TARGET_INSN_COST was added:** GCC's default `TARGET_RTX_COSTS` only costs the *source* side of `(set dst src)`. The destination is costed separately, and for memory destinations GCC assumes a fixed cost. On m68k, `move.l d0,(a0)` costs 12 cycles total, not 4 — without `TARGET_INSN_COST`, stores look as cheap as register moves, causing combine to fold values into memory operands unnecessarily. `TARGET_INSN_COST` sees the full `(set dst src)` pattern and can cost destination memory accesses accurately, including detecting non-RMW compound-to-memory patterns that require copy+op+store (3 insns). See [M68K_OPTIMIZATIONS.md §1](M68K_OPTIMIZATIONS.md#1-rtx-and-address-cost-calculations).

**Files:** `gcc/config/m68k/m68k_costs.cc` (`m68k_rtx_costs_impl()`, `m68k_insn_cost_impl()`, `m68k_address_cost_impl()`), `gcc/config/m68k/m68k.cc` (cost hooks)

### 2. SSA and PHI Nodes

**What:** [Static Single Assignment](GCC_GLOSSARY.md#ssa) form ensures every variable is defined exactly once. At control flow merge points, [PHI](GCC_GLOSSARY.md#phi) nodes select which definition reaches.

**Cross-ref:** [Chapter 2 §3](#3-ssa-construction) for examples of SSA construction from GIMPLE.

**Why it matters:** SSA makes def-use relationships trivial — each use has exactly one reaching definition. Without SSA, you need iterative dataflow analysis to answer "where was this value defined?" With SSA, it's a single pointer dereference.

**Example:**

```c
int x;
if (cond)
    x = a;
else
    x = b;
use(x);
```

```
;; GIMPLE (no SSA)          ;; GIMPLE-SSA
if (cond) goto then;        if (cond_1) goto then;
else_bb:                     else_bb:
  x = b;                      x_3 = b_5;
  goto join;                   goto join;
then:                        then:
  x = a;                      x_4 = a_6;
join:                        join:
  use(x);    ← which x?       # x_2 = PHI <x_3(else), x_4(then)>
                               use(x_2);  ← unambiguous
```

PHI nodes are not real instructions — they're resolved during [RTL expansion](#5-rtl-expansion) into register copies along CFG edges.

**What breaks without it:** No modern optimization pass works on non-SSA GIMPLE. [CCP](GCC_GLOSSARY.md#ccp) needs unique definitions to propagate constants. [PRE](GCC_GLOSSARY.md#pre) needs unique values to detect redundancy. [VRP](GCC_GLOSSARY.md#vrp) needs unique def points to track ranges.

**Files:** `gcc/tree-into-ssa.cc`, `gcc/tree-phinodes.cc`

### 3. Dominator-Based Optimization

**What:** A block A *dominates* block B if every path from the function entry to B must pass through A. The dominator pass (`pass_dominator::execute()` → `optimize_stmt()`, 5.43, in `gcc/tree-ssa-dom.cc`) uses this relationship to perform [CSE](GCC_GLOSSARY.md#cse), copy propagation, and jump threading in a single walk of the dominator tree.

**Why it matters:** Dominator information tells you what's *always* true at a given point. If block A dominates block B, any computation in A is available in B — no need to recompute it.

**Example — dominator-based CSE:**

```
BB1 (dominates BB2 and BB3):
  _1 = a + b;

BB2:
  _2 = a + b;    →  _2 = _1;     (CSE: BB1 dominates, _1 is available)

BB3:
  _3 = a + b;    →  _3 = _1;     (same reasoning)
```

**Example — jump threading:**

```
BB1:
  if (x_1 == 0) goto BB2; else goto BB3;
BB2:
  ...
  if (x_1 == 0) goto BB4; else goto BB5;
  ↓
  ;; Threaded: BB1→BB2 path knows x_1==0, so second test always true
  ;; Jump directly BB1 → BB2 → BB4, eliminating the second branch
```

**Files:** `gcc/tree-ssa-dom.cc`, `gcc/dominance.cc`

### 4. Dataflow Analysis (DF)

**What:** The [DF](GCC_GLOSSARY.md#df) framework (`df_analyze()` in `gcc/df-core.cc`) computes liveness, reaching definitions, and use-def/def-use chains over RTL. It maintains this information incrementally as passes modify instructions.

**Why it matters:** Almost every RTL pass needs to know "is this register live here?" or "who uses this definition?" DF provides these answers. [IRA](GCC_GLOSSARY.md#ira) depends on accurate liveness to know which registers conflict. Post-RA passes like `cprop_hardreg` and `fast_rtl_dce` use DF to find dead values.

**Three problems DF solves:**

| Problem | Direction | Answer |
|---------|-----------|--------|
| Reaching defs | Forward | "Which definitions of reg X could reach this point?" |
| Liveness | Backward | "Is reg X used on any path from here to the function exit?" |
| Use-def chains | — | "Which insn defined the value in reg X that this insn uses?" |

**m68k gotcha:** When modifying insns in a pass where DF is active, you **must** call `df_insn_rescan(insn)` after each modification. Failing to do so leaves stale DF references that cause use-after-free crashes in later passes (e.g., `sched2`'s `df_note_compute`). `SET_INSN_DELETED` does *not* notify DF — use `delete_insn()` instead. See [M68K_OPTIMIZATIONS.md §3](M68K_OPTIMIZATIONS.md#3-autoincrement-optimization-pass) for a real example of this bug.

**Files:** `gcc/df-core.cc`, `gcc/df-scan.cc`, `gcc/df-problems.cc`

### 5. Combine

**What:** `pass_combine` (7.33, `combine_instructions()` in `gcc/combine.cc`) tries to merge 2, 3, or 4 adjacent [insns](GCC_GLOSSARY.md#insn) into a single insn. It substitutes the source of earlier insns into later ones via `try_combine()`, validates costs with `combine_validate_cost()`, and checks if the result matches a `define_insn` pattern via `recog()` (`gcc/recog.cc`).

**Why it matters:** Combine is the single most impactful RTL pass. It's where multi-instruction sequences collapse into single m68k instructions. Without combine, GCC generates code that looks like a naive register-to-register machine.

**Examples of combine on m68k:**

```
;; Two insns → one (clear memory)
(set (reg d0) (const_int 0))
(set (mem (reg a0)) (reg d0))
  → (set (mem (reg a0)) (const_int 0))       ;; clr.l (a0)

;; Two insns → one (test-and-branch)
(set (reg cc) (compare (reg d0) (const_int 0)))
(set (pc) (if_then_else (eq (reg cc) ...) ...))
  → (set (pc) (if_then_else (eq (reg d0) (const_int 0)) ...))
  ;; tst.l d0 + beq → tst.l d0; beq (merged into one pattern)

;; Three insns → one (effective address)
(set (reg d1) (ashift (reg d0) (const_int 2)))
(set (reg a1) (plus (reg a0) (reg d1)))
  → (set (reg a1) (plus (reg a0) (ashift (reg d0) (const_int 2))))
  ;; lea (a0,d0.l*4),a1
```

Combine only succeeds when the merged RTL matches a `define_insn` pattern. If `m68k.md` doesn't have a pattern for the combined form, the merge fails silently. Adding new `.md` patterns is how you teach combine new tricks.

**Files:** `gcc/combine.cc`, `gcc/config/m68k/m68k.md` (patterns combine matches against)

### 6. IRA (Register Allocation)

**What:** IRA (Integrated Register Allocator, [Phase 8](GCC_PASSES.md#phase-8-register-allocation)) assigns physical registers to the virtual registers used by RTL. When demand exceeds supply, values are *spilled* to stack memory and *reloaded* when needed.

**Why it matters:** RA is the hard constraint that shapes everything. Pre-RA passes can assume unlimited registers and focus on reducing operation count. Post-RA passes must work within the fixed register set. The quality of RA determines how often values ping-pong between registers and stack — each spill/reload adds two memory accesses.

**m68k register classes:**

| Class | Registers | Used for |
|-------|-----------|----------|
| `DATA_REGS` | `d0`–`d7` | Arithmetic, shifts, multiplies, byte operations |
| `ADDR_REGS` | `a0`–`a6` | Memory base/index, pointer arithmetic |
| `FP_REGS` | `fp0`–`fp7` | Floating-point (68881/68882, not 68000) |

IRA's allocator works in two phases:

1. **Coloring:** Assign registers using graph coloring (`color()` in `gcc/ira-color.cc`). Pseudo-registers that interfere (are live at the same time) get different colors (physical registers).
2. **Spilling:** When coloring fails (not enough registers), pick the least-costly pseudo to spill to memory (`assign_hard_reg()` in `gcc/ira-color.cc`).

**m68k hook:** `TARGET_IRA_CHANGE_PSEUDO_ALLOCNO_CLASS` (`m68k_ira_change_pseudo_allocno_class()` in `gcc/config/m68k/m68k.cc`) promotes pseudos used as memory bases from `DATA_REGS` to `ADDR_REGS`, avoiding costly data→address register moves.

**Files:** `gcc/ira.cc`, `gcc/ira-color.cc`, `gcc/ira-lives.cc`, `gcc/lra.cc` ([LRA](GCC_GLOSSARY.md#lra) — constraint-based reload)

### 7. PRE/FRE

**What:** [FRE](GCC_GLOSSARY.md#fre) (Full Redundancy Elimination) removes computations that are fully redundant — the same expression is already computed on *all* paths to the current point. [PRE](GCC_GLOSSARY.md#pre) (Partial Redundancy Elimination) goes further: it inserts computations on paths where the expression is *not* available (`insert_into_preds_of_block()`), making it fully redundant, then eliminates the original (`eliminate_with_rpo_vn()`). Both in `gcc/tree-ssa-pre.cc`.

**Why it matters:** PRE subsumes CSE, loop-invariant code motion, and partial dead code elimination. It moves computations out of loops, eliminates repeated evaluations across branches, and reduces total operation count.

**Example — PRE hoisting out of a loop:**

```c
for (int i = 0; i < n; i++)
    a[i] = x + y;     // x+y is loop-invariant
```

```
;; Before PRE                ;; After PRE
loop:                        entry:
  _t = x + y;                 _t = x + y;      ← inserted
  a[i] = _t;                loop:
  ...                          a[i] = _t;       ← now uses precomputed value
```

PRE detects that `x + y` is *partially* redundant (available on the back edge, not on entry), inserts a copy on the entry edge, and now the loop body reuses it.

**FRE** is simpler and cheaper — it runs multiple times (passes 2.25, 5.23, 5.91, 5.109) because earlier optimizations create new redundancies. PRE runs once (5.56) as a loop optimization.

**PRE and edge splitting:** PRE sometimes needs to insert computations on CFG edges that don't have a block. It does this by *splitting* the edge — inserting a new empty BB on the edge and placing the computation there. Normally this is harmless, but for self-loop edges (a BB that branches back to itself), splitting creates a new latch BB that adds a jump per iteration and breaks auto-increment patterns. On m68k, `--param=pre-no-self-loop-insert=1` suppresses this, keeping tight loops in a single BB where `(a0)+` addressing works naturally. See [M68K_OPTIMIZATIONS.md §3](M68K_OPTIMIZATIONS.md#3-autoincrement-optimization-pass).

**Files:** `gcc/tree-ssa-pre.cc` (PRE), `gcc/tree-ssa-sccvn.cc` (value numbering used by FRE/PRE), `gcc/gcse.cc` (RTL PRE, self-loop suppression)

