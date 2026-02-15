# m68k GCC Build Scripts and Documentation

This directory contains helper scripts and documentation for working on the m68k-atari-mintelf GCC backend. Its purpose is twofold: provide one-liner scripts for common debugging workflows, and collect reference documentation to aid further development of the backend.

The work is tracked in a [draft PR](https://github.com/th-otto/m68k-atari-mint-gcc/pull/1), gracefully hosted by Thorsten Otto in his GCC fork. Thanks to Miro Kropacek for his invaluable help in trying out the branch and reporting bugs.

The documentation and scripts are updated as I continue exploring GCC internals. They are compiled from notes, reading GCC source code, and heavy use of Claude.ai for guided exploration and summarizing of concepts and code I do not yet fully understand. Expect inaccuracies — corrections and improvements are welcome.

## My General Workflow

1. Formulate a hypothesis and ask Claude.ai to explore the idea, presenting a markdown doc with possible options.
2. Sanity check the options by reading source code, googling for prior art, etc.
3. Pick the most promising option and iterate on the design proposal until it looks reasonable and complete.
4. Ask Claude.ai to write a task list for implementation.
5. Sanity check again — go back to the previous step if something does not smell right.
6. Iterate on the code, and have Claude.ai fix it up for style.
7. Have Claude.ai do thorough code review — go back to the previous step if needed.
8. Build Mikro's projects and test_cases, verify assembly for sanity by hand.
9. Build Fire Flight, and verify it still runs in Hatari.
10. Use my notes for the process as source, and have Claude.ai update all the documentation properly.
11. Success.

Half the battle is getting Claude to decipher my dyslexic notes — the other half is pretending I meant to write it that way.

## Repository Setup

This repository is a fork of GCC with m68k-atari-mintelf patches. The `build/` directory lives at the root of the GCC source tree:

```
m68k-atari-mint-gcc/          # git clone of the repository
  gcc/                         # GCC source (including gcc/config/m68k/)
  libgcc/
  libstdc++-v3/
  build/                       # this directory — scripts, docs, test cases
    build-host/                # build artifacts (created by build-gcc.sh)
    build-host-sjlj/           # sjlj build artifacts (created by build-gcc.sh -sjlj)
    ...
```

Clone and build:

```bash
git clone -b mint/gcc-15-experimental https://github.com/th-otto/m68k-atari-mint-gcc.git
cd m68k-atari-mint-gcc
git clone git@github.com:PeyloW/gcc-15-experimental-build.git build
cd build
./build-gcc.sh configure
./build-gcc.sh build
./build-gcc.sh -sjlj configure  # optional: sjlj exceptions variant
./build-gcc.sh -sjlj build
./build-test_cases.sh
```

See [GCC_DEBUG.md](GCC_DEBUG.md) for debugging workflows, or jump straight to the helper scripts below.

## Documentation

| File | Description |
|------|-------------|
| [M68K_OPTIMIZATIONS.md](M68K_OPTIMIZATIONS.md) | Detailed descriptions of all m68k-specific optimizations in this branch. |
| [GCC_PASSES.md](GCC_PASSES.md) | Complete list of GCC 15 optimization passes in execution order, annotated with custom m68k additions. |
| [GCC_ARCHITECTURE.md](GCC_ARCHITECTURE.md) | Conceptual guide to how GCC transforms C source into m68k assembly. |
| [GCC_DEBUG.md](GCC_DEBUG.md) | Practical guide for diagnosing regressions, miscompilations, and ICEs. |
| [GCC_GLOSSARY.md](GCC_GLOSSARY.md) | Glossary of GCC internal terms used across the other documents. |
| [PR_COMMENT.md](PR_COMMENT.md) | Succinct PR description derived from M68K_OPTIMIZATIONS.md. |

## Scripts

| Script | Description |
|--------|-------------|
| [build-gcc.sh](build-gcc.sh) | Configure, build, install, or clean the cross-compiler. |
| [build-test_cases.sh](build-test_cases.sh) | Compile `test_cases.cpp` with both compilers and compare instruction counts. |
| [build-mikros.sh](build-mikros.sh) | Build 16 packages with both non-sjlj and sjlj compilers for integration testing. |
| [debug-asm-diff.sh](debug-asm-diff.sh) | Compare assembly output between stock GCC 15 and this branch for a single source file. |
| [debug-bisect-passes.sh](debug-bisect-passes.sh) | Disable each m68k pass individually to find which one causes a regression or ICE. |
| [debug-dump-pass.sh](debug-dump-pass.sh) | Dump RTL or GIMPLE pass output, with optional two-pass diffing. |
