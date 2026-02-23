# GCC RTL Canonicalization Rules

GCC transforms RTL expressions into canonical forms so that `define_insn` patterns only need to match one shape per operation. The rules are enforced primarily by `combine` (7.33), `simplify-rtx.cc`, and `fwprop` (7.15/7.27). Backends must write patterns that match the canonical form — non-canonical RTL will never reach `recog()`.

This document collects the canonicalization rules from `gcc/doc/md.texi` ("Canonicalization of Instructions"), `gcc/rtlanal.cc` (`commutative_operand_precedence`), `gcc/combine.cc` (`make_compound_operation`, `simplify_comparison`), and `gcc/simplify-rtx.cc` (`simplify_plus_minus`, `simplify_associative_operation`).

## Contents

1. [Operand Ordering](#1-operand-ordering)
2. [Associativity and Left-Chaining](#2-associativity-and-left-chaining)
3. [Constant Positioning](#3-constant-positioning)
4. [Arithmetic Canonicalization](#4-arithmetic-canonicalization)
5. [Bitwise Operation Canonicalization](#5-bitwise-operation-canonicalization)
6. [Address Expression Canonicalization](#6-address-expression-canonicalization)
7. [Comparison Canonicalization](#7-comparison-canonicalization)
8. [Extension and Extraction](#8-extension-and-extraction)
9. [simplify_plus_minus Internals](#9-simplify_plus_minus-internals)
10. [simplify_associative_operation Internals](#10-simplify_associative_operation-internals)
11. [m68k-Specific: canon_scaled_index](#11-m68k-specific-canon_scaled_index)

---

## 1. Operand Ordering

For all commutative operators, GCC orders operands by `commutative_operand_precedence()` (`gcc/rtlanal.cc`). Higher precedence goes left (first operand), lower goes right (second operand). `swap_commutative_operands_p(x, y)` returns true when `x` should be swapped to the right.

**Priority table** (highest first):

| Priority | Category | Examples |
|----------|----------|---------|
| +4 | `RTX_COMM_ARITH` | `plus`, `mult`, `and`, `ior`, `xor` |
| +2 | `RTX_BIN_ARITH` | `minus`, `div`, `ashift`, `ashiftrt`, `lshiftrt` |
| +1 | `NEG` or `NOT` | unary negation/complement |
| 0 | other `RTX_UNARY`, `RTX_EXTRA` | |
| −1 | pointer `REG` or pointer `MEM` | `REG_POINTER` / `MEM_POINTER` set |
| −2 | non-pointer `REG` or `MEM` | |
| −3 | `SUBREG` of an object | |
| −4 | other `RTX_CONST_OBJ` | `CONST`, `SYMBOL_REF`, `LABEL_REF` |
| −5 | `CONST_DOUBLE`, `CONST_FIXED`, `CONST_POLY_INT` | after constant pool dereference |
| −6 | `CONST_WIDE_INT` | after constant pool dereference |
| −7 | `CONST_INT` | after constant pool dereference |
| −8..−10 | same types | before constant pool dereference |

**Practical consequences for m68k patterns:**

```
(plus (ashift idx 2) base)        ;; ashift (+2) before REG (-2) — canonical
(plus base (ashift idx 2))        ;; NOT canonical

(plus (plus A B) const_int)       ;; PLUS (+4) before CONST_INT (-10) — canonical
(plus const_int (plus A B))       ;; NOT canonical

(plus ptrReg nonptrReg)           ;; pointer (-1) before non-pointer (-2) — canonical
(plus nonptrReg ptrReg)           ;; NOT canonical — but only when REG_POINTER is set
```

**Source:** `gcc/rtlanal.cc` lines 3782–3860

---

## 2. Associativity and Left-Chaining

For associative operators, a sequence always chains to the left. Only the left (first) operand can itself be the same operator.

**Associative operators:** `and`, `ior`, `xor`, `plus`, `mult`, `smin`, `smax`, `umin`, `umax` (on integers).

```
(plus (plus A B) C)               ;; canonical — left-chained
(plus A (plus B C))               ;; NOT canonical
```

This is enforced by `simplify_associative_operation()` (`gcc/simplify-rtx.cc`), which rewrites `(a op (b op c))` into `((b op c) op a)` or `((a op b) op c)`.

**Note:** Within each PLUS, operand ordering (§1) still applies. So the full canonical form of `A + B + C` is `(plus (plus <higher-prec> <lower-prec>) <lowest-prec>)`.

**Source:** `gcc/doc/md.texi` lines 8902–8907; `gcc/simplify-rtx.cc` lines 2393–2447

---

## 3. Constant Positioning

Constants always go to the right (second operand) of commutative and comparison operators.

```
(plus reg (const_int 4))          ;; canonical
(plus (const_int 4) reg)          ;; NOT canonical
```

**Three-item sums:** When a sum has three items and one is a constant, the constant is always outermost:

```
(plus (plus x y) (const_int N))   ;; canonical
(plus (plus x (const_int N)) y)   ;; NOT canonical
```

This combines the left-chaining rule (§2) with constant positioning: the inner PLUS holds the two non-constant terms, the outer PLUS adds the constant.

**MINUS with constant:** `(minus x (const_int N))` is converted to `(plus x (const_int -N))`.

```
(plus x (const_int -5))           ;; canonical
(minus x (const_int 5))           ;; NOT canonical
```

**Source:** `gcc/doc/md.texi` lines 8889, 8962–8963, 9012–9017

---

## 4. Arithmetic Canonicalization

### NEG movement

NEG is pushed inward as far as possible:

```
(mult (neg A) B)                  ;; canonical — NEG inside MULT
(neg (mult A B))                  ;; NOT canonical
```

But when a PLUS can absorb the NEG as a MINUS:

```
(minus A (mult B C))              ;; canonical
(plus (mult (neg B) C) A)         ;; NOT canonical
```

### Complex subexpressions first

If only one operand of a commutative operator is a `neg`, `not`, `mult`, `plus`, or `minus` expression, it goes first:

```
(plus (minus A B) C)              ;; canonical — MINUS is complex
(plus C (minus A B))              ;; NOT canonical
```

This is already implied by the priority table (§1) where `RTX_BIN_ARITH` (+2) and `RTX_COMM_ARITH` (+4) rank above `RTX_OBJ` (−2), but the md.texi rule makes it explicit.

**Source:** `gcc/doc/md.texi` lines 8914–8925

---

## 5. Bitwise Operation Canonicalization

### De Morgan's Law

Bitwise negation is pushed inside AND/IOR:

```
(and (not A) (not B))             ;; NOT canonical
(not (and A B))                   ;; depends on context...

;; De Morgan rewrites so NOT is inside:
(ior (not A) (not B))             ;; canonical for NAND
(and (not A) B)                   ;; canonical for AND-NOT (NOT operand first)
```

If the result has only one `not` operand, it goes first:

```
(and (not A) B)                   ;; canonical — NOT operand first
(and B (not A))                   ;; NOT canonical
```

### XOR with NOT

XOR and NOT combine in only two forms:

```
(xor A B)                         ;; canonical
(not (xor A B))                   ;; canonical (XNOR)
(xor (not A) B)                   ;; NOT canonical — never produced
```

**Source:** `gcc/doc/md.texi` lines 8972–9010

---

## 6. Address Expression Canonicalization

Inside `mem` expressions, several additional rules apply.

### ASHIFT to MULT

Within address computations (inside `mem`), combine converts left shifts by constants into multiplications:

```
;; Inside MEM:
(mult idx (const_int 4))          ;; canonical (combine converts ashift)
(ashift idx (const_int 2))        ;; NOT canonical inside MEM

;; Outside MEM:
(ashift idx (const_int 2))        ;; canonical (no conversion)
```

This conversion is done by `make_compound_operation()` in `gcc/combine.cc` (lines 8090–8108). It also handles `(neg x)` inside the shift by absorbing it into a negative multiplier.

### Address form summary

Combining the rules from §1–§3, the canonical forms for common m68k address expressions are:

| Address | Canonical RTL |
|---------|---------------|
| `(An)` | `(mem (reg An))` |
| `d(An)` | `(mem (plus (reg An) (const_int d)))` |
| `(An,Xn)` | `(mem (plus (reg An) (reg Xn)))` — pointer reg first when `REG_POINTER` set |
| `d(An,Xn)` | `(mem (plus (plus (reg An) (reg Xn)) (const_int d)))` — constant outermost |
| `(An,Xn*S)` | `(mem (plus (mult (reg Xn) (const_int S)) (reg An)))` — MULT first |
| `d(An,Xn*S)` | `(mem (plus (plus (mult (reg Xn) (const_int S)) (reg An)) (const_int d)))` |

**Note:** The MULT-first ordering follows from `commutative_operand_precedence`: `RTX_COMM_ARITH` (+4) ranks above `RTX_OBJ` (−2). Inside the inner PLUS, MULT goes left and the base register goes right. The constant displacement is outermost per §3.

**Note:** The `REG_POINTER` flag affects ordering of two plain registers. When one register has `REG_POINTER` set (priority −1) and the other doesn't (−2), the pointer register goes first. In practice, this flag is not always set reliably, so m68k patterns should accept both orderings when matching `base + index`.

**Source:** `gcc/doc/md.texi` lines 8966–8967; `gcc/combine.cc` lines 8090–8108

---

## 7. Comparison Canonicalization

### Constant as second operand

```
(compare (reg) (const_int N))     ;; canonical
(compare (const_int N) (reg))     ;; NOT canonical
```

When a `compare` has a condition code register as the first argument, a constant is always the second operand.

### Operand ordering in compare

The same complex-first rules apply: `neg`, `not`, `mult`, `plus`, or `minus` expressions go first.

### Constant boundary reduction

`simplify_comparison()` in `gcc/combine.cc` normalizes comparisons against constants to use the smallest possible constant, preferring zero:

| Before | After | Condition |
|--------|-------|-----------|
| `(lt x (const_int C))` C>0 | `(le x (const_int C-1))` | |
| `(le x (const_int 0))` | `(eq x (const_int 0))` | when sign bit known zero |
| `(gt x (const_int C))` C<0 | `(ge x (const_int C+1))` | |
| `(ge x (const_int 0))` | `(ne x (const_int 0))` | when sign bit known zero |
| `(ltu x (const_int C))` C>0 | `(leu x (const_int C-1))` | |
| `(leu x (const_int 0))` | `(eq x (const_int 0))` | |
| `(geu x (const_int C))` C>1 | `(gtu x (const_int C-1))` | |
| `(gtu x (const_int 0))` | `(ne x (const_int 0))` | |

### Bit-test comparison

Equality comparisons of a group of bits with zero use `zero_extract` rather than `and` or `sign_extract`:

```
(eq (zero_extract x 1 pos) (const_int 0))  ;; canonical for single-bit test
(eq (and x (const_int 8)) (const_int 0))   ;; NOT canonical
```

### Overflow comparison

```
(ltu (plus a b) a)                ;; canonical
(ltu (plus a b) b)                ;; NOT canonical — converted to use 'a'
```

Likewise with `geu`.

### Parallel compare

Instructions that inherently set condition codes place the `compare` as the first expression in a `parallel`:

```
(parallel [
  (set (reg:CC cc) (compare ...))          ;; FIRST
  (set (reg dst) (plus ...))])
```

**Source:** `gcc/doc/md.texi` lines 8929–8960, 9022–9025; `gcc/combine.cc` lines 11896–12753

---

## 8. Extension and Extraction

### SIGN_EXTEND / ZERO_EXTEND with MULT

Extensions are pushed through multiplication:

```
(mult (sign_extend x) (sign_extend y))     ;; canonical (wider mode)
(sign_extend (mult x y))                   ;; NOT canonical
```

This also applies to `zero_extend`. The rule extends to shifted operands:

```
(mult (sign_extend (ashiftrt x s)) (sign_extend y))  ;; canonical
(sign_extend (mult (ashiftrt x s) (sign_extend y)))  ;; NOT canonical
```

### AND to ZERO_EXTRACT (combine)

`make_compound_operation()` converts AND with power-of-two-minus-one masks into `zero_extract`:

```
(zero_extract x 8 0)              ;; canonical (in comparison context)
(and x (const_int 255))           ;; may be converted by combine
```

### Shift to SIGN_EXTRACT / ZERO_EXTRACT (combine)

Shift pairs are converted to extractions:

```
;; (lshiftrt (ashift x C1) C2) where C2 >= C1:
(zero_extract x (width-C2) (C2-C1))   ;; canonical

;; (ashiftrt (ashift x C1) C2) where C2 >= C1:
(sign_extract x (width-C2) (C2-C1))   ;; canonical
```

**Source:** `gcc/doc/md.texi` lines 9028–9043; `gcc/combine.cc` lines 8090–8381

---

## 9. simplify_plus_minus Internals

`simplify_plus_minus()` in `gcc/simplify-rtx.cc` is the heavy-duty canonicalizer for PLUS/MINUS trees. It operates in four phases:

### Phase 1: Flatten

Recursively decompose nested PLUS/MINUS/NEG into a flat array of up to 16 `{op, neg}` entries:

- `(plus A B)` → entries `{A, false}`, `{B, false}`
- `(minus A B)` → entries `{A, false}`, `{B, true}`
- `(neg A)` → entry `{A, true}`
- `(not A)` → entries `{A, true}`, `{const_int 1, false}` (since `~a = -a - 1`)
- Negative `const_int` with `neg=true` → positive `const_int` with `neg=false`

### Phase 2: Sort

Insertion sort by `commutative_operand_precedence()`. Higher-precedence operands (complex expressions) sort to the front; constants sort to the back.

### Phase 3: Pairwise simplify

Try all pairs of operands for simplifiable combinations:

- `a + (-a)` → cancel both
- Two constants → fold into one
- `a + a` → `2*a` (when profitable)

### Phase 4: Rebuild

Build the result left-to-right:

```
result = ops[0]
for each remaining ops[i]:
    if ops[i].neg:
        result = (minus result ops[i])
    else:
        result = (plus result ops[i])
```

The first operand is always non-negated. If all operands are negated, the first is wrapped in `NEG`.

**Source:** `gcc/simplify-rtx.cc` lines 5841–6164

---

## 10. simplify_associative_operation Internals

`simplify_associative_operation()` in `gcc/simplify-rtx.cc` enforces left-chaining for a single associative operator. It has a recursion guard (`max_assoc_count`) to prevent quadratic blowup on large expressions (e.g. during var-tracking).

### Left-linearization

```
(a op (b op c))  →  ((b op c) op a)  or  ((a op b) op c)
```

If `op1` is itself the same operator, the function restructures to put it on the left.

### Constants to the outside

```
((x op c) op y)  →  ((x op y) op c)     when c has lower precedence than y
```

This pushes constants outermost, consistent with the constant positioning rules.

### Opportunistic simplification

After left-linearization, tries reassociating `(a op b) op c` as:

1. `a op (b op c)` — does the inner pair simplify?
2. `(a op c) op b` — does the outer pair simplify?

If either produces a simpler result, it's used.

**Source:** `gcc/simplify-rtx.cc` lines 2393–2447

---

## 11. m68k-Specific: canon_scaled_index

**Pass:** `m68k_pass_canon_scaled_index` (7.29b)

**Code:** `gcc/config/m68k/m68k-rtl-passes.cc` lines 4328–4507

### The problem

When fwprop substitutes `idx + idx` (from a ×2 scale) into a memory address, `simplify_gen_binary` left-chains the result per the associativity rule:

```
(plus base (plus idx idx))  →  (plus (plus base idx) idx)
```

This is valid per the general canonicalization rules — PLUS chains left (§2). But the result has three register operands with no scale operator. GCC's address decomposition (`decompose_normal_address` in `gcc/rtlanal.cc`) can handle at most two ambiguous register operands. Three registers cause an assertion failure, and even when it doesn't assert, the form doesn't match any `define_insn` pattern because there's no explicit index scale.

GCC's `simplify_plus_minus` can sometimes fold `idx + idx` into `(mult idx 2)`, but this only happens when the two identical terms appear as separate entries in the flattened array and the simplifier attempts pairwise combination. When they arrive embedded in a larger expression, the folding doesn't always fire.

### The fix

The canon pass, running after `pass_inc_dec` (7.29) and before IRA, rewrites inside MEM expressions:

```
(plus (plus A B) C) where B == C  →  (plus A (ashift C 1))
(plus (plus A B) C) where A == C  →  (plus B (ashift C 1))
```

The ASHIFT wrapper makes the index explicit. Address decomposition classifies it as a scaled index rather than an ambiguous third register, and the expression matches `*lea_indexed_disp_scaled` or similar patterns.

**Why not MULT?** Inside MEM, combine converts ASHIFT to MULT (§6). But the canon pass runs after combine, so using ASHIFT is correct — no further ASHIFT→MULT conversion will occur. The m68k `define_insn` patterns match the ASHIFT form.

### Interaction with other passes

The canon pass only processes MEM sub-expressions. It does not affect non-address uses of the 3-register form.

**Source:** `gcc/config/m68k/m68k-rtl-passes.cc` lines 4328–4507; see also [M68K_OPTIMIZATIONS.md §16](M68K_OPTIMIZATIONS.md#16-lra-register-allocator)
