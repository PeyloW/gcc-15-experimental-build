# Claude Code Instructions for m68k-atari-mint-gcc

## Build System

Always use the build script for GCC operations:

```bash
./build-gcc.sh configure        # Run configure
./build-gcc.sh build            # Build GCC
./build-gcc.sh install          # Install to /opt/cross-mint
./build-gcc.sh clean            # Clean build directory (WARNING: deletes all local files!)
./build-gcc.sh -sjlj configure  # Configure sjlj exceptions build
./build-gcc.sh -sjlj build      # Build sjlj variant (to build-host-sjlj/)
```

**Important:** Do NOT use raw `make` commands. The build script handles the proper configuration and multilib setup for the m68k-atari-mintelf target.

## Writing Documentation

Be as succinct as possible without losing clarity. All bullet lists and code blocks (starting with ```) must have an empty line before them (the user's Markdown editor requires this).

## Referring to GCC Code

When referring to code in GCC, look up the pass name and number from GCC_PASSES.md when applicable.

## Testing Changes

Before making changes, add test cases to test_cases.cpp when applicable. Run the test suite to get a baseline comparing standard GCC 15 and this branch:

```bash
./build-test_cases.sh
```

This compares assembly output between the system compiler (old) and the built compiler (new) across multiple optimization levels:

- `-O2` - Standard optimization
- `-O2 -mshort` - Optimization with 16-bit int
- `-Os` - Size optimization
- `-Os -mshort` - Size optimization with 16-bit int
- `-O2 -m68030` - Standard optimization for 68030
- `-Os -m68030` - Size optimization for 68030
- `-O2 -m68040` - Standard optimization for 68040
- `-Os -m68040` - Size optimization for 68040
- `-O2 -m68060` - Standard optimization for 68060
- `-Os -m68060` - Size optimization for 68060
- `-O2 -mcpu=5475` - Standard optimization for ColdFire
- `-Os -mcpu=5475` - Size optimization for ColdFire

After making changes to `gcc/config/m68k/` files, run the test suite again. Existing tests MUST NOT regress compared to this branch before new changes.

### Stress-test: mintlib vfscanf.c

MintLib's `vfscanf.c` is a particularly tricky file to compile — it has ~1100 basic blocks, 21 nested loops, and heavy switch/tablejump usage. It exercises register allocation, spill/reload, DCE convergence, and if-conversion at scale. Changes to cost models, register preferences, or pattern matching that work on small test cases can cause infinite loops or ICEs on this file.

After any change to IRA hooks, cost functions, or `.md` patterns, verify vfscanf compiles for all multilibs (especially ColdFire):

```bash
./build-host/gcc/xgcc -B./build-host/gcc -mcpu=5475 -mfastcall -O2 \
  -fomit-frame-pointer -fgnu89-inline -nostdinc \
  -I/Users/peylow/mintlib/stdio -I/Users/peylow/mintlib \
  -I/Users/peylow/mintlib/include -I/Users/peylow/mintlib/mintlib \
  -I/Users/peylow/mintlib/stdlib -DHAVE_CONFIG_H -D_LIBC -D_REENTRANT \
  -S /Users/peylow/mintlib/stdio/vfscanf.c -o /dev/null
```

If it hangs, the likely cause is DCE liveness oscillation (see `gcc/dce.cc` convergence limit) or an ifcvt/rnreg infinite loop triggered by new register allocation patterns.

## Key Files

**Backend source files:**

- `gcc/config/m68k/m68k.cc` - Main m68k backend, target hooks
- `gcc/config/m68k/m68k_costs.cc` - RTX cost calculations
- `gcc/config/m68k/m68k-pass-regalloc.cc` - Register allocation passes (canonical scaled index, break false dep)
- `gcc/config/m68k/m68k-pass-memreorder.cc` - Memory reordering passes (reorder_mem, reorder_incr)
- `gcc/config/m68k/m68k-pass-autoinc.cc` - Autoincrement passes (autoinc_split, opt_autoinc, normalize_autoinc, avail_copy_elim, sink_for_rmw, sink_postinc)
- `gcc/config/m68k/m68k-pass-shortopt.cc` - 16/32-bit optimization passes (narrow_const_ops, narrow_index_mult, elim_andi, highword_opt)
- `gcc/config/m68k/m68k-pass-miscopt.cc` - Miscellaneous optimization pass (reorder_for_cc)
- `gcc/config/m68k/m68k-doloop.cc` - Doloop/DBRA target hooks and exit IV analysis
- `gcc/config/m68k/m68k-util.cc` / `m68k-util.h` - Shared RTL utility functions for passes
- `gcc/config/m68k/m68k.md` - Machine description patterns

**Test files:**

- `build/test_cases.cpp` - Test cases for optimization verification
- `build/build-test_cases.sh` - Script to generate assembly comparisons

**Debug helper scripts:**

- `build/debug-asm-diff.sh` - Compare assembly between old and new compiler
- `build/debug-bisect-passes.sh` - Find which m68k pass causes a change
- `build/debug-dump-pass.sh` - Dump and diff pass output

**Documentation:**

- `build/M68K_OPTIMIZATIONS.md` - Detailed m68k-specific optimizations (full reference)
- `build/PR_COMMENT.md` - Succinct PR description (derived from M68K_OPTIMIZATIONS.md)
- `build/GCC_PASSES.md` - Complete GCC pass list with m68k additions
- `build/GCC_ARCHITECTURE.md` - Conceptual guide to GCC's transformation pipeline
- `build/GCC_RTL_CANON.md` - RTL canonicalization rules (canonical forms for define_insn patterns)
- `build/GCC_GLOSSARY.md` - Glossary of GCC internal terms
- `build/GCC_DEBUG.md` - Debugging guide (pass dumps, ICE diagnosis, pitfalls)

## Git Workflow

- Main development branch: `mint/gcc-15-experimental-v2`
- Base branch for comparisons: `mint/gcc-15` (stock GCC 15 with MiNT patches, no m68k optimizations)
- Do NOT commit directly to main branches
- In rare cases, you can create feature branches for development after asking the user for permission
- Verify builds succeed and test_cases output is correct before committing

## Build Layout

Build artifacts live in `./build-host/` (e.g. `build/build-host/gcc/xgcc`). The sjlj variant builds to `./build-host-sjlj/` (via `./build-gcc.sh -sjlj`). User files (test_cases.cpp, *.md, *.sh) stay in the `build/` root.

## Clean Safety

The `./build-gcc.sh clean` command removes `./build-host/` (after creating a timestamped tgz backup in `/tmp/`). Similarly, `./build-gcc.sh -sjlj clean` removes `./build-host-sjlj/`. User files in the `build/` root are never touched.
