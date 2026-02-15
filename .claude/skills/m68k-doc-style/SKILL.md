---
user-invocable: false
description: Loaded when writing or editing markdown documentation files in this project.
---

# Documentation Style

## Succinctness

Be as succinct as possible without losing clarity. Avoid verbose explanations when a short sentence or example suffices.

## Formatting Rules

All bullet lists and code blocks (starting with ```) must have an empty line before them. The user's Markdown editor requires this.

Good:

```markdown
Some text.

- Item 1
- Item 2

More text.

` ` `
code here
` ` `
```

Bad:

```markdown
Some text.
- Item 1
- Item 2

More text.
` ` `
code here
` ` `
```

## Pass Number Citations

When referring to GCC passes, include the pass number from `GCC_PASSES.md`:

- Good: "the combine pass (7.33)"
- Good: "`m68k_pass_autoinc_split` (5.95a)"
- Bad: "the combine pass"
- Bad: "the autoinc split pass"

Look up the pass number in `GCC_PASSES.md` when applicable.
