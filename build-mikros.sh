#!/bin/bash
set -o pipefail

# ============================================================================
# build-mikros.sh — Build 16 packages with both non-sjlj and sjlj compilers
# ============================================================================

# --- Configuration ---
DOWNLOAD_DIR="$HOME/Downloads/mikro"
GCC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="/tmp/build-mikros-$$"
SCRIPTS_DIR="$HOME/build-scripts"
SYSROOT=$(/opt/cross-mint/bin/m68k-atari-mintelf-gcc -print-sysroot)
TOOL_PREFIX=m68k-atari-mintelf
MAKEFLAGS="-j8"
export MAKEFLAGS

# Package versions
ZLIB_VERSION=1.3.1
GEMLIB_VERSION=master
SDL_VERSION=main
LIBXMP_VERSION=4.6.3
LIBXMP_LITE_VERSION=4.6.3
PHYSFS_VERSION=m68k-atari-mint
CFLIB_VERSION=master
LIBPNG_VERSION=1.6.53
SDL_IMAGE_VERSION=SDL-1.2
SDL_MIXER_VERSION=SDL-1.2
USOUND_VERSION=main
LIBCMINI_VERSION=master
ASAP_VERSION=7.0.0
MPG123_VERSION=1.33.4
UTHREAD_VERSION=main

# Download URLs
ZLIB_URL="https://www.zlib.net/zlib-${ZLIB_VERSION}.tar.gz"
GEMLIB_URL="https://github.com/freemint/gemlib/archive/refs/heads/${GEMLIB_VERSION}.tar.gz"
SDL_URL="https://github.com/libsdl-org/SDL-1.2/archive/refs/heads/${SDL_VERSION}.tar.gz"
LIBXMP_URL="https://github.com/libxmp/libxmp/releases/download/libxmp-${LIBXMP_VERSION}/libxmp-${LIBXMP_VERSION}.tar.gz"
LIBXMP_LITE_URL="https://github.com/libxmp/libxmp/releases/download/libxmp-${LIBXMP_VERSION}/libxmp-lite-${LIBXMP_LITE_VERSION}.tar.gz"
LDG_URL="https://svn.code.sf.net/p/ldg/code/trunk/ldg"
PHYSFS_URL="https://github.com/pmandin/physfs/archive/refs/heads/${PHYSFS_VERSION}.tar.gz"
CFLIB_URL="https://github.com/freemint/cflib/archive/refs/heads/${CFLIB_VERSION}.tar.gz"
LIBPNG_URL="https://download.sourceforge.net/libpng/libpng-${LIBPNG_VERSION}.tar.gz"
SDL_IMAGE_URL="https://github.com/libsdl-org/SDL_image/archive/refs/heads/${SDL_IMAGE_VERSION}.tar.gz"
USOUND_URL="https://raw.githubusercontent.com/mikrosk/usound/${USOUND_VERSION}/usound.h"
LIBCMINI_URL="https://github.com/freemint/libcmini/archive/refs/heads/${LIBCMINI_VERSION}.tar.gz"
SDL_MIXER_URL="https://github.com/mikrosk/SDL_mixer-1.2/archive/refs/heads/${SDL_MIXER_VERSION}.tar.gz"
ASAP_URL="https://sourceforge.net/projects/asap/files/asap/${ASAP_VERSION}/asap-${ASAP_VERSION}.tar.gz/download"
MPG123_URL="https://sourceforge.net/projects/mpg123/files/mpg123/${MPG123_VERSION}/mpg123-${MPG123_VERSION}.tar.bz2/download"
UTHREAD_URL="https://github.com/mikrosk/uthread/archive/refs/heads/${UTHREAD_VERSION}.tar.gz"

# Package list (in build order)
PKG_NAMES=(
    zlib gemlib LDG SDL-1.2 libxmp libxmp-lite physfs cflib
    libcmini ASAP mpg123 uthread libpng usound SDL_image SDL_mixer
)
PKG_COUNT=${#PKG_NAMES[@]}

# Result tracking arrays
declare -a TIME_BUILD1 TIME_BUILD2 RESULT_BUILD1 RESULT_BUILD2

# Parsed options
DO_DOWNLOAD=true
DO_BUILD1=true
DO_BUILD2=true

# --- Helper functions ---

die() { echo "ERROR: $*" >&2; exit 1; }

format_time() {
    local secs=$1
    printf "%dm %02ds" $((secs / 60)) $((secs % 60))
}

parse_args() {
    if [ $# -eq 0 ]; then return; fi
    # If any flag given, start with all false and enable only requested
    DO_DOWNLOAD=false; DO_BUILD1=false; DO_BUILD2=false
    for arg in "$@"; do
        case "$arg" in
            --download) DO_DOWNLOAD=true ;;
            --build1)   DO_DOWNLOAD=true; DO_BUILD1=true ;;
            --build2)   DO_DOWNLOAD=true; DO_BUILD2=true ;;
            *) die "Unknown argument: $arg (use --download, --build1, --build2)" ;;
        esac
    done
}

# Create wrapper directories with gcc wrapper + binutils symlinks
setup_wrappers() {
    local binutils_tools="ar ranlib ld as strip nm objcopy objdump readelf c++filt size strings"

    for dir_pair in "bin1:build/build-host" "bin2:build/build-host-sjlj"; do
        local bindir="${dir_pair%%:*}"
        local builddir="${dir_pair##*:}"
        local wrapdir="$WORK_DIR/$bindir"
        local gcc_build="$GCC_DIR/$builddir/gcc"

        mkdir -p "$wrapdir"

        # GCC wrapper script
        cat > "$wrapdir/${TOOL_PREFIX}-gcc" <<WRAPPER
#!/bin/bash
exec "$gcc_build/xgcc" -B"$gcc_build/" -fchecking=2 "\$@"
WRAPPER
        chmod +x "$wrapdir/${TOOL_PREFIX}-gcc"

        # G++ wrapper script
        cat > "$wrapdir/${TOOL_PREFIX}-g++" <<WRAPPER
#!/bin/bash
exec "$gcc_build/xg++" -B"$gcc_build/" -fchecking=2 "\$@"
WRAPPER
        chmod +x "$wrapdir/${TOOL_PREFIX}-g++"

        # Symlinks for binutils
        for tool in $binutils_tools; do
            ln -sf "/opt/cross-mint/bin/${TOOL_PREFIX}-${tool}" "$wrapdir/${TOOL_PREFIX}-${tool}"
        done
    done
}

download_file() {
    local url="$1" dest="$2" label="$3"
    if [ -s "$dest" ]; then
        printf "  [%2d/%d] %-28s cached\n" "$label" "$PKG_COUNT" "$(basename "$dest")"
    else
        printf "  [%2d/%d] %-28s downloading... " "$label" "$PKG_COUNT" "$(basename "$dest")"
        if curl -sL -o "$dest" "$url"; then
            echo "OK"
        else
            echo "FAILED"
            rm -f "$dest"
            return 1
        fi
    fi
}

download_all() {
    echo "=== Downloading sources to $DOWNLOAD_DIR/ ==="
    mkdir -p "$DOWNLOAD_DIR"

    local idx=0
    idx=$((idx+1)); download_file "$ZLIB_URL"         "$DOWNLOAD_DIR/zlib-${ZLIB_VERSION}.tar.gz"             "$idx"
    idx=$((idx+1)); download_file "$GEMLIB_URL"        "$DOWNLOAD_DIR/gemlib-${GEMLIB_VERSION}.tar.gz"         "$idx"
    idx=$((idx+1))  # LDG handled separately
    if [ -d "$DOWNLOAD_DIR/ldg-trunk" ]; then
        printf "  [%2d/%d] %-28s cached\n" "$idx" "$PKG_COUNT" "ldg-trunk/"
    else
        printf "  [%2d/%d] %-28s svn export... " "$idx" "$PKG_COUNT" "ldg-trunk/"
        if svn export -q "$LDG_URL" "$DOWNLOAD_DIR/ldg-trunk"; then
            echo "OK"
        else
            echo "FAILED"
            return 1
        fi
    fi
    idx=$((idx+1)); download_file "$SDL_URL"           "$DOWNLOAD_DIR/SDL-1.2-${SDL_VERSION}.tar.gz"           "$idx"
    idx=$((idx+1)); download_file "$LIBXMP_URL"        "$DOWNLOAD_DIR/libxmp-${LIBXMP_VERSION}.tar.gz"         "$idx"
    idx=$((idx+1)); download_file "$LIBXMP_LITE_URL"   "$DOWNLOAD_DIR/libxmp-lite-${LIBXMP_LITE_VERSION}.tar.gz" "$idx"
    idx=$((idx+1)); download_file "$PHYSFS_URL"        "$DOWNLOAD_DIR/physfs-${PHYSFS_VERSION}.tar.gz"         "$idx"
    idx=$((idx+1)); download_file "$CFLIB_URL"         "$DOWNLOAD_DIR/cflib-${CFLIB_VERSION}.tar.gz"           "$idx"
    idx=$((idx+1)); download_file "$LIBCMINI_URL"      "$DOWNLOAD_DIR/libcmini-${LIBCMINI_VERSION}.tar.gz"     "$idx"
    idx=$((idx+1)); download_file "$ASAP_URL"          "$DOWNLOAD_DIR/asap-${ASAP_VERSION}.tar.gz"             "$idx"
    idx=$((idx+1)); download_file "$MPG123_URL"        "$DOWNLOAD_DIR/mpg123-${MPG123_VERSION}.tar.bz2"        "$idx"
    idx=$((idx+1)); download_file "$UTHREAD_URL"       "$DOWNLOAD_DIR/uthread-${UTHREAD_VERSION}.tar.gz"       "$idx"
    idx=$((idx+1)); download_file "$LIBPNG_URL"        "$DOWNLOAD_DIR/libpng-${LIBPNG_VERSION}.tar.gz"         "$idx"
    idx=$((idx+1))  # usound is a single header
    if [ -s "$DOWNLOAD_DIR/usound.h" ]; then
        printf "  [%2d/%d] %-28s cached\n" "$idx" "$PKG_COUNT" "usound.h"
    else
        printf "  [%2d/%d] %-28s downloading... " "$idx" "$PKG_COUNT" "usound.h"
        if curl -sL -o "$DOWNLOAD_DIR/usound.h" "$USOUND_URL"; then
            echo "OK"
        else
            echo "FAILED"
            return 1
        fi
    fi
    idx=$((idx+1)); download_file "$SDL_IMAGE_URL"     "$DOWNLOAD_DIR/SDL_image-${SDL_IMAGE_VERSION}.tar.gz"   "$idx"
    idx=$((idx+1)); download_file "$SDL_MIXER_URL"     "$DOWNLOAD_DIR/SDL_mixer-1.2-${SDL_MIXER_VERSION}.tar.gz" "$idx"
    echo
}

# Extract all sources and apply patches
clean_build() {
    local builddir="$WORK_DIR/build"
    rm -rf "$builddir"
    mkdir -p "$builddir"
    cd "$builddir"

    # Extract tarballs
    tar xf "$DOWNLOAD_DIR/zlib-${ZLIB_VERSION}.tar.gz"
    tar xf "$DOWNLOAD_DIR/gemlib-${GEMLIB_VERSION}.tar.gz"
    cp -Rp "$DOWNLOAD_DIR/ldg-trunk" "$builddir/ldg-trunk"
    tar xf "$DOWNLOAD_DIR/SDL-1.2-${SDL_VERSION}.tar.gz"
    tar xf "$DOWNLOAD_DIR/libxmp-${LIBXMP_VERSION}.tar.gz"
    tar xf "$DOWNLOAD_DIR/libxmp-lite-${LIBXMP_LITE_VERSION}.tar.gz"
    tar xf "$DOWNLOAD_DIR/physfs-${PHYSFS_VERSION}.tar.gz"
    tar xf "$DOWNLOAD_DIR/cflib-${CFLIB_VERSION}.tar.gz"
    tar xf "$DOWNLOAD_DIR/libcmini-${LIBCMINI_VERSION}.tar.gz"
    tar xf "$DOWNLOAD_DIR/asap-${ASAP_VERSION}.tar.gz"
    tar xf "$DOWNLOAD_DIR/mpg123-${MPG123_VERSION}.tar.bz2"
    tar xf "$DOWNLOAD_DIR/uthread-${UTHREAD_VERSION}.tar.gz"
    tar xf "$DOWNLOAD_DIR/libpng-${LIBPNG_VERSION}.tar.gz"
    tar xf "$DOWNLOAD_DIR/SDL_image-${SDL_IMAGE_VERSION}.tar.gz"
    tar xf "$DOWNLOAD_DIR/SDL_mixer-1.2-${SDL_MIXER_VERSION}.tar.gz"

    # Apply patches
    (cd "libxmp-${LIBXMP_VERSION}" && patch -p1 < "$SCRIPTS_DIR/libxmp.patch")
    (cd "libxmp-lite-${LIBXMP_LITE_VERSION}" && patch -p1 < "$SCRIPTS_DIR/libxmp-lite.patch")

    # Copy cmake toolchain file
    cp "$SCRIPTS_DIR/freemint-m68k-atari-mintelf.cmake" "$builddir/"
}

build_package() {
    local idx=$1 name=$2 func=$3 compiler=$4
    printf "  [%2d/%d] %-16s " "$idx" "$PKG_COUNT" "$name"
    local logfile="$LOG_DIR/${name}.log"
    local start elapsed
    start=$(date +%s)
    if $func >> "$logfile" 2>&1; then
        elapsed=$(($(date +%s) - start))
        printf "PASS  %s\n" "$(format_time $elapsed)"
        eval "RESULT_${compiler}[$idx]=PASS"
    else
        elapsed=$(($(date +%s) - start))
        if grep -q "internal compiler error" "$logfile" 2>/dev/null; then
            printf "FAIL-ICE  %s\n" "$(format_time $elapsed)"
            eval "RESULT_${compiler}[$idx]=FAIL-ICE"
        else
            printf "FAIL  %s\n" "$(format_time $elapsed)"
            eval "RESULT_${compiler}[$idx]=FAIL"
        fi
    fi
    eval "TIME_${compiler}[$idx]=\$elapsed"
}

# --- Multilib helper: build autoconf package for 3 targets ---
# Usage: build_autoconf_3 <srcdir> <configure_args> [extra_env_per_target]
build_autoconf_3() {
    local srcdir="$1"; shift
    local configure_args="$*"
    cd "$WORK_DIR/build/$srcdir"

    # m68000
    CFLAGS='-O2 -fomit-frame-pointer -m68000' \
        ./configure --host=${TOOL_PREFIX} \
        --prefix=${SYSROOT}/usr --libdir=${SYSROOT}/usr/lib --bindir=${SYSROOT}/usr/bin \
        $configure_args
    make
    make distclean

    # m68020-60
    CFLAGS='-O2 -fomit-frame-pointer -m68020-60' \
        ./configure --host=${TOOL_PREFIX} \
        --prefix=${SYSROOT}/usr --libdir=${SYSROOT}/usr/lib/m68020-60 --bindir=${SYSROOT}/usr/bin/m68020-60 \
        $configure_args
    make
    make distclean

    # ColdFire m5475
    CFLAGS='-O2 -fomit-frame-pointer -mcpu=5475' \
        ./configure --host=${TOOL_PREFIX} \
        --prefix=${SYSROOT}/usr --libdir=${SYSROOT}/usr/lib/m5475 --bindir=${SYSROOT}/usr/bin/m5475 \
        $configure_args
    make
}

# --- 16 package build functions ---

build_zlib() {
    cd "$WORK_DIR/build/zlib-${ZLIB_VERSION}"

    # m68000
    CFLAGS='-O2 -fomit-frame-pointer -m68000' \
        CC=${TOOL_PREFIX}-gcc AR=${TOOL_PREFIX}-ar RANLIB=${TOOL_PREFIX}-ranlib \
        ./configure --prefix=${SYSROOT}/usr --libdir=${SYSROOT}/usr/lib
    make AR="${TOOL_PREFIX}-ar" ARFLAGS=rcs RANLIB="${TOOL_PREFIX}-ranlib"
    make distclean

    # m68020-60
    CFLAGS='-O2 -fomit-frame-pointer -m68020-60' \
        CC=${TOOL_PREFIX}-gcc AR=${TOOL_PREFIX}-ar RANLIB=${TOOL_PREFIX}-ranlib \
        ./configure --prefix=${SYSROOT}/usr --libdir=${SYSROOT}/usr/lib/m68020-60
    make AR="${TOOL_PREFIX}-ar" ARFLAGS=rcs RANLIB="${TOOL_PREFIX}-ranlib"
    make distclean

    # ColdFire m5475
    CFLAGS='-O2 -fomit-frame-pointer -mcpu=5475' \
        CC=${TOOL_PREFIX}-gcc AR=${TOOL_PREFIX}-ar RANLIB=${TOOL_PREFIX}-ranlib \
        ./configure --prefix=${SYSROOT}/usr --libdir=${SYSROOT}/usr/lib/m5475
    make AR="${TOOL_PREFIX}-ar" ARFLAGS=rcs RANLIB="${TOOL_PREFIX}-ranlib"
}

build_gemlib() {
    cd "$WORK_DIR/build/gemlib-${GEMLIB_VERSION}"
    make CROSS_TOOL=${TOOL_PREFIX} DESTDIR=${SYSROOT} PREFIX=/usr V=1
}

build_ldg() {
    cd "$WORK_DIR/build/ldg-trunk/src/devel"
    make -f gcc.mak CC=${TOOL_PREFIX}-gcc AR=${TOOL_PREFIX}-ar
    make -f gccm68020-60.mak CC=${TOOL_PREFIX}-gcc AR=${TOOL_PREFIX}-ar
    make -f gccm5475.mak CC=${TOOL_PREFIX}-gcc AR=${TOOL_PREFIX}-ar
}

build_sdl() {
    build_autoconf_3 "SDL-1.2-${SDL_VERSION}" "--disable-video-opengl --disable-threads"
}

build_libxmp() {
    build_autoconf_3 "libxmp-${LIBXMP_VERSION}"
}

build_libxmp_lite() {
    build_autoconf_3 "libxmp-lite-${LIBXMP_LITE_VERSION}" "--disable-it"
}

build_physfs() {
    cd "$WORK_DIR/build/physfs-${PHYSFS_VERSION}"

    # m68000
    mkdir -p build && cd build
    cmake -DCMAKE_TOOLCHAIN_FILE="$WORK_DIR/build/freemint-m68k-atari-mintelf.cmake" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS="-fomit-frame-pointer" \
        -DPHYSFS_BUILD_SHARED=0 \
        -DCMAKE_INSTALL_PREFIX=${SYSROOT}/usr -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_INSTALL_BINDIR=bin ..
    make VERBOSE=1
    cd ..

    # m68020-60
    mkdir -p build020 && cd build020
    cmake -DCMAKE_TOOLCHAIN_FILE="$WORK_DIR/build/freemint-m68k-atari-mintelf.cmake" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS="-fomit-frame-pointer -m68020-60" \
        -DPHYSFS_BUILD_SHARED=0 \
        -DCMAKE_INSTALL_PREFIX=${SYSROOT}/usr -DCMAKE_INSTALL_LIBDIR=lib/m68020-60 -DCMAKE_INSTALL_BINDIR=bin/m68020-60 ..
    make VERBOSE=1
    cd ..

    # ColdFire m5475
    mkdir -p buildcf && cd buildcf
    cmake -DCMAKE_TOOLCHAIN_FILE="$WORK_DIR/build/freemint-m68k-atari-mintelf.cmake" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS="-fomit-frame-pointer -mcpu=5475" \
        -DPHYSFS_BUILD_SHARED=0 \
        -DCMAKE_INSTALL_PREFIX=${SYSROOT}/usr -DCMAKE_INSTALL_LIBDIR=lib/m5475 -DCMAKE_INSTALL_BINDIR=bin/m5475 ..
    make VERBOSE=1
    cd ..
}

build_cflib() {
    cd "$WORK_DIR/build/cflib-${CFLIB_VERSION}"
    make CROSS_TOOL=${TOOL_PREFIX} DESTDIR=${SYSROOT} PREFIX=/usr V=1
}

build_libcmini() {
    cd "$WORK_DIR/build/libcmini-${LIBCMINI_VERSION}"
    make PREFIX=${SYSROOT}/opt/libcmini BUILD_FAST=N BUILD_SOFT_FLOAT=N COMPILE_ELF=Y VERBOSE=yes
}

build_asap() {
    cd "$WORK_DIR/build/asap-${ASAP_VERSION}"

    # m68000
    make CC=${TOOL_PREFIX}-gcc AR=${TOOL_PREFIX}-ar \
        CFLAGS='-O2 -fomit-frame-pointer -m68000' \
        prefix=${SYSROOT}/usr libdir=${SYSROOT}/usr/lib bindir=${SYSROOT}/usr/bin
    rm -f asap.o libasap.a asapconv

    # m68020-60
    make CC=${TOOL_PREFIX}-gcc AR=${TOOL_PREFIX}-ar \
        CFLAGS='-O2 -fomit-frame-pointer -m68020-60' \
        prefix=${SYSROOT}/usr libdir=${SYSROOT}/usr/lib/m68020-60 bindir=${SYSROOT}/usr/bin/m68020-60
    rm -f asap.o libasap.a asapconv

    # ColdFire m5475
    make CC=${TOOL_PREFIX}-gcc AR=${TOOL_PREFIX}-ar \
        CFLAGS='-O2 -fomit-frame-pointer -mcpu=5475' \
        prefix=${SYSROOT}/usr libdir=${SYSROOT}/usr/lib/m5475 bindir=${SYSROOT}/usr/bin/m5475
}

build_mpg123() {
    cd "$WORK_DIR/build/mpg123-${MPG123_VERSION}"
    local common_args="--disable-components --enable-libmpg123 --enable-network=no --disable-gapless --disable-feeder --disable-new-huffman --disable-messages --disable-equalizer --disable-32bit --disable-real --disable-feature_report --disable-largefile --with-seektable=0"

    # m68000 (no FPU)
    CFLAGS='-O2 -fomit-frame-pointer -m68000' \
        ./configure --host=${TOOL_PREFIX} \
        --prefix=${SYSROOT}/usr --libdir=${SYSROOT}/usr/lib \
        --with-cpu=generic_nofpu $common_args
    make
    make distclean

    # m68020-60 (FPU)
    CFLAGS='-O2 -fomit-frame-pointer -m68020-60' \
        ./configure --host=${TOOL_PREFIX} \
        --prefix=${SYSROOT}/usr --libdir=${SYSROOT}/usr/lib/m68020-60 \
        --with-cpu=generic_fpu $common_args
    make
    make distclean

    # ColdFire m5475 (FPU)
    CFLAGS='-O2 -fomit-frame-pointer -mcpu=5475' \
        ./configure --host=${TOOL_PREFIX} \
        --prefix=${SYSROOT}/usr --libdir=${SYSROOT}/usr/lib/m5475 \
        --with-cpu=generic_fpu $common_args
    make
}

build_uthread() {
    cd "$WORK_DIR/build/uthread-${UTHREAD_VERSION}"
    # 'make release' calls install internally; just build the library
    make CPU_FLG=-m68020-60
}

build_libpng() {
    build_autoconf_3 "libpng-${LIBPNG_VERSION}"
}

build_usound() {
    # Header-only library, nothing to compile
    test -f "$DOWNLOAD_DIR/usound.h"
}

build_sdl_image() {
    cd "$WORK_DIR/build/SDL_image-${SDL_IMAGE_VERSION}"

    # m68000
    PKG_CONFIG_LIBDIR=${SYSROOT}/usr/lib/pkgconfig \
        CFLAGS='-O2 -fomit-frame-pointer -m68000' \
        ./configure --host=${TOOL_PREFIX} \
        --prefix=${SYSROOT}/usr --libdir=${SYSROOT}/usr/lib --bindir=${SYSROOT}/usr/bin
    make
    make distclean

    # m68020-60
    PKG_CONFIG_LIBDIR=${SYSROOT}/usr/lib/m68020-60/pkgconfig \
        CFLAGS='-O2 -fomit-frame-pointer -m68020-60' \
        ./configure --host=${TOOL_PREFIX} \
        --prefix=${SYSROOT}/usr --libdir=${SYSROOT}/usr/lib/m68020-60 --bindir=${SYSROOT}/usr/bin/m68020-60
    make
    make distclean

    # ColdFire m5475
    PKG_CONFIG_LIBDIR=${SYSROOT}/usr/lib/m5475/pkgconfig \
        CFLAGS='-O2 -fomit-frame-pointer -mcpu=5475' \
        ./configure --host=${TOOL_PREFIX} \
        --prefix=${SYSROOT}/usr --libdir=${SYSROOT}/usr/lib/m5475 --bindir=${SYSROOT}/usr/bin/m5475
    make
}

build_sdl_mixer() {
    cd "$WORK_DIR/build/SDL_mixer-1.2-${SDL_MIXER_VERSION}"
    local disable_args="--disable-music-mod --disable-music-timidity-midi --disable-music-fluidsynth-midi --disable-music-ogg --disable-music-flac --disable-music-mp3"

    # m68000
    PKG_CONFIG_LIBDIR=${SYSROOT}/usr/lib/pkgconfig \
        CFLAGS='-O2 -fomit-frame-pointer -m68000' LDFLAGS='-m68000' \
        ./configure --host=${TOOL_PREFIX} \
        --prefix=${SYSROOT}/usr --libdir=${SYSROOT}/usr/lib --bindir=${SYSROOT}/usr/bin \
        $disable_args
    make
    make distclean

    # m68020-60
    PKG_CONFIG_LIBDIR=${SYSROOT}/usr/lib/m68020-60/pkgconfig \
        CFLAGS='-O2 -fomit-frame-pointer -m68020-60' LDFLAGS='-m68020-60' \
        ./configure --host=${TOOL_PREFIX} \
        --prefix=${SYSROOT}/usr --libdir=${SYSROOT}/usr/lib/m68020-60 --bindir=${SYSROOT}/usr/bin/m68020-60 \
        $disable_args
    make
    make distclean

    # ColdFire m5475
    PKG_CONFIG_LIBDIR=${SYSROOT}/usr/lib/m5475/pkgconfig \
        CFLAGS='-O2 -fomit-frame-pointer -mcpu=5475' LDFLAGS='-mcpu=5475' \
        ./configure --host=${TOOL_PREFIX} \
        --prefix=${SYSROOT}/usr --libdir=${SYSROOT}/usr/lib/m5475 --bindir=${SYSROOT}/usr/bin/m5475 \
        $disable_args
    make
}

# --- Build all packages for one compiler ---

build_all() {
    local compiler=$1
    local funcs=(
        build_zlib build_gemlib build_ldg build_sdl
        build_libxmp build_libxmp_lite build_physfs build_cflib
        build_libcmini build_asap build_mpg123 build_uthread
        build_libpng build_usound build_sdl_image build_sdl_mixer
    )

    for i in $(seq 0 $((PKG_COUNT - 1))); do
        build_package $((i + 1)) "${PKG_NAMES[$i]}" "${funcs[$i]}" "$compiler"
    done
}

# --- Print results table ---

print_results() {
    local has_build1=$1 has_build2=$2

    echo "==================================================================="
    echo "                        Build Results"
    echo "==================================================================="

    if $has_build1 && $has_build2; then
        printf " %-16s %-10s %10s   %-10s %10s\n" "Package" "non-sjlj" "(build)" "sjlj" "(sjlj)"
        echo "-------------------------------------------------------------------"
        local pass1=0 pass2=0 total1=0 total2=0
        for i in $(seq 1 $PKG_COUNT); do
            local r1="${RESULT_BUILD1[$i]:-N/A}"
            local r2="${RESULT_BUILD2[$i]:-N/A}"
            local t1="${TIME_BUILD1[$i]:-0}"
            local t2="${TIME_BUILD2[$i]:-0}"
            printf " %-16s %-10s %10s   %-10s %10s\n" \
                "${PKG_NAMES[$((i-1))]}" "$r1" "$(format_time $t1)" "$r2" "$(format_time $t2)"
            [[ "$r1" == "PASS" ]] && pass1=$((pass1 + 1))
            [[ "$r2" == "PASS" ]] && pass2=$((pass2 + 1))
            total1=$((total1 + t1))
            total2=$((total2 + t2))
        done
        echo "-------------------------------------------------------------------"
        printf " %-16s %-10s %10s   %-10s %10s\n" \
            "TOTAL" "${pass1}/${PKG_COUNT}" "$(format_time $total1)" "${pass2}/${PKG_COUNT}" "$(format_time $total2)"
    else
        local label compiler_var
        if $has_build1; then label="non-sjlj (build)"; compiler_var="BUILD1";
        else label="sjlj"; compiler_var="BUILD2"; fi
        printf " %-16s %-10s %10s\n" "Package" "$label" ""
        echo "-------------------------------------------------------------------"
        local pass=0 total=0
        for i in $(seq 1 $PKG_COUNT); do
            local r; eval "r=\${RESULT_${compiler_var}[$i]:-N/A}"
            local t; eval "t=\${TIME_${compiler_var}[$i]:-0}"
            printf " %-16s %-10s %10s\n" "${PKG_NAMES[$((i-1))]}" "$r" "$(format_time $t)"
            [[ "$r" == "PASS" ]] && pass=$((pass + 1))
            total=$((total + t))
        done
        echo "-------------------------------------------------------------------"
        printf " %-16s %-10s %10s\n" "TOTAL" "${pass}/${PKG_COUNT}" "$(format_time $total)"
    fi
    echo "==================================================================="
}

# --- Main ---

parse_args "$@"

echo "GCC source: $GCC_DIR"
echo "Sysroot:    $SYSROOT"
echo "Work dir:   $WORK_DIR"
echo

mkdir -p "$WORK_DIR"

if $DO_BUILD1 || $DO_BUILD2; then
    setup_wrappers
fi

if $DO_DOWNLOAD; then
    download_all
fi

if $DO_BUILD1; then
    echo "=== Building with non-sjlj compiler (build) ==="
    export PATH="$WORK_DIR/bin1:$PATH"
    LOG_DIR="$WORK_DIR/logs-non-sjlj"
    mkdir -p "$LOG_DIR"
    clean_build
    build_all BUILD1
    # Restore PATH (remove our bin1 prefix)
    export PATH="${PATH#$WORK_DIR/bin1:}"
    echo
fi

if $DO_BUILD2; then
    echo "=== Building with sjlj compiler ==="
    export PATH="$WORK_DIR/bin2:$PATH"
    LOG_DIR="$WORK_DIR/logs-sjlj"
    mkdir -p "$LOG_DIR"
    clean_build
    build_all BUILD2
    export PATH="${PATH#$WORK_DIR/bin2:}"
    echo
fi

if $DO_BUILD1 || $DO_BUILD2; then
    echo
    print_results "$DO_BUILD1" "$DO_BUILD2"
    echo
    echo "Log files: $WORK_DIR/logs-*/"
fi
