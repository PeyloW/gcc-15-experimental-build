---
description: Loaded when the user asks to count clock cycles, measure cycle cost, or compare cycle counts for m68k assembly code. Uses the `clccnt` command-line tool.
---

# Counting Clock Cycles with clccnt

The `clccnt` tool counts clock cycles for m68k assembly. It analyzes control flow and reports min/max cycles per function.

## Basic Usage

```bash
# Count cycles for a single instruction (68000 default)
clccnt -i "move.l (a0)+,d0"

# Count cycles for an assembly file
clccnt file.s

# Specify CPU model
clccnt -c 030 file.s

# Verbose output (per-instruction detail)
clccnt -v file.s

# JSON output (machine-readable)
clccnt -j file.s
```

## CPU Models

| Flag | CPU | Notes |
|------|-----|-------|
| `-c 000` | MC68000 | Default. 16-bit bus, 4-cycle minimum. Use for Atari ST. |
| `-c 020` | MC68020 | 32-bit bus, instruction cache. |
| `-c 030` | MC68030 | Like 020 with on-chip MMU. |
| `-c 040` | MC68040 | Pipelined, on-chip FPU. |
| `-c 060` | MC68060 | Superscalar. Also use for ColdFire (closest model). |

## Output Format

Plain text output shows one line per function:

```
  function_name                          min_cycles - max_cycles
```

If min equals max (no branches), only one number is shown.

## Summing Cycles Across a File

To get a total max-cycle count for all functions in a file:

```bash
clccnt -c 000 file.s | awk '{sum += $NF} END {print sum}'
```

## Comparing Two Assembly Files

```bash
old=$(clccnt -c 000 old.s | awk '{sum += $NF} END {print sum}')
new=$(clccnt -c 000 new.s | awk '{sum += $NF} END {print sum}')
echo "Old: $old  New: $new  Diff: $((new - old))"
```

## Per-Function Comparison

To compare a specific function between two files:

```bash
clccnt -c 000 old.s | grep test_function_name
clccnt -c 000 new.s | grep test_function_name
```

## Compiling and Counting in One Step

```bash
# Compile to assembly, then count cycles
./build-host/gcc/xgcc -B./build-host/gcc -O2 -mfastcall -fno-inline -S test.cpp -o test.s
clccnt -c 000 test.s
```

## Integration with build-test_cases.sh

`./build-test_cases.sh` defaults to clock cycle comparison when `clccnt` is available. Use `-s` for instruction count (size) mode:

```bash
./build-test_cases.sh      # Max clock cycles (default)
./build-test_cases.sh -s   # Instruction count (size)
```

## Matching CPU to Compiler Flags

| Compiler flag | clccnt flag |
|---------------|-------------|
| *(default)* | `-c 000` |
| `-mshort` | `-c 000` |
| `-m68030` | `-c 030` |
| `-m68060` | `-c 060` |
| `-mcpu=5475` | `-c 060` (closest approximation) |
