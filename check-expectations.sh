#!/bin/bash
# Check the assembly produced for test_cases.cpp against test_expectations.txt.
#
# build-test_cases.sh answers "did the code get bigger or smaller".  This answers
# "is the property that a known bug destroyed still there".  Run it after
# build-test_cases.sh, which leaves the .s files in tmp/test_cases/.
#
# Exit status is 1 if any expectation fails, so it can gate a commit.

set -u

EXPECT="test_expectations.txt"
ASMDIR="tmp/test_cases"

# Variants checked by default.  -mshort is left out on purpose: 16-bit int
# rewrites these sequences and the expectations do not describe them.
ALL_VARIANTS="O2 Os O2_68030 Os_68030 O2_68040 Os_68040 O2_68060 Os_68060 O2_cf Os_cf"

[ -f "$EXPECT" ] || { echo "Error: $EXPECT not found"; exit 1; }
[ -d "$ASMDIR" ] || { echo "Error: $ASMDIR not found — run ./build-test_cases.sh first"; exit 1; }

# Flatten one function body to a single line so a pattern can span instructions.
# Starts at the label, stops at the next label in column 0.
extract_fn () {
    awk -v s="_$2:" '
        index($0, s) == 1 { p = 1; next }
        p && /^[_a-zA-Z][a-zA-Z0-9_]*:/ { exit }
        p && /^\t[a-z]/ { gsub(/^\t/, ""); printf "%s ; ", $0 }
    ' "$1"
}

fail=0
checked=0
missing=""

while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac

    fn=$(echo "$line"   | cut -d'|' -f1 | tr -d ' ')
    kind=$(echo "$line" | cut -d'|' -f2 | tr -d ' ')
    vars=$(echo "$line" | cut -d'|' -f3 | sed 's/^ *//; s/ *$//')
    # The regex is everything after the third separator, so it may contain "|".
    rx=$(echo "$line"   | cut -d'|' -f4- | sed 's/^ *//; s/ *$//')
    [ "$vars" = "*" ] && vars="$ALL_VARIANTS"

    case "$kind" in
        must|must-not) ;;
        *) echo "MALFORMED  unknown kind '$kind' in: $line"; fail=$((fail + 1)); continue ;;
    esac
    if [ -z "$rx" ]; then
        echo "MALFORMED  empty pattern in: $line"; fail=$((fail + 1)); continue
    fi

    for v in $vars; do
        f="$ASMDIR/${v}_new.s"
        if [ ! -f "$f" ]; then
            echo "MALFORMED  no assembly for variant '$v' in: $line"
            fail=$((fail + 1))
            continue
        fi

        body=$(extract_fn "$f" "$fn")
        if [ -z "$body" ]; then
            case "$missing" in *" $fn "*) ;; *) missing="$missing $fn " ;; esac
            continue
        fi

        checked=$((checked + 1))
        if echo "$body" | grep -qE "$rx"; then found=yes; else found=no; fi

        if { [ "$kind" = must ] && [ "$found" = no ]; } \
        || { [ "$kind" = must-not ] && [ "$found" = yes ]; }; then
            printf 'FAIL  %-32s %-9s %-22s [%s]\n' "$fn" "$kind" "$rx" "$v"
            printf '        %s\n' "$body"
            fail=$((fail + 1))
        fi
    done
done < "$EXPECT"

echo ""
[ -n "$missing" ] && echo "Note: function not found in some variants (inlined away?):$missing"

if [ "$fail" -eq 0 ]; then
    echo "All expectations hold ($checked checks)."
    exit 0
fi
echo "$fail of $checked checks failed."
exit 1
