#!/bin/bash
# Generate assembly output for test_cases.cpp with various optimization options
# Compares output between system compiler (old) and built compiler (new)
#
# Default: show max clock cycles per variant (requires clccnt)
# -s: show instruction count (size) instead of cycles
# -reload: include reload (legacy register allocator) comparison columns

set -e

# Parse options
MODE="cycles"
SHOW_RELOAD=false
for arg in "$@"; do
    case $arg in
        -s) MODE="size" ;;
        -reload) SHOW_RELOAD=true ;;
        *) echo "Usage: $0 [-s] [-reload]"; exit 1 ;;
    esac
done

# Fall back to size mode if clccnt is not available
CLCCNT=$(command -v clccnt 2>/dev/null || true)
if [ "$MODE" = "cycles" ] && [ -z "$CLCCNT" ]; then
    MODE="size"
fi

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
COMMON_FLAGS="-mfastcall -fira-region=mixed"
echo "Common flags: $COMMON_FLAGS"
echo ""

# Accumulated build times (in milliseconds for precision)
time_old_ms=0
time_new_ms=0
time_reload_ms=0  # only used with -reload

# Function to generate assembly
generate() {
    local suffix="$1"
    local flags="$2"
    local t0 t1

    # Old (system compiler)
    t0=$(perl -MTime::HiRes=time -e 'printf "%.0f", time()*1000')
    m68k-atari-mintelf-gcc $COMMON_FLAGS $flags -fno-inline -S "$SOURCE" -o "$OUTPUT_DIR/${suffix}_old.s" 2>/dev/null || true
    t1=$(perl -MTime::HiRes=time -e 'printf "%.0f", time()*1000')
    time_old_ms=$((time_old_ms + t1 - t0))

    # New (built compiler, LRA is default)
    t0=$(perl -MTime::HiRes=time -e 'printf "%.0f", time()*1000')
    ./build-host/gcc/xgcc -B./build-host/gcc $COMMON_FLAGS $flags -fno-inline -S "$SOURCE" -o "$OUTPUT_DIR/${suffix}_new.s" 2>/dev/null || true
    t1=$(perl -MTime::HiRes=time -e 'printf "%.0f", time()*1000')
    time_new_ms=$((time_new_ms + t1 - t0))

    # Reload (built compiler with legacy reload) - only with -reload
    if $SHOW_RELOAD; then
        t0=$(perl -MTime::HiRes=time -e 'printf "%.0f", time()*1000')
        ./build-host/gcc/xgcc -B./build-host/gcc $COMMON_FLAGS $flags -mno-lra -fno-inline -S "$SOURCE" -o "$OUTPUT_DIR/${suffix}_reload.s" 2>/dev/null || true
        t1=$(perl -MTime::HiRes=time -e 'printf "%.0f", time()*1000')
        time_reload_ms=$((time_reload_ms + t1 - t0))
    fi
}

# Generate for different optimization levels
generate "O2" "-O2"
generate "O2_short" "-O2 -mshort"
generate "Os" "-Os"
generate "Os_short" "-Os -mshort"

# 68030 variants
generate "O2_68030" "-O2 -m68030"
generate "Os_68030" "-Os -m68030"

# 68060 variants
generate "O2_68060" "-O2 -m68060"
generate "Os_68060" "-Os -m68060"

# ColdFire variants
generate "O2_cf" "-O2 -mcpu=5475"
generate "Os_cf" "-Os -mcpu=5475"

# Count instruction lines for comparison
# Instructions start with a tab followed by a letter (excludes labels, directives, comments)
count_instructions() {
    grep -cE $'^\t[a-z]' "$1" 2>/dev/null || echo 0
}

# Sum max clock cycles using clccnt (last column of plain text output)
count_cycles() {
    local file="$1"
    local cpu="$2"
    "$CLCCNT" -c "$cpu" "$file" 2>/dev/null | awk '{sum += $NF} END {print sum+0}'
}

# Metric function: dispatches to cycles or instructions based on MODE
count_metric() {
    local file="$1"
    local cpu="$2"
    if [ "$MODE" = "cycles" ]; then
        count_cycles "$file" "$cpu"
    else
        count_instructions "$file"
    fi
}

# Map variant suffix to clccnt CPU model
# ColdFire has no cycle model; use 060 as closest approximation
cpu_for_variant() {
    case "$1" in
        *_68030) echo "030" ;;
        *_68060) echo "060" ;;
        *_cf)    echo "060" ;;
        *)       echo "000" ;;
    esac
}

echo ""
if [ "$MODE" = "cycles" ]; then
    echo "Max Clock Cycle Comparison"
    echo "=========================="
else
    echo "Assembly Instruction Count Comparison"
    echo "======================================"
fi
echo ""
if $SHOW_RELOAD; then
    printf "%-22s %8s %8s %8s %8s %8s %8s\n" "Variant" "Old" "New" "Diff%" "Reload" "Reldiff" "Rel%"
    printf "%-22s %8s %8s %8s %8s %8s %8s\n" "-------" "---" "---" "-----" "------" "-------" "----"
else
    printf "%-22s %8s %8s %8s\n" "Variant" "Old" "New" "Diff%"
    printf "%-22s %8s %8s %8s\n" "-------" "---" "---" "-----"
fi

for variant in "O2:O2" "O2 -mshort:O2_short" "Os:Os" "Os -mshort:Os_short" "O2 -m68030:O2_68030" "Os -m68030:Os_68030" "O2 -m68060:O2_68060" "Os -m68060:Os_68060" "O2 -mcpu=5475:O2_cf" "Os -mcpu=5475:Os_cf"; do
    display_name="${variant%%:*}"
    suffix="${variant##*:}"
    cpu=$(cpu_for_variant "$suffix")

    old_file="$OUTPUT_DIR/${suffix}_old.s"
    new_file="$OUTPUT_DIR/${suffix}_new.s"
    reload_file="$OUTPUT_DIR/${suffix}_reload.s"

    if [ -f "$old_file" ] && [ -f "$new_file" ]; then
        old_count=$(count_metric "$old_file" "$cpu")
        new_count=$(count_metric "$new_file" "$cpu")
        diff=$((new_count - old_count))
        if [ "$old_count" -gt 0 ]; then
            pct=$(awk "BEGIN {printf \"%.1f\", ($diff / $old_count) * 100}")
        else
            pct="0.0"
        fi

        if $SHOW_RELOAD; then
            # Reload columns (compare Reload vs New)
            if [ -f "$reload_file" ]; then
                reload_count=$(count_metric "$reload_file" "$cpu")
                reload_diff=$((reload_count - new_count))
                if [ "$new_count" -gt 0 ]; then
                    reload_pct=$(awk "BEGIN {printf \"%.1f\", ($reload_diff / $new_count) * 100}")
                else
                    reload_pct="0.0"
                fi
                printf "%-22s %8d %8d %7s%% %8d %8d %6s%%\n" "$display_name" "$old_count" "$new_count" "$pct" "$reload_count" "$reload_diff" "$reload_pct"
            else
                printf "%-22s %8d %8d %7s%% %8s %8s %6s\n" "$display_name" "$old_count" "$new_count" "$pct" "ERR" "-" "-"
            fi
        else
            printf "%-22s %8d %8d %7s%%\n" "$display_name" "$old_count" "$new_count" "$pct"
        fi
    fi
done

# Print build times
time_old_s=$(awk "BEGIN {printf \"%.1f\", $time_old_ms / 1000}")
time_new_s=$(awk "BEGIN {printf \"%.1f\", $time_new_ms / 1000}")
if $SHOW_RELOAD; then
    time_reload_s=$(awk "BEGIN {printf \"%.1f\", $time_reload_ms / 1000}")
    printf "%-22s %7ss %7ss %8s %7ss\n" "Time" "$time_old_s" "$time_new_s" "" "$time_reload_s"
else
    printf "%-22s %7ss %7ss\n" "Time" "$time_old_s" "$time_new_s"
fi

echo ""
echo "Output directory: $(pwd)/$OUTPUT_DIR"
