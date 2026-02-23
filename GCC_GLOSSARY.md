# GCC Glossary

Terms used in [GCC_ARCHITECTURE.md](GCC_ARCHITECTURE.md), [GCC_PASSES.md](GCC_PASSES.md), and [M68K_OPTIMIZATIONS.md](M68K_OPTIMIZATIONS.md).

<a id="allocno"></a>
**allocno** — IRA's representation of a pseudo-register within a specific loop region. Each pseudo gets one allocno per loop level in `ira-region=mixed`/`all` mode. Allocnos at different levels are linked as parent/child pairs; a **pass-through allocno** has zero references at its level (live but not used there). See [IRA](#ira).

<a id="ast"></a>
**AST** (Abstract Syntax Tree) — Tree representation of parsed source code. In GCC, the AST is [GENERIC](#generic). Each node represents a language construct (expression, statement, declaration).

<a id="bb"></a>
**BB** (Basic Block) — A straight-line sequence of instructions with one entry point and one exit point. No branches in the middle, no jumps into the middle. The fundamental unit of [CFG](#cfg) analysis.

<a id="cc"></a>
**CC** (Condition Codes) — Processor flags (N, Z, V, C) set by arithmetic and move instructions. On m68k, most instructions set CC, so `final` can often elide explicit `tst`/`cmp` by tracking which CC is already valid.

<a id="ccp"></a>
**CCP** (Conditional Constant Propagation) — [SSA](#ssa)-based pass that propagates constants through the program, including through branches. `if (1) x=2; else x=3;` → `x=2;` and the else-branch is eliminated.

<a id="cfg"></a>
**CFG** (Control Flow Graph) — Graph where [BBs](#bb) are nodes and edges represent branches/fallthrough. Built during gimplification (1.11) and maintained through all subsequent passes.

<a id="combine"></a>
**combine** — RTL pass (7.33) that merges 2–4 adjacent instructions into one. See [Foundation Passes: Combine](GCC_ARCHITECTURE.md#5-combine).

<a id="cse"></a>
**CSE** (Common Subexpression Elimination) — Replacing duplicate computations with reuse of a previously computed value. Operates at both GIMPLE (via [FRE](#fre)/[PRE](#pre)) and RTL (7.6, 7.26) levels.

<a id="dce"></a>
**DCE** (Dead Code Elimination) — Removes instructions whose results are never used. Runs multiple times at GIMPLE level (e.g. 5.47, 5.62) and at RTL (7.31, 9.19).

<a id="doloop"></a>
**doloop** — RTL pass (7.21) that converts counted loops into hardware loop instructions. On m68k, maps to `dbra` (decrement-and-branch). Requires [VRP](#vrp) to prove the counter fits in 16 bits. See [Chapter 2 §6](GCC_ARCHITECTURE.md#6-rtl-optimization-pre-ra).

<a id="df"></a>
**DF** (Dataflow Framework) — GCC's infrastructure for computing liveness, reaching definitions, and def-use chains over RTL. See [Foundation Passes: DF](GCC_ARCHITECTURE.md#4-dataflow-analysis-df).

<a id="dse"></a>
**DSE** (Dead Store Elimination) — Removes stores to memory locations that are overwritten before being read. `*p = 1; *p = 2;` → `*p = 2;`.

<a id="fre"></a>
**FRE** (Full Redundancy Elimination) — Eliminates computations that are redundant on *all* paths. Cheaper than [PRE](#pre) and runs multiple times. See [Foundation Passes: PRE/FRE](GCC_ARCHITECTURE.md#7-prefre).

<a id="generic"></a>
**GENERIC** — GCC's language-independent [AST](#ast). Output of the C/C++ parser, input to gimplification. Preserves source-level structure (nested expressions, structured loops).

<a id="gimple"></a>
**GIMPLE** — GCC's high-level [IR](#ir). Three-address code: each statement has at most one operation, with explicit temporaries for sub-expressions. Named after "three-address code" → "triple" → "gimple".

<a id="insn"></a>
**INSN** — An RTL instruction. In GCC's internal representation, insns are doubly-linked list nodes containing an RTL expression (the pattern) and metadata (UID, basic block, notes). Not all insns emit code — `NOTE` and `BARRIER` insns are structural.

<a id="ipa"></a>
**IPA** (Inter-Procedural Analysis) — Passes that analyze or transform across function boundaries. Includes inlining (3.11), constant propagation (3.8), and pure/const detection (3.13). Run in [Phases 2–4](GCC_PASSES.md#phase-2-small-ipa-passes).

<a id="ir"></a>
**IR** (Intermediate Representation) — Any representation between source and machine code. GCC uses three main IRs: [GENERIC](#generic), [GIMPLE](#gimple), and [RTL](#rtl).

<a id="ira"></a>
**IRA** (Integrated Register Allocator) — GCC's register allocator (8.1). Uses graph coloring with spilling. See [Foundation Passes: IRA](GCC_ARCHITECTURE.md#6-ira-register-allocation).

<a id="inc-dec"></a>
**inc_dec** — RTL pass (7.29) that folds address+increment sequences into [POST_INC](#postinc)/[PRE_DEC](#postinc) addressing modes. See [Chapter 2 §6](GCC_ARCHITECTURE.md#6-rtl-optimization-pre-ra).

<a id="iv"></a>
**IV** (Induction Variable) — A variable that changes by a fixed amount each loop iteration. Typically loop counters (`i++`) and pointer advances (`p += 4`).

<a id="ivopts"></a>
**IVOPTS** (Induction Variable Optimizations) — GIMPLE pass (5.95) that selects the best set of [IVs](#iv) for a loop. On m68k, this is where integer-indexed loops become pointer-chasing loops suitable for `(a0)+`. See [M68K_OPTIMIZATIONS.md §2](M68K_OPTIMIZATIONS.md#2-induction-variable-optimization).

<a id="lim"></a>
**LIM** (Loop Invariant Motion) — Moves computations that produce the same result every iteration to before the loop. `for(i) { t = a+b; }` → `t = a+b; for(i) { }`.

<a id="loop-unrolling"></a>
**loop unrolling** — RTL pass (7.20) that replicates the loop body N times to reduce branch overhead. On m68k, uses jump-table remainder dispatch and disables IV splitting to preserve auto-increment chains. See [Chapter 2 §6](GCC_ARCHITECTURE.md#6-rtl-optimization-pre-ra).

<a id="lra"></a>
**LRA** (Local Register Allocator) — GCC's constraint resolution pass (8.2), replacing the legacy `reload` (scheduled for removal in GCC 16). Resolves register constraints that [IRA](#ira) couldn't satisfy — inserts spills, reloads, and register-register moves. Default for most targets since GCC 5; m68k switched to LRA in this branch. See [GCC_ARCHITECTURE.md §7](GCC_ARCHITECTURE.md#7-register-allocation).

<a id="peephole1"></a>
**peephole1** — Legacy peephole optimizer that runs inside `final_scan_insn()` during assembly output. Defined via `define_peephole` in the `.md` file. Matches RTL insns but emits raw assembly text directly — no new RTL is generated, so later passes cannot see the result. Largely superseded by [peephole2](#peephole2).

<a id="peephole2"></a>
**peephole2** — Post-RA pattern matcher (9.14) that replaces sequences of 2–5 adjacent insns with better sequences. Defined via `define_peephole2` in the `.md` file, it produces replacement RTL that goes through normal `recog()` and constraint checking. On m68k, used for store merging, mem-to-mem moves, and sign-extension elimination.

<a id="phi"></a>
**PHI** — [SSA](#ssa) pseudo-function at control flow merge points. `x_3 = PHI(x_1, x_2)` means "x_3 is x_1 if we came from the first predecessor, x_2 if from the second." See [Foundation Passes: SSA](GCC_ARCHITECTURE.md#2-ssa-and-phi-nodes).

<a id="postinc"></a>
**POST_INC/PRE_DEC** — RTL [RTX](#rtx) expressions representing auto-increment/decrement addressing. `(mem (post_inc reg))` means "access memory at reg, then add the access size to reg." On m68k: `(a0)+` and `-(a0)`.

<a id="pre"></a>
**PRE** (Partial Redundancy Elimination) — Inserts computations on paths where an expression is missing, making it fully redundant and eliminable. Subsumes [CSE](#cse) and [LIM](#lim). See [Foundation Passes: PRE/FRE](GCC_ARCHITECTURE.md#7-prefre).

<a id="ra"></a>
**RA** (Register Allocation) — The process of mapping virtual registers to physical registers. See [IRA](#ira).

<a id="rtl"></a>
**RTL** (Register Transfer Language) — GCC's low-level [IR](#ir). Each instruction is an [RTX](#rtx) expression tree describing a register transfer: `(set dst src)`. Closely mirrors machine instructions but uses virtual registers until [RA](#ra).

<a id="rtx"></a>
**RTX** (RTL eXpression) — A node in an RTL expression tree. Common RTX codes: `SET`, `PLUS`, `MEM`, `REG`, `CONST_INT`, `IF_THEN_ELSE`. The RTX is the "what"; the [INSN](#insn) is the container.

<a id="sibcall"></a>
**sibcall** (sibling call / tail call) — Optimization where `call` + `return` is replaced by a single jump when the callee's return value is the caller's return value. On m68k: `jsr func; rts` → `jra func`. See [M68K_OPTIMIZATIONS.md §15](M68K_OPTIMIZATIONS.md#15-sibcall-optimization).

<a id="scc"></a>
**SCC** (Strongly Connected Component) — A maximal subset of a directed graph where every node is reachable from every other. Used in SSA optimization (value numbering walks SCCs of the SSA graph) and in call graph analysis.

<a id="scev"></a>
**SCEV** (Scalar Evolution) — Framework that describes how [SSA](#ssa) variables change across loop iterations. Represents IVs as `{initial, +, step}` — e.g. `{0, +, 1}` for a counter starting at 0 incrementing by 1. Used by [IVOPTS](#ivopts) and loop analysis.

<a id="store-merging"></a>
**store merging** — GIMPLE pass (5.124) that combines adjacent stores to contiguous memory into wider operations. `clr.w (a0); clr.w 2(a0)` → `clr.l (a0)`. Requires stores to be in offset order — see [M68K_OPTIMIZATIONS.md §11](M68K_OPTIMIZATIONS.md#11-memory-access-reordering).

<a id="sra"></a>
**SRA** (Scalar Replacement of Aggregates) — Replaces struct/array variables with individual scalar variables when the aggregate is only accessed field-by-field. `struct {int a,b} s; s.a=1; s.b=2;` → `int a=1; int b=2;`.

<a id="ssa"></a>
**SSA** (Static Single Assignment) — IR form where every variable is assigned exactly once. Multiple assignments to the same source variable become distinct SSA versions (`x_1`, `x_2`, ...) with [PHI](#phi) nodes at merge points. See [Foundation Passes: SSA](GCC_ARCHITECTURE.md#2-ssa-and-phi-nodes).

<a id="vrp"></a>
**VRP** (Value Range Propagation) — Tracks the possible value range of each [SSA](#ssa) variable (e.g. `x_1 ∈ [0, 255]`). Enables optimizations like eliminating impossible branches and narrowing types. On m68k, VRP determines if a loop counter fits in 16 bits for `dbra`.
