# GCC Optimization Passes for m68k Target

This document lists all optimization passes executed by GCC 15 for the m68k-atari-mintelf target, in execution order.

## Legend

- **IR**: Intermediate Representation
  - `GIMPLE` - GCC's high-level IR, close to source
  - `GIMPLE-SSA` - GIMPLE in Static Single Assignment form
  - `RTL` - Register Transfer Language, low-level IR
  - `RTL-CFG` - RTL in CFG layout mode
  - `IPA` - Inter-Procedural Analysis (operates across functions)
  - `ASM` - Final assembly generation

---

## Phase 1: Lowering Passes

Convert high-level constructs to basic GIMPLE.

| # | Pass | IR | Purpose | Related | Example |
|---|------|----|---------|---------|---------|
| 1.1 | `pass_warn_unused_result` | GIMPLE | Warn when `[[nodiscard]]` return values are ignored | - | `foo();` where foo returns `[[nodiscard]]` → warning |
| 1.2 | `pass_diagnose_omp_blocks` | GIMPLE | Diagnose invalid OpenMP constructs | `pass_lower_omp` | Report mismatched `#pragma omp` |
| 1.3 | `pass_diagnose_tm_blocks` | GIMPLE | Diagnose invalid transactional memory constructs | `pass_lower_tm` | Report invalid `__transaction` |
| 1.4 | `pass_omp_oacc_kernels_decompose` | GIMPLE | Decompose OpenACC kernels regions | `pass_expand_omp` | Split complex OpenACC regions |
| 1.5 | `pass_lower_omp` | GIMPLE | Lower OpenMP directives | `pass_expand_omp` | `#pragma omp parallel` → runtime calls |
| 1.6 | `pass_lower_cf` | GIMPLE | Lower control flow constructs | `pass_build_cfg` | Complex conditionals → simple branches |
| 1.7 | `pass_lower_tm` | GIMPLE | Lower transactional memory constructs | - | `__transaction` → TM library calls |
| 1.8 | `pass_refactor_eh` | GIMPLE | Refactor exception handling regions | `pass_lower_eh` | Merge/split EH regions |
| 1.9 | `pass_lower_eh` | GIMPLE | Lower exception handling | `pass_cleanup_eh` | `try/catch` → EH tables |
| 1.10 | `pass_coroutine_lower_builtins` | GIMPLE | Lower C++20 coroutine builtins | `pass_coroutine_early_expand_ifns` | `co_await` → state machine |
| 1.11 | `pass_build_cfg` | GIMPLE | Build Control Flow Graph | - | Linear code → basic blocks + edges |
| 1.12 | `pass_warn_function_return` | GIMPLE | Warn about missing return statements | - | non-void function with no return → warning |
| 1.13 | `pass_coroutine_early_expand_ifns` | GIMPLE | Expand coroutine internal functions | - | Coroutine IFNs → explicit operations |
| 1.14 | `pass_expand_omp` | GIMPLE | Expand OpenMP parallel regions | `pass_lower_omp` | OMP constructs → outlined functions |
| 1.15 | `pass_build_cgraph_edges` | GIMPLE | Build call graph edges | IPA passes | Connect caller → callee in call graph |

---

## Phase 2: Small IPA Passes

Initial inter-procedural analysis and early optimizations.

| # | Pass | IR | Purpose | Related | Example |
|---|------|----|---------|---------|---------|
| 2.1 | `pass_ipa_free_lang_data` | IPA | Free language-specific data | - | Release C++/ObjC frontend data |
| 2.2 | `pass_ipa_function_and_variable_visibility` | IPA | Compute symbol visibility | - | Mark functions as local/global |
| 2.3 | `pass_ipa_strub_mode` | IPA | Determine stack scrubbing mode | `pass_ipa_strub` | Identify functions needing stack cleanup |

### Build SSA Sub-passes

| # | Pass | IR | Purpose | Related | Example |
|---|------|----|---------|---------|---------|
| 2.4 | `pass_fixup_cfg` | GIMPLE | Fix control flow graph | - | Remove unreachable blocks |
| 2.5 | `pass_build_ssa` | GIMPLE-SSA | Convert to SSA form | - | `x = 1; x = 2` → `x_1 = 1; x_2 = 2` |
| 2.6 | `pass_walloca` | GIMPLE-SSA | Warn about `alloca()` usage | - | `alloca(n)` with unbounded n → warning |
| 2.7 | `pass_warn_printf` | GIMPLE-SSA | Warn about printf format issues | - | `printf("%d", "str")` → warning |
| 2.8 | `pass_warn_nonnull_compare` | GIMPLE-SSA | Warn about nonnull comparisons | - | `if (nonnull_ptr == NULL)` → warning |
| 2.9 | `pass_early_warn_uninitialized` | GIMPLE-SSA | Early uninitialized variable warnings | `pass_late_warn_uninitialized` | `int x; return x;` → warning |
| 2.10 | `pass_warn_access` | GIMPLE-SSA | Warn about invalid memory access | - | Out of bounds array access → warning |
| 2.11 | `pass_ubsan` | GIMPLE-SSA | Instrument for undefined behavior | - | Add runtime UB checks |
| 2.12 | `pass_nothrow` | GIMPLE-SSA | Mark nothrow functions | - | Detect functions that don't throw |
| 2.13 | `pass_rebuild_cgraph_edges` | GIMPLE | Rebuild call graph edges | - | Update after transformations |

### Local Optimization Sub-passes

| # | Pass | IR | Purpose | Related | Example |
|---|------|----|---------|---------|---------|
| 2.14 | `pass_local_fn_summary` | IPA | Compute function summaries | `pass_ipa_inline` | Estimate code size, time |
| 2.15 | `pass_early_inline` | IPA | Early inlining of small functions | `pass_ipa_inline` | Inline tiny functions immediately |
| 2.16 | `pass_warn_recursion` | IPA | Warn about infinite recursion | - | `f() { f(); }` → warning |

### All Early Optimizations Sub-passes

| # | Pass | IR | Purpose | Related | Example |
|---|------|----|---------|---------|---------|
| 2.17 | `pass_remove_cgraph_callee_edges` | IPA | Remove call graph edges | - | Clean stale edges |
| 2.18 | `pass_early_object_sizes` | GIMPLE-SSA | Evaluate `__builtin_object_size` | `pass_object_sizes` | `__builtin_object_size(p,0)` → 100 |
| 2.19 | `pass_ccp` | GIMPLE-SSA | Conditional Constant Propagation | - | `if (1) x=2; else x=3;` → `x=2;` |
| 2.20 | `pass_forwprop` | GIMPLE-SSA | Forward propagation | - | `a=b; c=a+1` → `c=b+1` |
| 2.21 | `pass_early_thread_jumps` | GIMPLE-SSA | Early jump threading | `pass_thread_jumps` | Shortcut predictable branches |
| 2.22 | `pass_sra_early` | GIMPLE-SSA | Scalar Replacement of Aggregates | `pass_sra` | `struct {int a,b}` → `int a; int b;` |
| 2.23 | `pass_build_ealias` | GIMPLE-SSA | Build early alias info | - | Compute memory aliasing |
| 2.24 | `pass_phiprop` | GIMPLE-SSA | Propagate through PHI nodes | - | Simplify PHI selections |
| 2.25 | `pass_fre` | GIMPLE-SSA | Full Redundancy Elimination | `pass_pre` | `a=x+y; b=x+y` → `a=x+y; b=a` |
| 2.26 | `pass_early_vrp` | GIMPLE-SSA | Early Value Range Propagation | `pass_vrp` | `if (x>0) if (x>0)` → `if (x>0)` |
| 2.27 | `pass_merge_phi` | GIMPLE-SSA | Merge PHI nodes | - | Combine redundant PHIs |
| 2.28 | `pass_dse` | GIMPLE-SSA | Dead Store Elimination | - | `*p=1; *p=2` → `*p=2` |
| 2.29 | `pass_cd_dce` | GIMPLE-SSA | Control-Dependent Dead Code Elim | `pass_dce` | Remove unused control-dependent code |
| 2.30 | `pass_phiopt` | GIMPLE-SSA | PHI node optimization | - | `x = cond ? a : a` → `x = a` |
| 2.31 | `pass_tail_recursion` | GIMPLE-SSA | Tail recursion elimination | `pass_tail_calls` | `f(n) {return f(n-1);}` → loop |
| 2.32 | `pass_if_to_switch` | GIMPLE-SSA | Convert if chains to switch | `pass_convert_switch` | `if(x==1)..elif(x==2)` → `switch(x)` |
| 2.33 | `pass_convert_switch` | GIMPLE-SSA | Optimize switch statements | `pass_lower_switch` | Convert to jump table or tree |
| 2.34 | `pass_cleanup_eh` | GIMPLE-SSA | Clean up exception handling | - | Remove dead EH regions |
| 2.35 | `pass_sccopy` | GIMPLE-SSA | SCC-based copy propagation | - | Propagate copies in SCCs |
| 2.36 | `pass_profile` | GIMPLE-SSA | Profile-guided optimization prep | - | Insert profiling instrumentation |
| 2.37 | `pass_local_pure_const` | IPA | Detect pure/const functions | `pass_ipa_pure_const` | Mark `f(x) {return x*2;}` as pure |
| 2.38 | `pass_modref` | IPA | Compute modification/reference info | `pass_ipa_modref` | Track what memory functions access |
| 2.39 | `pass_split_functions` | IPA | Split cold/hot code | - | Move cold code to separate section |
| 2.40 | `pass_strip_predict_hints` | GIMPLE-SSA | Remove prediction hints | - | Clean up `__builtin_expect` |
| 2.41 | `pass_release_ssa_names` | GIMPLE-SSA | Release unused SSA names | - | Free unused SSA variables |

### OpenACC/Parallel Sub-passes

| # | Pass | IR | Purpose | Related | Example |
|---|------|----|---------|---------|---------|
| 2.42 | `pass_ipa_pta` | IPA | Points-to analysis | - | Determine what pointers can point to |
| 2.43 | `pass_ipa_oacc_kernels` | IPA | OpenACC kernels optimization | - | Optimize accelerator code |
| 2.44 | `pass_ch` | GIMPLE-SSA | Copy headers into loops | - | Duplicate loop headers for optimization |
| 2.45 | `pass_lim` | GIMPLE-SSA | Loop Invariant Motion | - | `for(i) {x=a+b}` → `t=a+b; for(i) {x=t}` |
| 2.46 | `pass_dominator` | GIMPLE-SSA | Dominator-based optimization | - | Eliminate via dominance relations |
| 2.47 | `pass_dce` | GIMPLE-SSA | Dead Code Elimination | - | Remove unreachable/unused code |
| 2.48 | `pass_parallelize_loops` | GIMPLE-SSA | Auto-parallelize loops | - | Sequential loop → parallel threads |
| 2.49 | `pass_expand_omp_ssa` | GIMPLE-SSA | Expand OMP in SSA form | - | Lower OMP after SSA |

### Remaining Small IPA Passes

| # | Pass | IR | Purpose | Related | Example |
|---|------|----|---------|---------|---------|
| 2.50 | `pass_ipa_remove_symbols` | IPA | Remove unused symbols | - | Delete unreferenced functions |
| 2.51 | `pass_ipa_strub` | IPA | Stack scrubbing implementation | `pass_ipa_strub_mode` | Insert stack cleanup code |
| 2.52 | `pass_target_clone` | IPA | Clone for different targets | - | Create FMV function versions |
| 2.53 | `pass_ipa_auto_profile` | IPA | Auto-profile optimization | - | Apply AutoFDO data |
| 2.54 | `pass_ipa_tree_profile` | IPA | Tree profiling | - | Insert profile counters |
| 2.55 | `pass_feedback_split_functions` | IPA | Profile-guided function splitting | `pass_split_functions` | Split based on profile data |
| 2.56 | `pass_ipa_free_fn_summary` | IPA | Free function summaries | - | Release analysis memory |
| 2.57 | `pass_ipa_increase_alignment` | IPA | Increase data alignment | - | Align hot data for cache |
| 2.58 | `pass_ipa_tm` | IPA | Transactional memory IPA | `pass_lower_tm` | Cross-function TM optimization |
| 2.59 | `pass_ipa_lower_emutls` | IPA | Lower emulated TLS | - | TLS → emulation library calls |

---

## Phase 3: Regular IPA Passes

Full inter-procedural analysis after all functions are available.

| # | Pass | IR | Purpose | Related | Example |
|---|------|----|---------|---------|---------|
| 3.1 | `pass_analyzer` | IPA | Static analyzer | - | Detect bugs across functions |
| 3.2 | `pass_ipa_odr` | IPA | One Definition Rule checking | - | Detect ODR violations |
| 3.3 | `pass_ipa_whole_program_visibility` | IPA | Whole-program visibility | - | Mark internal functions |
| 3.4 | `pass_ipa_profile` | IPA | IPA profiling | - | Propagate profile info |
| 3.5 | `pass_ipa_icf` | IPA | Identical Code Folding | - | Merge identical functions |
| 3.6 | `pass_ipa_devirt` | IPA | Devirtualization | - | `vptr->f()` → direct call |
| 3.7 | `pass_ipa_cdtor_merge` | IPA | Constructor/Destructor merging | - | Combine static init functions |
| 3.8 | `pass_ipa_cp` | IPA | Constant Propagation IPA | `pass_ccp` | Propagate constants across calls |
| 3.9 | `pass_ipa_sra` | IPA | Scalar Replacement IPA | `pass_sra` | Split struct parameters |
| 3.10 | `pass_ipa_fn_summary` | IPA | Function summaries | `pass_ipa_inline` | Compute for inlining decisions |
| 3.11 | `pass_ipa_inline` | IPA | Function inlining | `pass_early_inline` | Inline profitable functions |
| 3.12 | `pass_ipa_locality_cloning` | IPA | Locality-based cloning | - | Clone for cache locality |
| 3.13 | `pass_ipa_pure_const` | IPA | Pure/const detection IPA | `pass_local_pure_const` | Mark pure/const across calls |
| 3.14 | `pass_ipa_modref` | IPA | Modification/reference IPA | `pass_modref` | Track memory access cross-function |
| 3.15 | `pass_ipa_reference` | IPA | Reference analysis | - | Track what's referenced |
| 3.16 | `pass_ipa_single_use` | IPA | Single use detection | - | Find singly-used functions |
| 3.17 | `pass_ipa_comdats` | IPA | COMDAT optimization | - | Privatize COMDAT symbols |

---

## Phase 4: Late IPA Passes

| # | Pass | IR | Purpose | Related | Example |
|---|------|----|---------|---------|---------|
| 4.1 | `pass_ipa_pta` (2) | IPA | Late points-to analysis | - | Refined pointer analysis |
| 4.2 | `pass_omp_simd_clone` | IPA | Create SIMD clones | - | Clone functions for vectorization |

---

## Phase 5: All Optimizations (Per-Function)

Main optimization pipeline run on each function.

| # | Pass | IR | Purpose | Related | Example |
|---|------|----|---------|---------|---------|
| 5.1 | `pass_fixup_cfg` | GIMPLE | Fix CFG after IPA | - | Clean up after inlining |
| 5.2 | `pass_lower_eh_dispatch` | GIMPLE | Lower EH dispatch | - | Simplify EH landing pads |
| 5.3 | `pass_oacc_loop_designation` | GIMPLE | OpenACC loop designation | - | Mark accelerator loops |
| 5.4 | `pass_omp_oacc_neuter_broadcast` | GIMPLE | OpenACC broadcast optimization | - | Optimize broadcasts |
| 5.5 | `pass_oacc_device_lower` | GIMPLE | Lower for OpenACC device | - | Device-specific lowering |
| 5.6 | `pass_omp_device_lower` | GIMPLE | Lower for OMP device | - | Offload code lowering |
| 5.7 | `pass_omp_target_link` | GIMPLE | OMP target linking | - | Link device/host code |
| 5.8 | `pass_adjust_alignment` | GIMPLE | Adjust alignments | - | Fix alignment requirements |
| 5.9 | `pass_harden_control_flow_redundancy` | GIMPLE | CFI hardening | - | Add control flow checks |

### Main Optimization Sub-passes

| # | Pass | IR | Purpose | Related | Example |
|---|------|----|---------|---------|---------|
| 5.10 | `pass_remove_cgraph_callee_edges` | IPA | Clean call graph | - | Remove stale edges |
| 5.11 | `pass_strip_predict_hints` | GIMPLE-SSA | Remove predictions | - | Clean `__builtin_expect` |
| 5.12 | `pass_ccp` (2) | GIMPLE-SSA | CCP with nonzero bits | - | Track non-zero bit patterns |
| 5.13 | `pass_object_sizes` | GIMPLE-SSA | Evaluate object sizes | - | `sizeof` optimization |
| 5.14 | `pass_post_ipa_warn` | GIMPLE-SSA | Post-IPA warnings | - | Warnings after inlining |
| 5.15 | `pass_warn_access` (2) | GIMPLE-SSA | Access warnings | - | Buffer overflow warnings |
| 5.16 | `pass_rebuild_frequencies` | GIMPLE-SSA | Rebuild block frequencies | - | Update profile after transforms |
| 5.17 | `pass_complete_unrolli` | GIMPLE-SSA | Complete unrolling | `pass_complete_unroll` | Fully unroll small loops |
| 5.18 | `pass_backprop` | GIMPLE-SSA | Backward propagation | `pass_forwprop` | Propagate uses backward |
| 5.19 | `pass_phiprop` (2) | GIMPLE-SSA | PHI propagation | - | PHI node simplification |
| 5.20 | `pass_forwprop` (2) | GIMPLE-SSA | Forward propagation | - | `a=b; c=a` → `c=b` |
| 5.21 | `pass_build_alias` | GIMPLE-SSA | Build alias info | - | Compute memory aliasing |
| 5.22 | `pass_return_slot` | GIMPLE-SSA | Return slot optimization | - | Avoid copy for return values |
| 5.23 | `pass_fre` (3) | GIMPLE-SSA | Full redundancy elimination | - | Eliminate redundant expressions |
| 5.24 | `pass_merge_phi` (2) | GIMPLE-SSA | Merge PHIs | - | Combine redundant PHIs |
| 5.25 | `pass_thread_jumps_full` | GIMPLE-SSA | Full jump threading | - | Thread through all conditions |
| 5.26 | `pass_vrp` | GIMPLE-SSA | Value Range Propagation | - | `if(x>0 && x>0)` → `if(x>0)` |
| 5.26a | **`m68k_pass_narrow_index_mult`** | GIMPLE-SSA | **Narrow 32→16-bit multiply** | m68k | **`jsr __mulsi3` → `muls.w #320,d0`** |
| 5.27 | `pass_array_bounds` | GIMPLE-SSA | Array bounds checking | - | Warn/optimize bounds |
| 5.28 | `pass_dse` (2) | GIMPLE-SSA | Dead Store Elimination | - | Remove overwritten stores |
| 5.29 | `pass_dce` (2) | GIMPLE-SSA | Dead Code Elimination | - | Remove dead assignments |
| 5.30 | `pass_stdarg` | GIMPLE-SSA | Optimize stdarg | - | `va_list` optimization |
| 5.31 | `pass_call_cdce` | GIMPLE-SSA | Conditional DCE for calls | - | Remove dead call results |
| 5.32 | `pass_cselim` | GIMPLE-SSA | Conditional store elimination | - | `if(c) *p=x` optimization |
| 5.33 | `pass_copy_prop` | GIMPLE-SSA | Copy propagation | - | `a=b; use(a)` → `use(b)` |
| 5.34 | `pass_tree_ifcombine` | GIMPLE-SSA | Combine if statements | - | `if(a) if(b)` → `if(a&&b)` |
| 5.35 | `pass_merge_phi` (3) | GIMPLE-SSA | PHI merging | - | Combine PHIs |
| 5.36 | `pass_phiopt` (2) | GIMPLE-SSA | PHI optimization | - | `phi(a,a)` → `a` |
| 5.37 | `pass_tail_recursion` (2) | GIMPLE-SSA | Tail recursion | - | Tail call → jump |
| 5.38 | `pass_ch` (2) | GIMPLE-SSA | Loop header copying | - | Copy loop headers |
| 5.39 | `pass_lower_complex` | GIMPLE-SSA | Lower complex arithmetic | - | `complex` → real/imag pairs |
| 5.40 | `pass_lower_bitint` | GIMPLE-SSA | Lower _BitInt | - | `_BitInt(N)` → library calls |
| 5.41 | `pass_sra` | GIMPLE-SSA | Scalar replacement | - | struct → scalars |
| 5.42 | `pass_thread_jumps` | GIMPLE-SSA | Jump threading | - | Shortcut branches |
| 5.43 | `pass_dominator` (2) | GIMPLE-SSA | Dominator optimization | - | Dominator-based CSE |
| 5.44 | `pass_copy_prop` (2) | GIMPLE-SSA | Copy propagation | - | Forward copies |
| 5.45 | `pass_isolate_erroneous_paths` | GIMPLE-SSA | Isolate UB paths | - | Mark UB code unreachable |
| 5.46 | `pass_reassoc` | GIMPLE-SSA | Reassociation | - | `(a+b)+c` → `a+(b+c)` |
| 5.47 | `pass_dce` (3) | GIMPLE-SSA | Dead code elimination | - | Remove dead code |
| 5.48 | `pass_forwprop` (3) | GIMPLE-SSA | Forward propagation | - | Propagate expressions |
| 5.49 | `pass_phiopt` (3) | GIMPLE-SSA | PHI optimization | - | Optimize PHI selections |
| 5.50 | `pass_ccp` (3) | GIMPLE-SSA | CCP | - | Constant propagation |
| 5.51 | `pass_expand_pow` | GIMPLE-SSA | Expand pow() calls | - | `pow(x,2)` → `x*x` |
| 5.52 | `pass_optimize_bswap` | GIMPLE-SSA | Byte swap optimization | - | Recognize bswap patterns |
| 5.53 | `pass_laddress` | GIMPLE-SSA | Lower address computation | - | Simplify address math |

### Loop Optimization Sub-passes

| # | Pass | IR | Purpose | Related | Example |
|---|------|----|---------|---------|---------|
| 5.54 | `pass_lim` (2) | GIMPLE-SSA | Loop Invariant Motion | - | Hoist invariants out of loops |
| 5.55 | `pass_walloca` (2) | GIMPLE-SSA | Alloca warnings | - | Warn in loops |
| 5.56 | `pass_pre` | GIMPLE-SSA | Partial Redundancy Elimination | `pass_fre` | More aggressive than FRE |
| 5.57 | `pass_sink_code` | GIMPLE-SSA | Code sinking | - | Move code to less frequent paths |
| 5.58 | `pass_sancov` | GIMPLE-SSA | Sanitizer coverage | - | Add coverage instrumentation |
| 5.59 | `pass_asan` | GIMPLE-SSA | AddressSanitizer | - | Memory error detection |
| 5.60 | `pass_tsan` | GIMPLE-SSA | ThreadSanitizer | - | Race detection |
| 5.61 | `pass_dse` (3) | GIMPLE-SSA | Dead Store Elimination | - | With DR analysis |
| 5.62 | `pass_dce` (4) | GIMPLE-SSA | DCE | - | Remove dead code |
| 5.63 | `pass_fix_loops` | GIMPLE-SSA | Fix loop structures | - | Discover/remove loops |
| 5.64 | `pass_tree_loop` | GIMPLE-SSA | Loop optimization container | - | Parent for loop passes |
| 5.65 | `pass_tree_loop_init` | GIMPLE-SSA | Initialize loop optimizer | - | Set up loop data |
| 5.66 | `pass_tree_unswitch` | GIMPLE-SSA | Loop unswitching | - | `for(i) if(c)` → `if(c) for(i)` |
| 5.67 | `pass_loop_split` | GIMPLE-SSA | Loop splitting | - | Split loops at boundaries |
| 5.68 | `pass_scev_cprop` | GIMPLE-SSA | SCEV constant prop | - | Scalar evolution analysis |
| 5.69 | `pass_loop_versioning` | GIMPLE-SSA | Loop versioning | - | Create specialized loop versions |
| 5.70 | `pass_loop_jam` | GIMPLE-SSA | Loop fusion/jamming | - | Combine adjacent loops |
| 5.71 | `pass_cd_dce` (2) | GIMPLE-SSA | Control-dependent DCE | - | Remove empty loops |
| 5.72 | `pass_iv_canon` | GIMPLE-SSA | IV canonicalization | - | Normalize induction variables |
| 5.73 | `pass_loop_distribution` | GIMPLE-SSA | Loop distribution | - | Split loop for parallelism |
| 5.74 | `pass_crc_optimization` | GIMPLE-SSA | CRC optimization | - | Recognize CRC patterns |
| 5.75 | `pass_linterchange` | GIMPLE-SSA | Loop interchange | - | Swap nested loop order |
| 5.76 | `pass_copy_prop` (3) | GIMPLE-SSA | Copy propagation | - | Clean up after loop opts |
| 5.77 | `pass_graphite` | GIMPLE-SSA | Polyhedral optimization | - | Complex loop transforms |
| 5.78 | `pass_graphite_transforms` | GIMPLE-SSA | Graphite transforms | - | Apply polyhedral changes |
| 5.79 | `pass_lim` (3) | GIMPLE-SSA | Loop invariant motion | - | Post-graphite LIM |
| 5.80 | `pass_copy_prop` (4) | GIMPLE-SSA | Copy propagation | - | Post-graphite cleanup |
| 5.81 | `pass_dce` (5) | GIMPLE-SSA | DCE | - | Post-graphite cleanup |
| 5.82 | `pass_parallelize_loops` (2) | GIMPLE-SSA | Auto-parallelization | - | Parallelize loops |
| 5.83 | `pass_expand_omp_ssa` (2) | GIMPLE-SSA | Expand OMP | - | Expand parallel regions |
| 5.84 | `pass_ch_vect` | GIMPLE-SSA | Loop header for vectorization | - | Prepare for vectorizer |
| 5.85 | `pass_if_conversion` | GIMPLE-SSA | If-conversion | - | `if(c)a=1;else a=2` → `a=c?1:2` |
| 5.86 | `pass_vectorize` | GIMPLE-SSA | Auto-vectorization | - | `for(i)a[i]=b[i]+c[i]` → SIMD |
| 5.87 | `pass_dce` (6) | GIMPLE-SSA | Post-vectorization DCE | - | Clean up |
| 5.88 | `pass_predcom` | GIMPLE-SSA | Predictive commoning | - | Reuse loop computations |
| 5.89 | `pass_complete_unroll` | GIMPLE-SSA | Complete loop unrolling | - | Fully unroll small loops |
| 5.90 | `pass_pre_slp_scalar_cleanup` | GIMPLE-SSA | Pre-SLP cleanup | - | Prepare for SLP |
| 5.91 | `pass_fre` (4) | GIMPLE-SSA | FRE | - | Pre-SLP redundancy elim |
| 5.92 | `pass_dse` (4) | GIMPLE-SSA | DSE | - | Pre-SLP dead stores |
| 5.93 | `pass_slp_vectorize` | GIMPLE-SSA | SLP vectorization | - | Straight-line code vectorization |
| 5.94 | `pass_loop_prefetch` | GIMPLE-SSA | Loop prefetching | - | Insert prefetch instructions |
| 5.95 | `pass_iv_optimize` | GIMPLE-SSA | IV optimization | - | Strength reduction of IVs |
| 5.95a | **`m68k_pass_autoinc_split`** | GIMPLE-SSA | **Split combined increments** | m68k | **Re-split for `(a0)+` addressing** |
| 5.96 | `pass_lim` (4) | GIMPLE-SSA | Final LIM | - | Late loop invariant motion |
| 5.97 | `pass_tree_loop_done` | GIMPLE-SSA | Finalize loop optimizer | - | Clean up loop data |

### Post-Loop Optimization Sub-passes

| # | Pass | IR | Purpose | Related | Example |
|---|------|----|---------|---------|---------|
| 5.98 | `pass_tree_no_loop` | GIMPLE-SSA | Non-loop container | - | When no loops exist |
| 5.99 | `pass_slp_vectorize` (2) | GIMPLE-SSA | SLP for non-loop | - | Vectorize straight-line code |
| 5.100 | `pass_simduid_cleanup` | GIMPLE-SSA | Clean SIMD uids | - | Remove SIMD metadata |
| 5.101 | `pass_lower_vector_ssa` | GIMPLE-SSA | Lower vector operations | - | Vector ops → scalars/libcalls |
| 5.102 | `pass_lower_switch` | GIMPLE-SSA | Lower switch statements | - | switch → if/else or table |
| 5.103 | `pass_cse_sincos` | GIMPLE-SSA | CSE sin/cos | - | `sin(x),cos(x)` → `sincos(x)` |
| 5.104 | `pass_cse_reciprocals` | GIMPLE-SSA | CSE reciprocals | - | `1/x, y/x` → `r=1/x, r, y*r` |
| 5.105 | `pass_reassoc` (2) | GIMPLE-SSA | Late reassociation | - | Final expression reordering |
| 5.106 | `pass_strength_reduction` | GIMPLE-SSA | Strength reduction | - | `x*4` → `x<<2` |
| 5.107 | `pass_split_paths` | GIMPLE-SSA | Path splitting | - | Duplicate for better opts |
| 5.108 | `pass_tracer` | GIMPLE-SSA | Superblock formation | - | Create superblocks |
| 5.109 | `pass_fre` (5) | GIMPLE-SSA | Late FRE | - | Final redundancy elim |
| 5.110 | `pass_thread_jumps` (2) | GIMPLE-SSA | Late jump threading | - | Final jump threading |
| 5.111 | `pass_dominator` (3) | GIMPLE-SSA | Late dominator | - | Final dominator opts |
| 5.112 | `pass_strlen` | GIMPLE-SSA | String length optimization | - | Optimize strlen/strcpy |
| 5.113 | `pass_thread_jumps_full` (2) | GIMPLE-SSA | Full threading | - | Complete jump threading |
| 5.114 | `pass_vrp` (2) | GIMPLE-SSA | Final VRP | - | Final value range |
| 5.115 | `pass_ccp` (4) | GIMPLE-SSA | Final CCP | - | Compute alignment/nonzero |
| 5.116 | `pass_warn_restrict` | GIMPLE-SSA | Restrict warnings | - | Warn about restrict violations |
| 5.117 | `pass_dse` (5) | GIMPLE-SSA | Final DSE | - | Last dead store elim |
| 5.118 | `pass_dce` (7) | GIMPLE-SSA | Final DCE | - | Last dead code elim |
| 5.119 | `pass_forwprop` (4) | GIMPLE-SSA | Final forwprop | - | Last forward propagation |
| 5.120 | `pass_sink_code` (2) | GIMPLE-SSA | Final sinking | - | Last code sinking |
| 5.121 | `pass_phiopt` (4) | GIMPLE-SSA | Final phiopt | - | Last PHI optimization |
| 5.122 | `pass_fold_builtins` | GIMPLE-SSA | Fold builtins | - | `sqrt(4.0)` → `2.0` |
| 5.123 | `pass_optimize_widening_mul` | GIMPLE-SSA | Widening multiply | - | Use wide multiply instructions |
| 5.123a | `m68k_pass_reorder_mem` | GIMPLE-SSA | **Memory reorder** | m68k | Reorders scattered struct accesses by offset |
| 5.124 | `pass_store_merging` | GIMPLE-SSA | Store merging | - | `*p=a; *(p+4)=b` → single store |
| 5.125 | `pass_cd_dce` (3) | GIMPLE-SSA | Control-dependent DCE | - | Final CD-DCE |
| 5.126 | `pass_sccopy` (2) | GIMPLE-SSA | SCC copy prop | - | Final copy propagation |
| 5.127 | `pass_tail_calls` | GIMPLE-SSA | Tail call optimization | - | `return f()` → jump to f |
| 5.128 | `pass_split_crit_edges` | GIMPLE-SSA | Split critical edges | - | For better code gen |
| 5.129 | `pass_late_warn_uninitialized` | GIMPLE-SSA | Late uninit warnings | - | Final uninitialized check |
| 5.130 | `pass_local_pure_const` (2) | IPA | Final pure/const | - | Final purity analysis |
| 5.131 | `pass_modref` (2) | IPA | Final modref | - | Final memory analysis |
| 5.132 | `pass_uncprop` | GIMPLE-SSA | Un-copy propagation | - | Replace constants with SSA names |

### Debug/Hardening Sub-passes

| # | Pass | IR | Purpose | Related | Example |
|---|------|----|---------|---------|---------|
| 5.133 | `pass_assumptions` | GIMPLE-SSA | Handle `[[assume]]` | - | Process C++23 assume |
| 5.134 | `pass_tm_init` | GIMPLE-SSA | TM initialization | - | Set up TM |
| 5.135 | `pass_tm_mark` | GIMPLE-SSA | TM marking | - | Mark TM regions |
| 5.136 | `pass_tm_memopt` | GIMPLE-SSA | TM memory optimization | - | Optimize TM memory |
| 5.137 | `pass_tm_edges` | GIMPLE-SSA | TM edge insertion | - | Insert TM edges |
| 5.138 | `pass_simduid_cleanup` (2) | GIMPLE-SSA | SIMD cleanup | - | Final SIMD cleanup |
| 5.139 | `pass_vtable_verify` | GIMPLE-SSA | Vtable verification | - | Add vtable checks |
| 5.140 | `pass_lower_vaarg` | GIMPLE-SSA | Lower va_arg | - | va_arg → explicit code |
| 5.141 | `pass_lower_vector` | GIMPLE-SSA | Lower vectors | - | Vector → scalar/library |
| 5.142 | `pass_lower_complex_O0` | GIMPLE-SSA | Lower complex (O0) | - | complex → real/imag |
| 5.143 | `pass_lower_bitint_O0` | GIMPLE-SSA | Lower _BitInt (O0) | - | _BitInt → library |
| 5.144 | `pass_sancov_O0` | GIMPLE-SSA | Coverage (O0) | - | Coverage at O0 |
| 5.145 | `pass_lower_switch_O0` | GIMPLE-SSA | Lower switch (O0) | - | switch lowering at O0 |
| 5.146 | `pass_asan_O0` | GIMPLE-SSA | ASan (O0) | - | ASan at O0 |
| 5.147 | `pass_tsan_O0` | GIMPLE-SSA | TSan (O0) | - | TSan at O0 |
| 5.148 | `pass_musttail` | GIMPLE-SSA | Must-tail calls | - | Handle `[[clang::musttail]]` |
| 5.149 | `pass_sanopt` | GIMPLE-SSA | Sanitizer optimization | - | Optimize sanitizer code |
| 5.150 | `pass_cleanup_eh` (2) | GIMPLE-SSA | EH cleanup | - | Final EH cleanup |
| 5.151 | `pass_lower_resx` | GIMPLE-SSA | Lower resx | - | Lower EH resume |
| 5.152 | `pass_nrv` | GIMPLE-SSA | Named Return Value | - | Eliminate return copies |
| 5.153 | `pass_gimple_isel` | GIMPLE-SSA | GIMPLE instruction selection | - | Prepare for RTL gen |
| 5.154 | `pass_harden_conditional_branches` | GIMPLE-SSA | Branch hardening | - | Add branch checks |
| 5.155 | `pass_harden_compares` | GIMPLE-SSA | Compare hardening | - | Add comparison checks |
| 5.156 | `pass_warn_access` (3) | GIMPLE-SSA | Final access warnings | - | Final buffer checks |
| 5.157 | `pass_cleanup_cfg_post_optimizing` | GIMPLE | Final CFG cleanup | - | Clean CFG before RTL |
| 5.158 | `pass_warn_function_noreturn` | GIMPLE | Noreturn warnings | - | Warn if should be noreturn |

---

## Phase 6: RTL Generation

| # | Pass | IR | Purpose | Related | Example |
|---|------|----|---------|---------|---------|
| 6.1 | `pass_expand` | GIMPLE→RTL | **Expand GIMPLE to RTL** | - | `a = b + c` → `(set d0 (plus d1 d2))` |

---

## Phase 7: RTL Optimization (Pre-Register Allocation)

| # | Pass | IR | Purpose | Related | Example |
|---|------|----|---------|---------|---------|
| 7.1 | `pass_instantiate_virtual_regs` | RTL | Instantiate virtual registers | - | `virtual_stack_vars` → real offsets |
| 7.2 | `pass_into_cfg_layout_mode` | RTL | Enter CFG layout mode | `pass_outof_cfg_layout_mode` | Enable CFG manipulation |
| 7.3 | `pass_jump` | RTL | Jump optimization | `pass_jump2` | Simplify/remove jumps |
| 7.4 | `pass_lower_subreg` | RTL | Lower subregs | `pass_lower_subreg2` | Split multi-word operations |
| 7.5 | `pass_df_initialize_opt` | RTL | Initialize dataflow (opt) | `pass_df_finish` | Set up dataflow framework |
| 7.6 | `pass_cse` | RTL | Common Subexpression Elimination | `pass_cse2` | `move d0,d1; add d0,d2` → reuse d0 |
| 7.7 | `pass_rtl_fwprop` | RTL | RTL forward propagation | `pass_rtl_fwprop_addr` | Propagate RTL expressions |
| 7.8 | `pass_rtl_cprop` | RTL | RTL constant propagation | - | Propagate constants in RTL |
| 7.9 | `pass_rtl_pre` | RTL | RTL partial redundancy elim | - | PRE at RTL level |
| 7.10 | `pass_rtl_hoist` | RTL | RTL code hoisting | - | Hoist expressions up |
| 7.11 | `pass_hardreg_pre` | RTL | Hard register PRE | - | PRE for hard registers |
| 7.12 | `pass_rtl_cprop` (2) | RTL | Second RTL cprop | - | After PRE/hoist |
| 7.13 | `pass_rtl_store_motion` | RTL | Store motion | - | Move stores out of loops |
| 7.14 | `pass_cse_after_global_opts` | RTL | CSE after global opts | - | CSE cleanup |
| 7.15 | `pass_rtl_ifcvt` | RTL | RTL if-conversion | - | Conditional move generation |
| 7.16 | `pass_reginfo_init` | RTL | Initialize register info | - | Set up register data |

### RTL Loop Optimization

| # | Pass | IR | Purpose | Related | Example |
|---|------|----|---------|---------|---------|
| 7.17 | `pass_loop2` | RTL | RTL loop container | - | Parent for RTL loop passes |
| 7.18 | `pass_rtl_loop_init` | RTL | Initialize RTL loops | `pass_rtl_loop_done` | Set up loop structures |
| 7.19 | `pass_rtl_move_loop_invariants` | RTL | Move loop invariants | - | RTL-level LIM |
| 7.20 | `pass_rtl_unroll_loops` | RTL | Loop unrolling | - | Unroll loops in RTL |
| 7.21 | `pass_rtl_doloop` | RTL | **Doloop optimization** | - | **`subq #1,dn; bne` → `dbra dn`** (m68k!) |
| 7.22 | `pass_rtl_loop_done` | RTL | Finalize RTL loops | - | Clean up loop data |

### Pre-RA RTL Optimization (continued)

| # | Pass | IR | Purpose | Related | Example |
|---|------|----|---------|---------|---------|
| 7.23 | `pass_lower_subreg2` | RTL | Second subreg lowering | - | Split remaining multi-word |
| 7.24 | `pass_web` | RTL | Web construction | - | Build webs for register allocation |
| 7.25 | `pass_rtl_cprop` (3) | RTL | Third cprop | - | Final pre-RA cprop |
| 7.26 | `pass_cse2` | RTL | Second CSE | `pass_cse` | More aggressive CSE |
| 7.27 | `pass_rtl_dse1` | RTL | RTL dead store elimination | `pass_rtl_dse2` | Remove dead stores |
| 7.28 | `pass_rtl_fwprop_addr` | RTL | Address forward propagation | - | Propagate address expressions |
| 7.29 | `pass_inc_dec` | RTL | **Autoincrement/decrement** | - | **`(a0)` + `lea 4(a0),a0` → `(a0)+`** (m68k!) |
| 7.29a | **`m68k_pass_avail_copy_elim`** | RTL | **Redundant copy elimination** | m68k | **Remove copies available on all paths** |
| 7.30 | `pass_initialize_regs` | RTL | Initialize uninitialized regs | - | Set undefined regs to 0 |
| 7.31 | `pass_ud_rtl_dce` | RTL | Use-def RTL DCE | - | Remove dead code |
| 7.32 | `pass_ext_dce` | RTL | Extension DCE | - | Remove dead extends |
| 7.33 | `pass_combine` | RTL | **Instruction combining** | - | **`clr d0; move d0,(a0)` → `clr (a0)`** |
| 7.34 | `pass_late_combine` | RTL | Late combining | - | After other opts |
| 7.35 | `pass_if_after_combine` | RTL | If-conversion after combine | - | Conditional moves |
| 7.36 | `pass_jump_after_combine` | RTL | Jump opt after combine | - | Optimize jumps |
| 7.37 | `pass_partition_blocks` | RTL | Block partitioning | - | Hot/cold code separation |
| 7.38 | `pass_outof_cfg_layout_mode` | RTL | Exit CFG layout mode | - | Linearize code |
| 7.39 | `pass_split_all_insns` | RTL | Split all instructions | - | Prepare for RA |
| 7.40 | `pass_lower_subreg3` | RTL | Final subreg lowering | - | Last subreg split |
| 7.41 | `pass_df_initialize_no_opt` | RTL | Initialize dataflow (no opt) | - | For later passes |
| 7.42 | `pass_stack_ptr_mod` | RTL | Stack pointer modification | - | Adjust SP operations |
| 7.43 | `pass_mode_switching` | RTL | Mode switching | - | FPU mode changes |
| 7.44 | `pass_match_asm_constraints` | RTL | Match asm constraints | - | Satisfy inline asm |
| 7.45 | `pass_sms` | RTL | Software pipelining | - | Modulo scheduling |
| 7.46 | `pass_live_range_shrinkage` | RTL | Shrink live ranges | - | Reduce register pressure |
| 7.47 | `pass_sched` | RTL | Instruction scheduling 1 | `pass_sched2` | Pre-RA scheduling |
| 7.48 | `pass_rtl_avoid_store_forwarding` | RTL | Avoid store forwarding | - | Prevent store-to-load |
| 7.49 | `pass_early_remat` | RTL | Early rematerialization | - | Recompute vs reload |

---

## Phase 8: Register Allocation

| # | Pass | IR | Purpose | Related | Example |
|---|------|----|---------|---------|---------|
| 8.1 | `pass_ira` | RTL | **Integrated Register Allocator** | - | **Assign pseudo → d0-d7/a0-a6** |
| 8.2 | `pass_reload` | RTL | **Reload pass** | - | **Spill/restore for constraints** |

---

## Phase 9: Post-Register Allocation

| # | Pass | IR | Purpose | Related | Example |
|---|------|----|---------|---------|---------|
| 9.1 | `pass_postreload` | RTL | Post-reload container | - | Parent for post-RA passes |
| 9.2 | `pass_postreload_cse` | RTL | Post-reload CSE | - | CSE with hard registers |
| 9.3 | `pass_late_combine` (2) | RTL | Late combining | - | Post-RA combining |
| 9.4 | `pass_gcse2` | RTL | Global CSE 2 | - | Post-RA global CSE |
| 9.5 | `pass_split_after_reload` | RTL | Post-reload splitting | - | Split complex insns |
| 9.6 | `pass_ree` | RTL | Redundant extension elimination | - | Remove useless extends |
| 9.7 | `pass_compare_elim_after_reload` | RTL | **Compare elimination** | - | **Use CC from previous insn** |
| 9.8 | `pass_thread_prologue_and_epilogue` | RTL | **Prologue/epilogue** | - | **Insert `movem.l` save/restore** |
| 9.9 | `pass_rtl_dse2` | RTL | Post-reload DSE | - | Remove dead stores |
| 9.10 | `pass_stack_adjustments` | RTL | Stack adjustments | - | Combine SP changes |
| 9.11 | `pass_jump2` | RTL | Final jump optimization | - | Clean up jumps |
| 9.12 | `pass_duplicate_computed_gotos` | RTL | Duplicate computed gotos | - | For better scheduling |
| 9.13 | `pass_sched_fusion` | RTL | Scheduler fusion | - | Fuse for scheduling |
| 9.13a | **`m68k_pass_normalize_autoinc`** | RTL | **m68k autoinc normalize** | - | **Canonicalize autoinc patterns** |
| 9.14 | `pass_peephole2` | RTL | **Peephole optimization 2** | - | **`move.l (a0)+,(a1)+`** (m68k!) |
| 9.14a | **`m68k_pass_reorder_for_cc`** | RTL | **m68k load reorder for CC** | - | **Load tested reg last, elide `tst`** |
| 9.14b | **`m68k_pass_opt_autoinc`** | RTL | **m68k auto-increment** | - | **Convert indexed→`(ax)+`/`-(ax)`** |
| 9.15 | `pass_if_after_reload` | RTL | Post-reload if-conversion | - | Late conditional moves |
| 9.16 | `pass_regrename` | RTL | Register renaming | - | Break false dependencies |
| 9.17 | `pass_fold_mem_offsets` | RTL | Fold memory offsets | - | Combine offset calculations |
| 9.18 | `pass_cprop_hardreg` | RTL | **Hard register copy prop** | - | **`move d0,d1; move d1,d2` → use d0** |
| 9.19 | `pass_fast_rtl_dce` | RTL | Fast RTL DCE | - | Quick dead code removal |
| 9.19a | **`m68k_pass_highword_opt`** | RTL | **m68k highword optimization** | - | **Word packing, swap+move.w** |
| 9.19b | **`m68k_pass_elim_andi`** | RTL | **m68k ANDI elimination** | - | **Hoist `moveq #0` for zero-extend** |
| 9.20 | `pass_reorder_blocks` | RTL | Block reordering | - | Optimize code layout |
| 9.21 | `pass_leaf_regs` | RTL | Leaf function registers | - | Optimize leaf functions |
| 9.22 | `pass_split_before_sched2` | RTL | Pre-sched2 split | - | Prepare for scheduling |
| 9.23 | `pass_sched2` | RTL | **Instruction scheduling 2** | - | **Post-RA scheduling** |
| 9.24 | `pass_stack_regs` | RTL | Stack register allocation | - | x87 FPU stack (not m68k FPU) |
| 9.25 | `pass_split_before_regstack` | RTL | Pre-regstack split | - | For x87 |
| 9.26 | `pass_stack_regs_run` | RTL | Run stack regs | - | Execute stack allocation |

---

## Phase 10: Late Compilation

| # | Pass | IR | Purpose | Related | Example |
|---|------|----|---------|---------|---------|
| 10.1 | `pass_late_thread_prologue_and_epilogue` | RTL | Late prologue/epilogue | - | Finalize save/restore |
| 10.2 | `pass_late_compilation` | RTL | Late compilation container | - | Final passes |
| 10.3 | `pass_zero_call_used_regs` | RTL | Zero call-used registers | - | Security: clear regs |
| 10.4 | `pass_compute_alignments` | RTL | Compute alignments | - | Branch target alignment |
| 10.5 | `pass_variable_tracking` | RTL | Variable tracking | - | Debug info generation |
| 10.6 | `pass_free_cfg` | RTL | Free CFG | - | Release CFG memory |
| 10.7 | `pass_machine_reorg` | RTL | **Machine reorganization** | - | **m68k-specific transforms** |
| 10.8 | `pass_cleanup_barriers` | RTL | Cleanup barriers | - | Remove redundant barriers |
| 10.9 | `pass_delay_slots` | RTL | Delay slot filling | - | Fill branch delay slots |
| 10.10 | `pass_split_for_shorten_branches` | RTL | Split for branch shortening | - | Prepare for short branches |
| 10.11 | `pass_convert_to_eh_region_ranges` | RTL | EH region conversion | - | Convert EH info |
| 10.12 | `pass_shorten_branches` | RTL | **Branch shortening** | - | **`jmp` → `bra.s`** (m68k!) |
| 10.13 | `pass_set_nothrow_function_flags` | RTL | Set nothrow flags | - | Mark nothrow functions |
| 10.14 | `pass_dwarf2_frame` | RTL | DWARF frame info | - | Generate unwind info |

---

## Phase 11: Final Assembly Generation

| # | Pass | IR | Purpose | Related | Example |
|---|------|----|---------|---------|---------|
| 11.1 | `pass_final` | RTL→ASM | **Final assembly output** | - | **RTL → `.s` file** |

---

## Phase 12: Cleanup

| # | Pass | IR | Purpose | Related | Example |
|---|------|----|---------|---------|---------|
| 12.1 | `pass_df_finish` | - | Finish dataflow | - | Release dataflow memory |
| 12.2 | `pass_clean_state` | - | Clean state | - | Reset for next function |

---

## m68k-Specific Passes and Optimizations

### GIMPLE Passes

#### `m68k_pass_autoinc_split`

**Location**: After `pass_iv_optimize` (5.95) in Phase 5
**Source**: `gcc/config/m68k/m68k-gimple-passes.cc`

**Purpose**: Split autoincrement pointer operations that span multiple statements, enabling later RTL passes to use post-increment addressing.

**Transformation Example**:
```c
// Before: increment spans statements
*p++ = a; *p++ = b;  // p used twice, incremented twice

// After: explicit increments
*p = a; p++; *p = b; p++;
```

#### `m68k_pass_narrow_index_mult`

**Location**: After `pass_vrp` (Value Range Propagation) in Phase 5
**Source**: `gcc/config/m68k/m68k-gimple-passes.cc`

**Purpose**: Narrow 32-bit multiplications to 16-bit when operand ranges fit, enabling use of `muls.w` instead of library calls on 68000.

**Transformation Example**:
```c
int idx = (row & 0xFF) * 320;
```
```asm
; Before: 32-bit multiply (library call on 68000)
jsr     __mulsi3

; After: 16-bit multiply
muls.w  #320,d0
```

#### `m68k_pass_reorder_mem`

**Location**: Before `pass_store_merging` (5.124) in Phase 5
**Source**: `gcc/config/m68k/m68k-gimple-passes.cc`

**Purpose**: Reorder scattered struct field accesses by memory offset, enabling store merging and post-increment addressing.

### RTL Passes

#### `m68k_pass_avail_copy_elim`

**Location**: After `pass_inc_dec` (7.29) in Phase 7
**Source**: `gcc/config/m68k/m68k-rtl-passes.cc`

**Purpose**: Eliminate redundant register copies that are already available on all incoming paths. Cleans up copies reintroduced by loop unrolling before IRA.

#### `m68k_pass_normalize_autoinc`

**Location**: Before `pass_peephole2` (9.14) in Phase 9
**Source**: `gcc/config/m68k/m68k-rtl-passes.cc`

**Purpose**: Normalize autoincrement patterns to canonical forms for better optimization.

#### `m68k_pass_reorder_for_cc`

**Location**: After `pass_peephole2` (9.14) in Phase 9
**Source**: `gcc/config/m68k/m68k-rtl-passes.cc`

**Purpose**: Reorder loads so the register tested by a conditional branch is set by the immediately preceding instruction, allowing `final` to elide the `tst`.

#### `m68k_pass_opt_autoinc`

**Location**: After `m68k_pass_reorder_for_cc` in Phase 9
**Source**: `gcc/config/m68k/m68k-rtl-passes.cc`

**Purpose**: Convert indexed addressing to POST_INC/PRE_DEC addressing modes. Also works across basic block boundaries when the increment is in a fall-through successor.

**Transformation Example**:
```asm
; Before:
  move.l (a0),d0
  move.l 4(a0),d1
  lea 8(a0),a0

; After:
  move.l (a0)+,d0
  move.l (a0)+,d1
```

#### `m68k_pass_elim_andi`

**Location**: After `pass_fast_rtl_dce` (9.19) in Phase 9
**Source**: `gcc/config/m68k/m68k-rtl-passes.cc`

**Purpose**: Replace `andi.l #mask` for zero-extension with a hoisted `moveq #0` and register moves.

**Transformation Example**:
```asm
; Before: repeated ANDI in loop
.loop:
  move.b  (a0)+,d0
  andi.l  #255,d0     ; zero-extend

; After: hoisted zero register
  moveq   #0,d0       ; hoisted
.loop:
  move.b  (a0)+,d0    ; inherits zero upper bits
```

#### `m68k_pass_highword_opt`

**Location**: After `pass_fast_rtl_dce` (9.19), before `m68k_pass_elim_andi` in Phase 9
**Source**: `gcc/config/m68k/m68k-rtl-passes.cc`

**Purpose**: Optimize word packing, including `struct { short, short }` construction and combining `andi.l #$ffff` + `ori.l #xxxx0000` sequences.

**Transformation Example**:
```asm
; Before: shift and OR
  swap    d0
  clr.w   d0
  andi.l  #$ffff,d1
  or.l    d1,d0

; After: direct packing
  swap    d0
  move.w  d1,d0
```

### Key m68k Optimizations in All Passes

| Pass | m68k Optimization | Example |
|------|-------------------|---------|
| `m68k_pass_narrow_index_mult` (5.26a) | Narrow 32→16-bit multiply | `jsr __mulsi3` → `muls.w #320,d0` |
| `m68k_pass_autoinc_split` (5.95a) | Split combined increments | Re-split for `(a0)+` addressing |
| `m68k_pass_reorder_mem` (5.123a) | Reorder struct accesses | Sequential offsets → store merge |
| `pass_rtl_doloop` (7.21) | Convert loops to `dbra` | `subq #1,dn; bne` → `dbra dn,loop` |
| `pass_inc_dec` (7.29) | Auto-increment addressing | `move (a0); addq #4,a0` → `move (a0)+` |
| `m68k_pass_avail_copy_elim` (7.29a) | Eliminate redundant copies | Remove copies available on all paths |
| `pass_combine` (7.33) | Instruction combining | `clr d0; move d0,(a0)` → `clr (a0)` |
| `pass_compare_elim` (9.7) | Eliminate redundant compares | `sub d0,d1; tst d1` → `sub d0,d1` (sets CC) |
| `pass_thread_prologue_and_epilogue` (9.8) | Efficient save/restore | Individual pushes → `movem.l d3-d7/a2-a6,-(sp)` |
| `m68k_pass_normalize_autoinc` (9.13a) | Normalize autoinc patterns | Canonicalize for later passes |
| `pass_peephole2` (9.14) | Pattern-based optimization | Complex multi-insn patterns |
| `m68k_pass_reorder_for_cc` (9.14a) | Reorder loads for CC | Load tested reg last, elide `tst` |
| `m68k_pass_opt_autoinc` (9.14b) | Convert indexed→autoinc | `(a0); lea 4(a0),a0` → `(a0)+` |
| `m68k_pass_highword_opt` (9.19a) | Word packing | `andi.l #$ffff; ori.l` → `swap; move.w` |
| `m68k_pass_elim_andi` (9.19b) | Hoist zero-extension | `andi.l #255,dn` → hoisted `moveq #0,dn` |
| `pass_shorten_branches` (10.12) | Use short branches | `jmp label` → `bra.s label` |

### Machine Description Patterns

The m68k machine description (`m68k.md`) defines patterns that enable:

1. **Address modes**: `(an)`, `(an)+`, `-(an)`, `d(an)`, `d(an,xi)`, etc.
2. **Conditional instructions**: `scc`, `dbcc` patterns
3. **Bit operations**: `bset`, `bclr`, `btst` patterns
4. **Move optimization**: `moveq`, `clr`, combined load/store
5. **Arithmetic**: `addq`/`subq` for small constants

---

## Optimization Level Effects

| Flag | Effect on Passes |
|------|------------------|
| `-O0` | Most optimization passes skipped; uses `*_O0` variants |
| `-O1` | Basic optimization passes enabled |
| `-O2` | Full optimization; loop opts, vectorization disabled |
| `-O3` | Aggressive optimization; vectorization, unrolling enabled |
| `-Os` | Size optimization; unrolling disabled, size-based inlining |
| `-Og` | Debug optimization; uses `pass_all_optimizations_g` path |

---

## Pass Dependencies Summary

```
GIMPLE → SSA → Loop Opts → Lower → RTL → Pre-RA → IRA → Reload → Post-RA → Final
   │         │           │         │      │           │         │          │
   └─────────┴───────────┴─────────┴──────┴───────────┴─────────┴──────────┘
            Multiple passes at each stage, iterating for convergence
```
