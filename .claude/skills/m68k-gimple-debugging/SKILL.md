---
user-invocable: false
description: Loaded when debugging or writing GIMPLE passes in the m68k backend (m68k-gimple-passes.cc).
---

# GIMPLE Pass Debugging

## m68k GIMPLE Passes

| Pass | Number | Purpose |
|------|--------|---------|
| `m68k_pass_narrow_index_mult` | 5.26a | Narrow 32→16-bit multiply when VRP proves operands fit |
| `m68k_pass_autoinc_split` | 5.95a | Re-split combined pointer increments for `(a0)+` |
| `m68k_pass_reorder_mem` | 5.123a | Reorder struct accesses by offset for store merging |

Source: `gcc/config/m68k/m68k-gimple-passes.cc`

## GIMPLE Dump Flags

```
-fdump-tree-m68k_narrow_index_mult    # Dump narrow-index-mult pass
-fdump-tree-m68k_autoinc_split        # Dump autoinc-split pass
-fdump-tree-m68k_reorder_mem          # Dump reorder-mem pass
-fdump-tree-all                       # Dump all GIMPLE passes (huge)
```

## SSA Update Rules

After modifying GIMPLE statements:

- `TODO_update_ssa` — full SSA update (needed when adding new defs)
- `TODO_update_ssa_only_virtuals` — only update virtual operands (lighter, use when only modifying memory ops)
- `mark_virtual_operands_for_renaming(cfun)` — mark all virtual ops for SSA rename

When moving or reordering statements that access memory, virtual operands (`.MEM`) need renaming.

## Common GIMPLE API Patterns

```c
// Iterating over statements in a BB
gimple_stmt_iterator gsi;
for (gsi = gsi_start_bb(bb); !gsi_end_p(gsi); gsi_next(&gsi)) {
    gimple *stmt = gsi_stmt(gsi);
    ...
}

// Checking statement type
if (gimple_assign_single_p(stmt)) { ... }  // simple assignment
if (is_gimple_call(stmt)) { ... }          // function call

// Accessing assignment operands
tree lhs = gimple_assign_lhs(stmt);
tree rhs = gimple_assign_rhs1(stmt);
enum tree_code code = gimple_assign_rhs_code(stmt);

// SSA def-use
gimple *def_stmt = SSA_NAME_DEF_STMT(ssa_name);
```

## Alias Oracle

Use the alias oracle to check if reordering memory operations is safe:

```c
// Check if stmt1 and stmt2 may alias
if (refs_may_alias_p(gimple_assign_lhs(stmt1), gimple_assign_rhs1(stmt2)))
    // Cannot reorder — stmt2 reads what stmt1 writes
```

## Range Query (VRP)

To query value ranges in a GIMPLE pass:

```c
// Enable ranger for the pass
enable_ranger(cfun);

// Query range of an SSA name
value_range vr;
if (get_range_query(cfun)->range_of_expr(vr, ssa_name, stmt)) {
    if (vr.upper_bound() <= 32767 && vr.lower_bound() >= -32768)
        // Fits in 16 bits
}

// Disable ranger when done
disable_ranger(cfun);
```

## Type Conversion Checks

When narrowing types (e.g. 32→16 bit multiply):

```c
// Check if conversion is a no-op
if (useless_type_conversion_p(target_type, source_type))
    // No conversion needed

// Build a conversion
tree converted = fold_convert(target_type, expr);
```

Past bug: `m68k_emit_narrow_mult` had a type mismatch when input was unsigned short but target was signed short — always check with `useless_type_conversion_p`.
