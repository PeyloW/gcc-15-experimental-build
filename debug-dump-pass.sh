#!/bin/bash
# Dump and diff GCC pass output (RTL or GIMPLE)
# See GCC_DEBUG.md section 3 for background

set -e

# --- Defaults ---
OPT_FLAGS="-Os -mshort -mfastcall"
EXTRA_FLAGS=""
FUNC=""

XGCC="./build-host/gcc/xgcc"
OUTDIR="./tmp/debug"

# Known RTL pass name prefixes (for auto-detection)
RTL_PASSES="combine|cse|peephole|reload|sched|ira|pro_and_epilogue|cprop|dce|dse|fwprop|gcse|jump|loop|postreload|ree|rnreg|split|vartrack|m68k-"

# --- Colors (only if stdout is a terminal) ---
if [ -t 1 ]; then
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    BOLD="" DIM="" RESET=""
fi

usage() {
    cat <<EOF
Usage: $0 [options] <source.c> <pass> [pass2]

Dump GCC pass output. With two passes, diff their output.

Options:
  -f FUNC    Show only function FUNC in dumps
  -O FLAGS   Optimization flags (default: $OPT_FLAGS)
  -x FLAGS   Extra compiler flags
  -h         Show this help

Pass names:
  RTL passes: combine, cse2, peephole2, m68k-autoinc, ...
  GIMPLE passes: ivopts, pre, fre, ...

Examples:
  $0 test.c combine                  # Show combine pass dump
  $0 test.c cse2 combine             # Diff cse2 → combine
  $0 -f my_func test.c m68k-autoinc  # Show autoinc dump for one function
EOF
    exit 1
}

# --- Parse args ---
while getopts "f:O:x:h" opt; do
    case $opt in
        f) FUNC="$OPTARG" ;;
        O) OPT_FLAGS="$OPTARG" ;;
        x) EXTRA_FLAGS="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

SOURCE="${1:-}"
PASS1="${2:-}"
PASS2="${3:-}"

if [ -z "$SOURCE" ] || [ -z "$PASS1" ]; then
    echo "Error: need source file and at least one pass name"
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
SRCBASE=$(basename "$SOURCE")
FLAGS="$OPT_FLAGS $EXTRA_FLAGS -fno-inline"
# Use -dumpdir to put all dump files in OUTDIR
DUMP_COMMON="-dumpdir ${OUTDIR}/"

echo -e "${BOLD}Source:${RESET} $SOURCE"
echo -e "${BOLD}Flags:${RESET}  $FLAGS"
echo -e "${BOLD}Pass:${RESET}   $PASS1${PASS2:+ → $PASS2}"
[ -n "$FUNC" ] && echo -e "${BOLD}Function:${RESET} $FUNC"
echo ""

# --- Detect pass type (RTL vs GIMPLE) ---
detect_type() {
    local pass="$1"
    if echo "$pass" | grep -qE "^($RTL_PASSES)"; then
        echo "rtl"
    else
        echo "tree"
    fi
}

# --- Extract a function from a dump file ---
extract_func_from_dump() {
    local file="$1"
    local func="$2"
    # RTL/GIMPLE dumps use ";; Function <name>"
    sed -n "/^;; Function ${func} /,/^;; Function /{ /^;; Function ${func} /p; /^;; Function [^(]/!p; }" "$file"
}

# --- Filter address noise ---
filter_noise() {
    sed 's/0x[0-9a-f]*/0xADDR/g'
}

# --- Find dump file for a pass in OUTDIR ---
find_dump() {
    local pass="$1"
    ls -1 "${OUTDIR}/${SRCBASE}."*".${pass}" 2>/dev/null | head -1
}

# --- Compile helper ---
compile_with_dumps() {
    "$XGCC" -B./build-host/gcc $FLAGS $DUMP_COMMON "$@" -S "$SOURCE" -o /dev/null 2>/dev/null
}

# --- Compile with dumps ---
if [ -n "$PASS2" ]; then
    # Two passes: dump all, find both, diff
    type1=$(detect_type "$PASS1")
    type2=$(detect_type "$PASS2")

    DUMP_FLAGS=""
    if [ "$type1" = "rtl" ] || [ "$type2" = "rtl" ]; then
        DUMP_FLAGS="$DUMP_FLAGS -fdump-rtl-all"
    fi
    if [ "$type1" = "tree" ] || [ "$type2" = "tree" ]; then
        DUMP_FLAGS="$DUMP_FLAGS -fdump-tree-all"
    fi

    echo -e "${BOLD}Compiling with dump flags...${RESET}"
    compile_with_dumps $DUMP_FLAGS

    DUMP1=$(find_dump "$PASS1")
    DUMP2=$(find_dump "$PASS2")

    if [ -z "$DUMP1" ]; then
        echo "Error: no dump file found for pass '$PASS1'"
        echo "Available dumps:"
        ls -1 "${OUTDIR}/${SRCBASE}."* 2>/dev/null | sed "s|${OUTDIR}/||" | head -20
        exit 1
    fi
    if [ -z "$DUMP2" ]; then
        echo "Error: no dump file found for pass '$PASS2'"
        exit 1
    fi

    echo -e "  ${DIM}$(basename "$DUMP1")${RESET}"
    echo -e "  ${DIM}$(basename "$DUMP2")${RESET}"
    echo ""

    # Diff
    if [ -n "$FUNC" ]; then
        extract_func_from_dump "$DUMP1" "$FUNC" | filter_noise > "$OUTDIR/pass1_func.dump"
        extract_func_from_dump "$DUMP2" "$FUNC" | filter_noise > "$OUTDIR/pass2_func.dump"
        diff -u "$OUTDIR/pass1_func.dump" "$OUTDIR/pass2_func.dump" || true
    else
        diff -u <(filter_noise < "$DUMP1") <(filter_noise < "$DUMP2") || true
    fi

    # Clean up all-pass dumps, keep only the two we care about
    for f in "${OUTDIR}/${SRCBASE}."*; do
        case "$f" in
            "$DUMP1"|"$DUMP2") ;;  # keep
            *) rm -f "$f" ;;
        esac
    done

else
    # Single pass: dump just that pass
    type1=$(detect_type "$PASS1")
    DUMP_FLAG="-fdump-${type1}-${PASS1}"

    echo -e "${BOLD}Compiling with ${DUMP_FLAG}...${RESET}"
    compile_with_dumps "$DUMP_FLAG"

    DUMP1=$(find_dump "$PASS1")

    # If not found, try the other type
    if [ -z "$DUMP1" ]; then
        if [ "$type1" = "rtl" ]; then
            alt_type="tree"
        else
            alt_type="rtl"
        fi
        DUMP_FLAG="-fdump-${alt_type}-${PASS1}"
        echo -e "${DIM}Not found as ${type1}, trying ${alt_type}...${RESET}"
        compile_with_dumps "$DUMP_FLAG"
        DUMP1=$(find_dump "$PASS1")
    fi

    if [ -z "$DUMP1" ]; then
        echo "Error: no dump file found for pass '$PASS1'"
        exit 1
    fi

    echo -e "  ${DIM}$(basename "$DUMP1")${RESET}"
    echo ""

    # Show
    if [ -n "$FUNC" ]; then
        extract_func_from_dump "$DUMP1" "$FUNC"
    else
        cat "$DUMP1"
    fi
fi
