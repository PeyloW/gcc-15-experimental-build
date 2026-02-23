#!/bin/bash
set -euo pipefail

# build-coremark.sh — Build CoreMark benchmark for Atari MiNT
# Produces 12 variants: {Os,O2} x {fastcall,no} x {default,experimental,experimental-reload}
# Experimental-reload variants use -mno-lra (legacy reload) and are suffixed with 'r'.
# Run from: ~/m68k-atari-mint-gcc/build/

SRCDIR="$HOME/m68k-atari-mint-gcc"
REPO="git@github.com:czietz/coremark.git"
JOBS=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)

WORKDIR="tmp/coremark"
OUTDIR="build-cm"

CC_DEFAULT="m68k-atari-mintelf-gcc"
CC_EXPERIMENTAL="$SRCDIR/build/build-host/gcc/xgcc -B$SRCDIR/build/build-host/gcc/"

do_prepare() {
    mkdir -p tmp

    if [ ! -d "$WORKDIR" ]; then
        echo "=== Cloning CoreMark ==="
        git clone "$REPO" "$WORKDIR"
    fi

    echo "=== Resetting working tree ==="
    git -C "$WORKDIR" checkout .

    echo "=== Applying patch ==="
    git -C "$WORKDIR" apply ../../coremark.patch

    echo "=== Prepare complete ==="
}

do_build() {
    # Verify compilers exist
    if ! command -v "$CC_DEFAULT" &>/dev/null; then
        echo "Error: $CC_DEFAULT not found on PATH"
        exit 1
    fi
    if [ ! -x "$SRCDIR/build/build-host/gcc/xgcc" ]; then
        echo "Error: experimental compiler not found at $SRCDIR/build/build-host/gcc/xgcc"
        exit 1
    fi

    echo "=== Building CoreMark (12 variants) ==="

    build_one() {
        local name="$1" opt="$2" fastcall="$3" cc="$4" extra="$5"
        local logname="${name%.tos}"
        local fastcall_flag=""
        if $fastcall; then
            fastcall_flag="-mfastcall"
        fi
        echo "  Building $name ..."
        make -j"$JOBS" -C "$WORKDIR" PORT_DIR=atari \
            CC="$cc" \
            PORT_CFLAGS="$opt -mcpu=68000 -fomit-frame-pointer $extra" \
            XCFLAGS="$fastcall_flag -DLOG_NAME=$logname" \
            OUTNAME="$name"
    }

    #           name            opt    fastcall  compiler              extra
    build_one  cm_os.tos       -Os    false     "$CC_DEFAULT"         ""
    build_one  cm_ose.tos      -Os    false     "$CC_EXPERIMENTAL"    ""
    build_one  cm_oser.tos     -Os    false     "$CC_EXPERIMENTAL"    "-mno-lra"
    build_one  cm_osf.tos      -Os    true      "$CC_DEFAULT"         ""
    build_one  cm_osfe.tos     -Os    true      "$CC_EXPERIMENTAL"    ""
    build_one  cm_osfer.tos    -Os    true      "$CC_EXPERIMENTAL"    "-mno-lra"
    build_one  cm_o2.tos       -O2    false     "$CC_DEFAULT"         ""
    build_one  cm_o2e.tos      -O2    false     "$CC_EXPERIMENTAL"    ""
    build_one  cm_o2er.tos     -O2    false     "$CC_EXPERIMENTAL"    "-mno-lra"
    build_one  cm_o2f.tos      -O2    true      "$CC_DEFAULT"         ""
    build_one  cm_o2fe.tos     -O2    true      "$CC_EXPERIMENTAL"    ""
    build_one  cm_o2fer.tos    -O2    true      "$CC_EXPERIMENTAL"    "-mno-lra"

    echo "=== Copying .tos files to $OUTDIR/ ==="
    mkdir -p "$OUTDIR"
    cp "$WORKDIR"/cm_*.tos "$OUTDIR"/

    echo "=== Build complete ==="
    echo ""
    printf "%-16s %8s\n" "Variant" "Text"
    printf "%-16s %8s\n" "-------" "----"
    for f in "$OUTDIR"/cm_*.tos; do
        local text
        text=$(m68k-atari-mintelf-size "$f" | awk 'NR==2{print $1}')
        printf "%-16s %8d\n" "$(basename "$f")" "$text"
    done
    echo ""
}

do_compare() {
    local logs=("$OUTDIR"/cm_*.log)
    if [ ! -f "${logs[0]}" ]; then
        echo "No log files found in $OUTDIR/cm_*.log"
        exit 1
    fi

    # Decode variant name into description columns
    decode_name() {
        local base="$1"            # e.g. cm_o2fe
        local rest="${base#cm_}"   # e.g. o2fe

        # Optimization level
        if [[ "$rest" == os* ]]; then
            local opt="-Os"
            rest="${rest#os}"
        else
            local opt="-O2"
            rest="${rest#o2}"
        fi

        # Fastcall
        if [[ "$rest" == f* ]]; then
            local fc="yes"
            rest="${rest#f}"
        else
            local fc="no"
        fi

        # Compiler and reload
        if [[ "$rest" == er* ]]; then
            local cc="exp-reload"
        elif [[ "$rest" == e* ]]; then
            local cc="exp"
        else
            local cc="def"
        fi

        echo "$opt $fc $cc"
    }

    # Collect data: iter/sec filename opt fastcall compiler
    local tmpfile
    tmpfile=$(mktemp)
    for f in "${logs[@]}"; do
        local ips
        ips=$(tr -d '\r' < "$f" | awk '/^Iterations\/Sec/ { print $NF }')
        if [ -z "$ips" ]; then
            continue
        fi
        local base
        base=$(basename "$f" .log)
        local desc
        desc=$(decode_name "$base")
        echo "$ips $base $desc" >> "$tmpfile"
    done

    if [ ! -s "$tmpfile" ]; then
        echo "No Iterations/Sec data found in log files"
        rm -f "$tmpfile"
        exit 1
    fi

    # Sort by iterations/sec descending, print table
    echo ""
    echo "Benchmark Results"
    echo "================="
    echo ""
    printf "%-14s %8s  %-4s %-9s %s\n" "Variant" "Iter/s" "Opt" "Fastcall" "Compiler"
    printf "%-14s %8s  %-4s %-9s %s\n" "-------" "------" "---" "--------" "--------"
    sort -t' ' -k1 -rn "$tmpfile" | while read -r ips name opt fc cc; do
        printf "%-14s %8s  %-4s %-9s %s\n" "$name" "$ips" "$opt" "$fc" "$cc"
    done
    echo ""

    rm -f "$tmpfile"

    # Text section size table, sorted smallest to largest
    local bins=("$OUTDIR"/cm_*.tos)
    if [ ! -f "${bins[0]}" ]; then
        return
    fi

    local tmpfile2
    tmpfile2=$(mktemp)
    for f in "${bins[@]}"; do
        local base
        base=$(basename "$f" .tos)
        local text
        text=$(m68k-atari-mintelf-size "$f" | awk 'NR==2{print $1}')
        local desc
        desc=$(decode_name "$base")
        echo "$text $base $desc" >> "$tmpfile2"
    done

    echo "Text Section Sizes"
    echo "=================="
    echo ""
    printf "%-14s %8s  %-4s %-9s %s\n" "Variant" "Text" "Opt" "Fastcall" "Compiler"
    printf "%-14s %8s  %-4s %-9s %s\n" "-------" "----" "---" "--------" "--------"
    sort -t' ' -k1 -n "$tmpfile2" | while read -r text name opt fc cc; do
        printf "%-14s %8d  %-4s %-9s %s\n" "$name" "$text" "$opt" "$fc" "$cc"
    done
    echo ""

    rm -f "$tmpfile2"
}

do_clean() {
    echo "=== Cleaning CoreMark binaries ==="
    rm -f "$WORKDIR"/cm_*.tos "$OUTDIR"/cm_*.tos
    echo "=== Clean complete ==="
}

usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  prepare  — Clone repo and apply patch"
    echo "  build    — Build 12 CoreMark variants (default, experimental LRA, experimental reload)"
    echo "  compare  — Compare benchmark results and text sizes from $OUTDIR/"
    echo "  clean    — Remove generated .tos files"
    exit 1
}

case "${1:-}" in
    prepare) do_prepare ;;
    build)   do_build ;;
    compare) do_compare ;;
    clean)   do_clean ;;
    *)       usage ;;
esac
