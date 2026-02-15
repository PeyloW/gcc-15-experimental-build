---
disable-model-invocation: true
description: Test workflow for verifying m68k GCC optimization changes.
---

# Test Workflow

## Running Tests

```bash
./build-test_cases.sh
```

This compares assembly output between the system compiler (old) and the built compiler (new) across 6 optimization variants:

| Flag | Description |
|------|-------------|
| `-O2` | Standard optimization |
| `-O2 -mshort` | Optimization with 16-bit int |
| `-O2 -m68030` | Optimization for 68030 |
| `-Os` | Size optimization |
| `-Os -mshort` | Size optimization with 16-bit int |
| `-Os -m68030` | Size optimization for 68030 |

## Regression Rules

- Existing tests MUST NOT regress compared to the branch before new changes
- Run the test suite before and after making changes to establish a baseline

## Adding Test Cases

Add new test functions to `build/test_cases.cpp`. Test function naming convention:

- `test_<feature>()` — positive test (optimization should apply)
- `test_no_<feature>()` — negative test (optimization must NOT apply)

## Workflow

1. Add test cases to `test_cases.cpp` if applicable
2. Run `./build-test_cases.sh` to get baseline
3. Make changes to `gcc/config/m68k/` files
4. Build with `./build-gcc.sh build`
5. Run `./build-test_cases.sh` again and compare
