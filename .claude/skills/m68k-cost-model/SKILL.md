---
user-invocable: false
description: Loaded when working on RTX costs, address costs, or instruction costs in the m68k backend.
---

# m68k Cost Model

## The 4 Cost Hooks

| Hook | Callers | Input | Answers |
|------|---------|-------|---------|
| `TARGET_RTX_COSTS` | combine, late_combine, IVOPTS, CSE | RTX sub-expression (no insn context) | "How expensive is this expression?" |
| `TARGET_INSN_COST` | combine, late_combine, scheduler | Complete `(set dst src)` pattern | "How expensive is this whole instruction?" |
| `TARGET_ADDRESS_COST` | IVOPTS, combine, scheduler | Address expression inside MEM | "How expensive is this addressing mode?" |
| `TARGET_NEW_ADDRESS_PROFITABLE_P` | scheduler | Two address expressions (old, new) | "Is the new address cheaper?" |

## Source Files

- `gcc/config/m68k/m68k_costs.cc` — `m68k_rtx_costs_impl()`, `m68k_insn_cost_impl()`, `m68k_address_cost_impl()`
- `gcc/config/m68k/m68k.cc` — hook registration

## Non-RMW Compound-to-Memory Detection

`(set (mem) (plus reg const))` where reg is NOT the memory base requires copy+op+store (3 insns), not a single RMW instruction. `TARGET_INSN_COST` must detect this and use additive cost. Without this, `late_combine` and `combine` fold IV chains into base+offset form.

Detection: check if the source operand's register is the same as the memory base register. If not, it's non-RMW.

## Pseudo-Register Costing

Pre-RA, cost hooks receive pseudo-register numbers, not `d0`/`a0`. The cost model cannot know the exact register class. The m68k model costs register-class-agnostic patterns at their cheapest valid form, relying on `.md` operand constraints to prevent invalid allocations.

## How Combine Uses Costs

`combine_validate_cost()` in `gcc/combine.cc` compares the cost of the original insn sequence against the merged result. If merged is not cheaper, combine rejects the transformation. This is why accurate `TARGET_INSN_COST` is critical — it prevents combine from folding pointer IVs into expensive indexed addressing.

## Why TARGET_INSN_COST Was Added

GCC's default `TARGET_RTX_COSTS` only costs the source side of `(set dst src)`. Memory destinations get a fixed cost. On m68k, `move.l d0,(a0)` costs 12 cycles, not 4. Without `TARGET_INSN_COST`, stores look as cheap as register moves.

## Atari ST Bus Cycle Rounding

On the Atari ST, the 68000 runs at 8 MHz with a 16-bit bus that operates on 4-cycle (500 ns) bus cycles. All instruction timings are rounded up to the nearest multiple of 4 clock cycles, because the CPU must wait for the current bus cycle to complete before starting the next operation. For example, a `moveq` takes 4 cycles (one bus cycle), while `addq.l #1,d0` nominally takes 4 cycles but a `move.l (a0),d0` takes 12 cycles (three bus cycles). This rounding means small cycle differences in the data sheet (e.g. 6 vs 8 cycles) may collapse to the same effective cost (8 cycles) on real hardware.

When comparing instruction costs, always consider the rounded cost, not the raw cycle count from the 68000 programmer's reference.

## Addressing Mode Costs (68000)

Cycle counts shown are raw 68000 data sheet values. On Atari ST, round up to the nearest 4.

| Mode | Cycles | Atari ST | Example |
|------|--------|----------|---------|
| `(an)` | 4 | 4 | `move.l (a0),d0` operand cost |
| `(an)+` | 4 | 4 | `move.l (a0)+,d0` operand cost |
| `d(an)` | 8 | 8 | `move.l 4(a0),d0` operand cost |
| `d(an,xi)` | 10 | 12 | `move.l (a0,d0.l),d1` operand cost |
| `xxx.w` | 8 | 8 | `move.l $1234.w,d0` operand cost |
| `xxx.l` | 12 | 12 | `move.l $12345678.l,d0` operand cost |

## 68020+ Address Sub-Expressions

On 68020, nested RTX inside MEM must be costed once as addressing modes, not double-counted as standalone arithmetic + addressing. The cost model recognizes address sub-expressions and costs them appropriately.
