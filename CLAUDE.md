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
- `-O2 -m68060` - Standard optimization for 68060
- `-Os -m68060` - Size optimization for 68060
- `-O2 -mcpu=5475` - Standard optimization for ColdFire
- `-Os -mcpu=5475` - Size optimization for ColdFire

After making changes to `gcc/config/m68k/` files, run the test suite again. Existing tests MUST NOT regress compared to this branch before new changes.

## Key Files

**Backend source files:**

- `gcc/config/m68k/m68k.cc` - Main m68k backend, target hooks
- `gcc/config/m68k/m68k_costs.cc` - RTX cost calculations
- `gcc/config/m68k/m68k-rtl-passes.cc` - RTL optimization passes (Phases 7 and 9)
- `gcc/config/m68k/m68k-gimple-passes.cc` - GIMPLE optimization passes
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
- `build/GCC_GLOSSARY.md` - Glossary of GCC internal terms
- `build/GCC_DEBUG.md` - Debugging guide (pass dumps, ICE diagnosis, pitfalls)

## Git Workflow

- Main development branch: `mint/gcc-15-experimental`
- Base branch for comparisons: `mint/gcc-15` (stock GCC 15 with MiNT patches, no m68k optimizations)
- Do NOT commit directly to main branches
- In rare cases, you can create feature branches for development after asking the user for permission
- Verify builds succeed and test_cases output is correct before committing

## Build Layout

Build artifacts live in `./build-host/` (e.g. `build/build-host/gcc/xgcc`). The sjlj variant builds to `./build-host-sjlj/` (via `./build-gcc.sh -sjlj`). User files (test_cases.cpp, *.md, *.sh) stay in the `build/` root.

## Clean Safety

The `./build-gcc.sh clean` command removes `./build-host/` (after creating a timestamped tgz backup in `/tmp/`). Similarly, `./build-gcc.sh -sjlj clean` removes `./build-host-sjlj/`. User files in the `build/` root are never touched.
