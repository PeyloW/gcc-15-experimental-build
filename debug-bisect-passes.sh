#!/bin/bash
# Find which m68k pass causes a change in assembly output
# See GCC_DEBUG.md section 2 for background

set -e

# --- Defaults ---
OPT_FLAGS="-Os -mshort -mfastcall"
EXTRA_FLAGS=""
FUNC=""
ICE_MODE=false

XGCC="./build-host/gcc/xgcc"
OUTDIR="./tmp/debug"

# m68k-specific flags to iterate, ordered by pass execution phase
M68K_FLAGS=(
    # Phase 5 — GIMPLE
    "-mno-m68k-narrow-index-mult"    # 5.26a
    "-fno-ivopts-autoinc-step"       # 5.95 (IV step discount)
    "-mno-m68k-autoinc"              # 5.95a (split) + 9.13a/9.14b (RTL convert)
    "-mno-m68k-reorder-mem"          # 5.123a
    # Phase 7 — RTL pre-RA
    "-mno-m68k-doloop"               # 7.21 (pass_rtl_doloop)
    "-mno-m68k-avail-copy-elim"      # 7.29a
    # Phase 8 — Register allocation
    "-mno-m68k-ira-promote"          # 8.1
    # Phase 9 — RTL post-RA
    "-mno-m68k-btst-extract"         # 9.14 (peephole2)
    "-mno-m68k-highword-opt"         # 9.19a
    "-mno-m68k-elim-andi"            # 9.19b
    # All costing
    "-mno-m68k-insn-cost"            # TARGET_INSN_COST hook
)

# --- Colors (only if stdout is a terminal) ---
if [ -t 1 ]; then
    BOLD='\033[1m'
    GREEN='\033[1;32m'
    RED='\033[1;31m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    BOLD="" GREEN="" RED="" DIM="" RESET=""
fi

usage() {
    cat <<EOF
Usage: $0 [options] <source.c>

Disable each m68k pass individually to find which one causes a change.

Options:
  -f FUNC    Focus on function FUNC only
  -O FLAGS   Optimization flags (default: $OPT_FLAGS)
  -x FLAGS   Extra compiler flags
  -ice       Search for ICE failures instead of instruction count changes
  -h         Show this help

Examples:
  $0 test.c
  $0 -f my_func test.c
  $0 -ice test.c
EOF
    exit 1
}

# --- Parse args ---
# Manual parsing to support -ice (multi-char flag)
while [ $# -gt 0 ]; do
    case "$1" in
        -f)   FUNC="$2"; shift 2 ;;
        -O)   OPT_FLAGS="$2"; shift 2 ;;
        -x)   EXTRA_FLAGS="$2"; shift 2 ;;
        -ice) ICE_MODE=true; shift ;;
        -h)   usage ;;
        -*)   echo "Unknown option: $1"; usage ;;
        *)    break ;;
    esac
done

SOURCE="${1:-}"
if [ -z "$SOURCE" ]; then
    echo "Error: no source file specified"
    usage
fi

if [ ! -f "$SOURCE" ]; then
    echo "Error: $SOURCE not found"
    exit 1
fi

if [ ! -f "$XGCC" ]; then
    echo "Error: $XGCC not found — run ./build-gcc.sh build first"
    exit 1
fi

# --- Setup ---
mkdir -p "$OUTDIR"
BASE=$(basename "$SOURCE" | sed 's/\.[^.]*$//')
FLAGS="$OPT_FLAGS $EXTRA_FLAGS -fno-inline"

echo -e "${BOLD}Source:${RESET} $SOURCE"
echo -e "${BOLD}Flags:${RESET}  $FLAGS"
[ -n "$FUNC" ] && echo -e "${BOLD}Function:${RESET} $FUNC"
$ICE_MODE && echo -e "${BOLD}Mode:${RESET}  ICE detection"
echo ""

# --- Extract a function from assembly (ELF bare name or a.out _ prefix) ---
extract_func() {
    local file="$1"
    local result
    result=$(sed -n "/^_${FUNC}:/,/^\\t\\.size/p" "$file")
    if [ -z "$result" ]; then
        result=$(sed -n "/^${FUNC}:/,/^\\t\\.size/p" "$file")
    fi
    echo "$result"
}

# --- Count instructions ---
count_insns() {
    local file="$1"
    local count
    if [ -n "$FUNC" ]; then
        count=$(extract_func "$file" | grep -cE $'^\t[a-z]' || true)
    else
        count=$(grep -cE $'^\t[a-z]' "$file" || true)
    fi
    echo "${count:-0}"
}

# --- Compile helper (returns 0 even on ICE) ---
compile() {
    local outfile="$1"
    shift
    "$XGCC" -B./build-host/gcc $FLAGS "$@" -S "$SOURCE" -o "$outfile" 2>"$outfile.err" || true
}

# --- Check if compilation produced an ICE ---
has_ice() {
    grep -q "internal compiler error" "$1.err" 2>/dev/null
}

# --- Extract ICE message ---
get_ice_message() {
    grep "internal compiler error" "$1.err" 2>/dev/null | head -1
}

if $ICE_MODE; then
    # === ICE detection mode ===

    # --- Baseline ---
    BASELINE="$OUTDIR/${BASE}_baseline.s"
    compile "$BASELINE"
    baseline_ice=false
    if has_ice "$BASELINE"; then
        baseline_ice=true
    fi

    # --- Print table header ---
    printf "\n${BOLD}%-35s  %s${RESET}\n" "Pass" "ICE?"
    printf "%-35s  %s\n" "---" "----"

    # Baseline row
    if $baseline_ice; then
        printf "%-35s  ${RED}ICE${RESET}\n" "baseline (all enabled)"
        echo -e "  ${DIM}$(get_ice_message "$BASELINE")${RESET}"
    else
        printf "%-35s  ${DIM}ok${RESET}\n" "baseline (all enabled)"
    fi

    # --- All m68k passes disabled ---
    ALL_DISABLED="$OUTDIR/${BASE}_all_disabled.s"
    compile "$ALL_DISABLED" "${M68K_FLAGS[@]}"
    if has_ice "$ALL_DISABLED"; then
        printf "%-35s  ${RED}ICE${RESET}\n" "all m68k disabled"
        echo -e "  ${DIM}$(get_ice_message "$ALL_DISABLED")${RESET}"
    else
        state="ok"
        # Highlight if baseline ICEs but this doesn't (= m68k pass is the culprit)
        if $baseline_ice; then
            state="${GREEN}ok (ICE gone!)${RESET}"
        else
            state="${DIM}ok${RESET}"
        fi
        printf "%-35s  $state\n" "all m68k disabled"
    fi

    # --- Each pass individually ---
    for flag in "${M68K_FLAGS[@]}"; do
        outfile="$OUTDIR/${BASE}_${flag}.s"
        compile "$outfile" "$flag"

        if has_ice "$outfile"; then
            printf "%-35s  ${RED}ICE${RESET}\n" "$flag"
            echo -e "  ${DIM}$(get_ice_message "$outfile")${RESET}"
        else
            if $baseline_ice; then
                printf "%-35s  ${GREEN}ok (ICE gone!)${RESET}\n" "$flag"
            else
                printf "%-35s  ${DIM}ok${RESET}\n" "$flag"
            fi
        fi
    done

else
    # === Instruction count mode ===

    # --- Baseline (all passes enabled) ---
    BASELINE="$OUTDIR/${BASE}_baseline.s"
    compile "$BASELINE"
    baseline_count=$(count_insns "$BASELINE")

    # --- All m68k passes disabled ---
    ALL_DISABLED="$OUTDIR/${BASE}_all_disabled.s"
    compile "$ALL_DISABLED" "${M68K_FLAGS[@]}"
    all_disabled_count=$(count_insns "$ALL_DISABLED")
    all_diff=$((all_disabled_count - baseline_count))

    # --- Print table header ---
    printf "\n${BOLD}%-35s %6s %6s  %s${RESET}\n" "Pass" "Insns" "Diff" "Changed?"
    printf "%-35s %6s %6s  %s\n" "---" "-----" "----" "--------"

    # Baseline row
    printf "%-35s %6d\n" "baseline (all enabled)" "$baseline_count"

    # All disabled row
    if [ "$all_diff" -ne 0 ]; then
        printf "%-35s %6d %+5d  ${GREEN}YES${RESET}\n" "all m68k disabled" "$all_disabled_count" "$all_diff"
    else
        printf "%-35s %6d %5d  ${DIM}no${RESET}\n" "all m68k disabled" "$all_disabled_count" "$all_diff"
    fi

    # --- Each pass individually ---
    for flag in "${M68K_FLAGS[@]}"; do
        outfile="$OUTDIR/${BASE}_${flag}.s"
        compile "$outfile" "$flag"
        count=$(count_insns "$outfile")
        diff=$((count - baseline_count))

        if [ "$diff" -ne 0 ]; then
            printf "%-35s %6d %+5d  ${GREEN}YES${RESET}\n" "$flag" "$count" "$diff"
        else
            printf "%-35s %6d %5d  ${DIM}no${RESET}\n" "$flag" "$count" "$diff"
        fi
    done
fi

echo ""
echo -e "${DIM}Temp files in $OUTDIR/${RESET}"
