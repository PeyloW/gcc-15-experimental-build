#!/bin/bash
set -euo pipefail

# build-gcc.sh — Build and install m68k-atari-mintelf GCC
# Run from: ~/m68k-atari-mint-gcc/build/

SRCDIR="$HOME/m68k-atari-mint-gcc"
PREFIX="/opt/cross-mint"
CROSSTOOLS="$HOME/crosstools"
JOBS=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
SJLJ=false
BUILDDIR="build-host"
BACKUP_PREFIX="build-gcc-backup-"

# Parse -sjlj flag before the command
if [[ "${1:-}" == "-sjlj" ]]; then
    SJLJ=true
    BUILDDIR="build-host-sjlj"
    BACKUP_PREFIX="build-gcc-sjlj-backup-"
    shift
fi

# Ensure we're in the build directory
check_build_dir() {
    if [[ "$(pwd)" != "$SRCDIR/build" ]]; then
        echo "Error: Run this script from $SRCDIR/build/"
        exit 1
    fi
}

do_configure() {
    check_build_dir

    if $SJLJ; then
        echo "=== Configuring (sjlj exceptions) ==="
    else
        echo "=== Configuring ==="
    fi

    # Flags that differ between default and sjlj builds
    if $SJLJ; then
        local lang_flags="--enable-languages=c"
        local ssp_flags="--disable-libssp"
        local exc_flags="--enable-sjlj-exceptions"
        local newlib_flags="--with-newlib --without-headers"
        local extra_flags="--enable-version-specific-runtime-libs"
    else
        local lang_flags="--enable-languages=c,c++,lto"
        local ssp_flags="--enable-lto --enable-ssp --enable-libssp"
        local exc_flags="--disable-sjlj-exceptions"
        local newlib_flags="--without-newlib"
        local extra_flags=""
    fi

    mkdir -p "$BUILDDIR"
    cd "$BUILDDIR"
    ../../configure \
        --target=m68k-atari-mintelf \
        --build=x86_64-apple-darwin17.0.0 \
        --prefix="$PREFIX" \
        --libdir="$PREFIX/lib" \
        --bindir="$PREFIX/bin" \
        --libexecdir="$PREFIX/lib" \
        \
        CFLAGS_FOR_BUILD='-pipe -O2 -arch x86_64' \
        CFLAGS='-pipe -O2 -arch x86_64' \
        CXXFLAGS_FOR_BUILD='-pipe -O2 -stdlib=libc++ -arch x86_64' \
        CXXFLAGS='-pipe -O2 -stdlib=libc++ -arch x86_64' \
        BOOT_CFLAGS='-pipe -O2 -arch x86_64' \
        LDFLAGS_FOR_BUILD='-Wl,-headerpad_max_install_names -arch x86_64' \
        LDFLAGS='-Wl,-headerpad_max_install_names -arch x86_64' \
        \
        CFLAGS_FOR_TARGET='-O2 -fomit-frame-pointer' \
        CXXFLAGS_FOR_TARGET='-O2 -fomit-frame-pointer' \
        GDCFLAGS='-O2 -fomit-frame-pointer -D__LIBC_CUSTOM_BINDINGS_H__' \
        \
        GNATMAKE_FOR_HOST=gnatmake \
        GNATBIND_FOR_HOST=gnatbind \
        GNATLINK_FOR_HOST=gnatlink \
        \
        --with-pkgversion='MiNT ELF 20250810' \
        --with-gcc-major-version-only \
        --with-gcc \
        --with-gnu-as \
        --with-gnu-ld \
        \
        --with-gxx-include-dir="$PREFIX/m68k-atari-mintelf/sys-root/usr/include/c++/15" \
        --with-libstdcxx-zoneinfo=/usr/share/zoneinfo \
        --with-sysroot="$PREFIX/m68k-atari-mintelf/sys-root" \
        \
        --with-system-zlib \
        --without-static-standard-libraries \
        --with-zstd="$CROSSTOOLS" \
        --with-libiconv-prefix="$PREFIX" \
        --with-libintl-prefix="$PREFIX" \
        --with-gmp="$CROSSTOOLS" \
        --with-mpfr="$CROSSTOOLS" \
        --with-mpc="$CROSSTOOLS" \
        \
        $lang_flags \
        $ssp_flags \
        \
        --disable-libcc1 \
        --disable-werror \
        --disable-libgomp \
        --disable-libstdcxx-pch \
        --disable-threads \
        --disable-win32-registry \
        --disable-plugin \
        --disable-decimal-float \
        --disable-nls \
        $exc_flags \
        \
        --without-stage1-ldflags \
        $newlib_flags \
        --enable-checking=yes \
        $extra_flags
        # --disable-libstdcxx
    cd ..
    echo "=== Configure complete ==="
}

do_build() {
    check_build_dir
    echo "=== Building with $JOBS jobs ==="
    make -C "$BUILDDIR" -j"$JOBS"
    echo "=== Build complete ==="
}

do_install() {
    check_build_dir
    echo "=== Installing to $PREFIX ==="
    sudo make -C "$BUILDDIR" install
    echo "=== Install complete ==="
    echo "Compiler installed as: m68k-atari-mintelf-gcc-opt"
    echo "Add to PATH: export PATH=\"$PREFIX/bin:\$PATH\""
}

do_clean() {
    check_build_dir
    echo "=== Cleaning build directory ==="

    if [ ! -d "$BUILDDIR" ]; then
        echo "Nothing to clean ($BUILDDIR/ does not exist)"
        return
    fi

    # Create timestamped backup archive
    local timestamp=$(date +%Y-%m-%dT%H%M%S)
    local backup_tgz="/tmp/${BACKUP_PREFIX}${timestamp}.tgz"
    echo "Creating archive ${backup_tgz}..."
    tar czf "${backup_tgz}" "$BUILDDIR" 2>/dev/null || true

    rm -rf "$BUILDDIR"
    echo "=== Clean complete ==="
    echo "Timestamped archive: ${backup_tgz}"
}

usage() {
    echo "Usage: $0 [-sjlj] <command>"
    echo ""
    echo "Options:"
    echo "  -sjlj      — Build with sjlj exceptions (builds to build-host-sjlj/)"
    echo ""
    echo "Commands:"
    echo "  configure  — Run configure"
    echo "  build      — Build GCC"
    echo "  install    — Install to $PREFIX (requires sudo)"
    echo "  clean      — Remove all files from build directory"
    echo ""
    echo "Run from: $SRCDIR/build/"
    exit 1
}

case "${1:-}" in
    configure) do_configure ;;
    build)     do_build ;;
    install)   do_install ;;
    clean)     do_clean ;;
    *)         usage ;;
esac
