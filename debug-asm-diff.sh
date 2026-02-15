#!/bin/bash
# Compare assembly output between stock GCC 15 and this branch
# See GCC_DEBUG.md section 1 for background

set -e

# --- Defaults ---
OPT_FLAGS="-Os -mshort -mfastcall"
EXTRA_FLAGS=""
FUNC=""
NEW_ONLY=false

XGCC="./build-host/gcc/xgcc"
OLD_CC="m68k-atari-mintelf-gcc"
OUTDIR="./tmp/debug"

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

Compare assembly output between stock GCC 15 and this branch.

Options:
  -f FUNC    Extract and diff only function FUNC
  -O FLAGS   Optimization flags (default: $OPT_FLAGS)
  -x FLAGS   Extra compiler flags appended to both compilers
  -n         New compiler only (skip old, just compile and show)
  -h         Show this help

Examples:
  $0 test.c
  $0 -f memcmp memcmp.c
  $0 -O "-O2" -x "-mcpu=68030" test.c
EOF
    exit 1
}

# --- Parse args ---
while getopts "f:O:x:nh" opt; do
    case $opt in
        f) FUNC="$OPTARG" ;;
        O) OPT_FLAGS="$OPTARG" ;;
        x) EXTRA_FLAGS="$OPTARG" ;;
        n) NEW_ONLY=true ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

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

NEW_ASM="$OUTDIR/${BASE}_new.s"
OLD_ASM="$OUTDIR/${BASE}_old.s"

echo -e "${BOLD}Source:${RESET} $SOURCE"
echo -e "${BOLD}Flags:${RESET}  $FLAGS"
[ -n "$FUNC" ] && echo -e "${BOLD}Function:${RESET} $FUNC"
echo ""

# --- Extract a function from assembly ---
# ELF uses bare name, a.out uses _ prefix; try both
extract_func() {
    local file="$1"
    local result
    result=$(sed -n "/^_${FUNC}:/,/^\\t\\.size/p" "$file")
    if [ -z "$result" ]; then
        result=$(sed -n "/^${FUNC}:/,/^\\t\\.size/p" "$file")
    fi
    echo "$result"
}

# --- Count instructions in file or extracted function ---
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

# --- Compile ---
echo -e "${BOLD}Compiling...${RESET}"

"$XGCC" -B./build-host/gcc $FLAGS -S "$SOURCE" -o "$NEW_ASM" 2>/dev/null
new_count=$(count_insns "$NEW_ASM")

if $NEW_ONLY; then
    echo -e "  new: ${GREEN}${new_count} insns${RESET}  → $NEW_ASM"
    echo ""
    if [ -n "$FUNC" ]; then
        extract_func "$NEW_ASM"
    else
        cat "$NEW_ASM"
    fi
    exit 0
fi

"$OLD_CC" $FLAGS -S "$SOURCE" -o "$OLD_ASM" 2>/dev/null
old_count=$(count_insns "$OLD_ASM")

diff_count=$((new_count - old_count))
if [ "$diff_count" -gt 0 ]; then
    diff_str="${RED}+${diff_count}${RESET}"
elif [ "$diff_count" -lt 0 ]; then
    diff_str="${GREEN}${diff_count}${RESET}"
else
    diff_str="${DIM}0${RESET}"
fi

echo -e "  old: ${old_count} insns"
echo -e "  new: ${new_count} insns  (${diff_str})"
echo ""

# --- Diff ---
if [ -n "$FUNC" ]; then
    extract_func "$OLD_ASM" > "$OUTDIR/${BASE}_old_func.s"
    extract_func "$NEW_ASM" > "$OUTDIR/${BASE}_new_func.s"
    diff -u "$OUTDIR/${BASE}_old_func.s" "$OUTDIR/${BASE}_new_func.s" || true
else
    diff -u "$OLD_ASM" "$NEW_ASM" || true
fi
