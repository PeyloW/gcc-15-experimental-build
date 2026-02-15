#!/bin/bash
# Generate assembly output for test_cases.cpp with various optimization options
# Compares output between system compiler (old) and built compiler (new)

set -e

SOURCE="test_cases.cpp"
OUTPUT_DIR="tmp/test_cases"

if [ ! -f "$SOURCE" ]; then
    echo "Error: $SOURCE not found"
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

echo "Generating assembly files for $SOURCE..."

# Common flags for fastcall ABI
# COMMON_FLAGS="-mfastcall -fpeel-loops -funroll-loops"
COMMON_FLAGS="-mfastcall"
echo "Common flags: $COMMON_FLAGS"
echo ""

# Function to generate assembly
generate() {
    local suffix="$1"
    local flags="$2"

    # Old (system compiler)
    m68k-atari-mintelf-gcc $COMMON_FLAGS $flags -fno-inline -S "$SOURCE" -o "$OUTPUT_DIR/${suffix}_old.s" 2>/dev/null || true

    # New (built compiler)
    ./build-host/gcc/xgcc -B./build-host/gcc $COMMON_FLAGS $flags -fno-inline -S "$SOURCE" -o "$OUTPUT_DIR/${suffix}_new.s" 2>/dev/null || true
}

# Generate for different optimization levels
generate "O2" "-O2"
generate "O2_short" "-O2 -mshort"
generate "Os" "-Os"
generate "Os_short" "-Os -mshort"

# 68030 variants
generate "O2_68030" "-O2 -m68030"
generate "Os_68030" "-Os -m68030"

# Count instruction lines for comparison
# Instructions start with a tab followed by a letter (excludes labels, directives, comments)
count_instructions() {
    grep -cE $'^\t[a-z]' "$1" 2>/dev/null || echo 0
}

echo ""
echo "Assembly Instruction Count Comparison"
echo "======================================"
echo ""
printf "%-25s %8s %8s %8s %8s\n" "Variant" "Old" "New" "Diff" "Diff%"
printf "%-25s %8s %8s %8s %8s\n" "-------" "---" "---" "----" "-----"

for variant in "O2:O2" "O2 -mshort:O2_short" "Os:Os" "Os -mshort:Os_short" "O2 -m68030:O2_68030" "Os -m68030:Os_68030"; do
    display_name="${variant%%:*}"
    suffix="${variant##*:}"

    old_file="$OUTPUT_DIR/${suffix}_old.s"
    new_file="$OUTPUT_DIR/${suffix}_new.s"

    if [ -f "$old_file" ] && [ -f "$new_file" ]; then
        old_count=$(count_instructions "$old_file")
        new_count=$(count_instructions "$new_file")
        diff=$((new_count - old_count))
        if [ "$old_count" -gt 0 ]; then
            pct=$(awk "BEGIN {printf \"%.1f\", ($diff / $old_count) * 100}")
        else
            pct="0.0"
        fi
        printf "%-25s %8d %8d %8d %7s%%\n" "$display_name" "$old_count" "$new_count" "$diff" "$pct"
    fi
done

echo ""
echo "Output directory: $(pwd)/$OUTPUT_DIR"
