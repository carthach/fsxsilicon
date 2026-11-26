#!/bin/bash
# Build everything FSX needs into $RUNTIME, from pinned upstream sources plus the patches in this repository.
#
#   scripts/build.sh [step...]     steps: deps x87sidecar wine llvm dxmt addons gamemode   (default: all, in order)
#
# Each step leaves a stamp in .work/stamps and is skipped next time; delete the stamp (or `./fsxsilicon clean`) to redo.
# Rough times: deps ~5 min, wine ~25 min, llvm ~20 min, dxmt ~5 min, the rest seconds.
set -eo pipefail
. "$(dirname "$0")/lib.sh"

[ "$(uname -m)" = arm64 ] || die "this port targets Apple Silicon Macs"
arch -x86_64 /usr/bin/true 2>/dev/null || die "Rosetta 2 is needed: softwareupdate --install-rosetta --agree-to-license"

BISON_FLEX="$(brew_prefix bison)/bin:$(brew_prefix flex)/bin"
MINGW="$(brew_prefix mingw-w64)/bin"
X86_CC="/usr/bin/clang -arch x86_64"
X86_CFLAGS="-O2 -mmacosx-version-min=$MACOS_MIN"

# ---- x86_64 FreeType, GMP, Nettle, GnuTLS (Wine runs as x86_64; without GnuTLS Steam can't reach its servers) ----
build_deps() {
    step deps && return
    local host="--host=x86_64-apple-darwin --build=aarch64-apple-darwin --prefix=$DEPS"
    export CC="$X86_CC" CFLAGS="$X86_CFLAGS" CPPFLAGS="-I$DEPS/include" LDFLAGS="-L$DEPS/lib"
    export PKG_CONFIG_PATH="$DEPS/lib/pkgconfig"

    unpack "$FREETYPE_URL" "$FREETYPE_SHA256" freetype-2.13.3
    (cd "$SRC/freetype-2.13.3" && ./configure $host --enable-static=no \
        --without-harfbuzz --without-png --without-brotli --without-bzip2 && make -j"$JOBS" && make install)

    unpack "$GMP_URL" "$GMP_SHA256" gmp-6.3.0
    (cd "$SRC/gmp-6.3.0" && ./configure $host --enable-shared --disable-static --disable-assembly \
        && make -j"$JOBS" && make install)

    unpack "$NETTLE_URL" "$NETTLE_SHA256" nettle-3.10.1
    (cd "$SRC/nettle-3.10.1" && ./configure $host --enable-shared --disable-static --disable-documentation \
        --disable-assembler && make -j"$JOBS" && make install)

    unpack "$GNUTLS_URL" "$GNUTLS_SHA256" gnutls-3.8.9
    (cd "$SRC/gnutls-3.8.9" && ./configure $host --enable-shared --disable-static \
        --with-included-libtasn1 --with-included-unistring --without-p11-kit --without-idn --without-brotli \
        --without-zstd --without-zlib --without-tpm --without-tpm2 --without-leancrypto --disable-doc \
        --disable-manpages --disable-tests --disable-tools --disable-cxx --disable-guile --disable-nls \
        && make -j"$JOBS" && make install)

    unset CC CFLAGS CPPFLAGS LDFLAGS PKG_CONFIG_PATH
    # only the dylibs are needed at run time
    rm -rf "$DEPS/share" "$DEPS/bin"
    done_step deps
}

# ---- Wine 11 with our patches: native arm64 tools, then an x86_64 cross build (WoW64: i386 + x86_64 PE) ----------
# Apple's clang can't run under Rosetta, so Wine is cross-built from arm64 (--host=x86_64-apple-darwin).
build_wine() {
    step wine && return
    [ -f "$DEPS/lib/libgnutls.dylib" ] || die "run the deps step first"
    unpack "$WINE_URL" "$WINE_SHA256" "wine-$WINE_VERSION"
    local p
    for p in "$REPO"/patches/wine/*.diff; do
        echo "patch: $(basename "$p")"
        patch -s -p1 -d "$SRC/wine-$WINE_VERSION" < "$p"
    done
    # the cooperative handshake's wire protocol comes from x87sidecar itself (MIT; see NOTICE.md)
    x87sidecar_src
    cp "$SRC/x87sidecar/rosetta_loader/src/coop_proto.h" "$SRC/wine-$WINE_VERSION/dlls/ntdll/unix/x87sidecar_coop_proto.h"

    local ft; ft=$(brew_prefix freetype)
    rm -rf "$BLD/wine-tools" "$BLD/wine"; mkdir -p "$BLD/wine-tools" "$BLD/wine"
    # wrc needs nls/locale.nls and sfnt2fon needs (arm64) FreeType, or the tools build is incomplete
    (cd "$BLD/wine-tools" && PATH="$BISON_FLEX:$(brew_prefix llvm)/bin:$(brew_prefix lld)/bin:$PATH" \
        CC=/usr/bin/clang CXX=/usr/bin/clang++ \
        FREETYPE_CFLAGS="-I$ft/include/freetype2" FREETYPE_LIBS="-L$ft/lib -lfreetype" \
        "$SRC/wine-$WINE_VERSION/configure" --without-x --without-gnutls --without-vulkan --disable-tests \
        && PATH="$BISON_FLEX:$PATH" make -j"$JOBS" __tooldeps__ tools/sfnt2fon/sfnt2fon nls/locale.nls)

    (cd "$BLD/wine" && PATH="$BISON_FLEX:$MINGW:$PATH" CC="$X86_CC" CXX="/usr/bin/clang++ -arch x86_64" \
        CFLAGS="$X86_CFLAGS" LDFLAGS="-mmacosx-version-min=$MACOS_MIN" \
        FREETYPE_CFLAGS="-I$DEPS/include/freetype2" FREETYPE_LIBS="-L$DEPS/lib -lfreetype" \
        GNUTLS_CFLAGS="-I$DEPS/include" GNUTLS_LIBS="-L$DEPS/lib -lgnutls" \
        "$SRC/wine-$WINE_VERSION/configure" --host=x86_64-apple-darwin --with-wine-tools="$BLD/wine-tools" \
        --enable-archs=i386,x86_64 --prefix="$WINE_INSTALL" \
        --without-x --without-vulkan --without-gstreamer --without-sane --without-krb5 --without-cups --disable-tests \
        && PATH="$BISON_FLEX:$MINGW:$PATH" make -j"$JOBS" && PATH="$BISON_FLEX:$MINGW:$PATH" make install)

    # DXMT's build looks for winebuild inside the Wine build tree
    mkdir -p "$BLD/wine/tools/winebuild"
    ln -sfn "$BLD/wine-tools/tools/winebuild/winebuild" "$BLD/wine/tools/winebuild/winebuild"
    rm -f "$STAMPS/gamemode"   # make install replaced the loader
    done_step wine
}

# ---- x87sidecar: fast x87 for Rosetta (FSX is x87 code; stock Rosetta runs it ~270x slower than SSE) -------------
x87sidecar_src() {
    [ -f "$SRC/x87sidecar/rosetta_loader/src/coop_proto.h" ] && return
    rm -rf "$SRC/x87sidecar"
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$X87SIDECAR_TAG" "$X87SIDECAR_REPO" "$SRC/x87sidecar"
}
build_x87sidecar() {
    step x87sidecar && return
    local d="$SRC/x87sidecar"
    x87sidecar_src
    cmake -S "$d" -B "$BLD/x87sidecar" -G Ninja -DCMAKE_BUILD_TYPE=Release
    cmake --build "$BLD/x87sidecar" --target x87sidecar
    mkdir -p "$RUNTIME/bin"
    cp "$BLD/x87sidecar/bin/x87sidecar" "$RUNTIME/bin/x87sidecar"
    done_step x87sidecar
}

# ---- LLVM 15 for x86_64 macOS (DXMT's shader converter links against it) --------------------------------------------
build_llvm() {
    step llvm && return
    unpack "$LLVM_URL" "$LLVM_SHA256" llvm-project-15.0.7.src
    cmake -S "$SRC/llvm-project-15.0.7.src/llvm" -B "$BLD/llvm-darwin" -G Ninja \
        -DCMAKE_INSTALL_PREFIX="$TOOLCHAINS/llvm-darwin" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=x86_64 -DLLVM_HOST_TRIPLE=x86_64-apple-darwin \
        -DLLVM_ENABLE_ASSERTIONS=On -DLLVM_ENABLE_ZSTD=Off -DLLVM_TARGETS_TO_BUILD="" \
        -DLLVM_BUILD_TOOLS=Off -DLLVM_INCLUDE_BENCHMARKS=Off -DLLVM_INCLUDE_TESTS=Off -DLLVM_INCLUDE_EXAMPLES=Off \
        -DCMAKE_CXX_FLAGS="-D_LIBCPP_KEEP_TRANSITIVE_INCLUDES_LLVM23" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DLLVM_VERSION_PRINTER_SHOW_HOST_TARGET_INFO=Off
    cmake --build "$BLD/llvm-darwin"
    cmake --install "$BLD/llvm-darwin"
    rm -rf "$BLD/llvm-darwin"
    done_step llvm
}

# ---- DXMT: Direct3D 10/11 on Metal -----------------------------------------------------------------------------------
# 64-bit build: winemetal.so (Unix side, Metal) + 64-bit winemetal.dll, installed into Wine.
# 32-bit build (llvm-mingw: no SJLJ exceptions or emulated TLS; ~10% of FSX's main thread with GCC):
#   winemetal.dll into Wine, and d3d11/dxgi/d3d10core.dll, which go into the FSX folder only (`./fsxsilicon install`).
build_dxmt() {
    step dxmt && return
    [ -d "$TOOLCHAINS/llvm-darwin" ] || die "run the llvm step first"
    [ -d "$BLD/wine/dlls/ntdll" ] || die "the dxmt step needs the Wine build tree (run the wine step first)"
    export DEVELOPER_DIR; DEVELOPER_DIR=$(xcode_dev)
    xcrun -sdk macosx metal --version >/dev/null 2>&1 || die "Metal toolchain missing: xcodebuild -downloadComponent MetalToolchain"

    if [ ! -d "$TOOLCHAINS/$LLVM_MINGW_NAME" ]; then
        mkdir -p "$TOOLCHAINS"; tar -xf "$(fetch "$LLVM_MINGW_URL" "$LLVM_MINGW_SHA256")" -C "$TOOLCHAINS"
    fi

    local d="$SRC/dxmt"
    rm -rf "$d"
    git clone -q "$DXMT_REPO" "$d"
    git -C "$d" checkout -q "$DXMT_COMMIT"
    git -C "$d" submodule update -q --init include/native/directx
    git -C "$d" apply "$REPO/patches/dxmt/dxmt-fsx.diff"
    sed "s|@LLVM_MINGW@|$TOOLCHAINS|g" "$REPO/patches/dxmt/build-win32-llvm.txt.in" > "$d/build-win32-llvm.txt"

    local common=(--buildtype release --strip -Dnative_llvm_path="$TOOLCHAINS/llvm-darwin" -Dwine_build_path="$BLD/wine")
    rm -rf "$BLD/dxmt64" "$BLD/dxmt32" "$WORK/dxmt-stage"
    (cd "$d" && PATH="$MINGW:$PATH" meson setup --cross-file build-win64.txt "${common[@]}" \
        --prefix "$WORK/dxmt-stage/64" "$BLD/dxmt64" && PATH="$MINGW:$PATH" meson install -C "$BLD/dxmt64")
    (cd "$d" && meson setup --cross-file build-win32-llvm.txt "${common[@]}" -Dwine_builtin_dll=false \
        --prefix "$WORK/dxmt-stage/32" "$BLD/dxmt32" && meson install -C "$BLD/dxmt32")

    local s64="$WORK/dxmt-stage/64" s32="$WORK/dxmt-stage/32" w="$WINE_INSTALL/lib/wine"
    cp "$(find "$s64" -name winemetal.so | head -1)" "$w/x86_64-unix/"
    cp "$(find "$s64" -path '*x86_64-windows*' -name winemetal.dll | head -1)" "$w/x86_64-windows/"
    cp "$(find "$s32" -path '*i386-windows*' -name winemetal.dll | head -1)" "$w/i386-windows/"
    mkdir -p "$RUNTIME/dxmt"
    local f
    for f in d3d11 dxgi d3d10core; do
        cp "$(find "$s32" -name "$f.dll" | head -1)" "$RUNTIME/dxmt/$f.dll" || die "DXMT did not build $f.dll"
    done
    done_step dxmt
}

# ---- our helpers: fsxopt.dll (SSE2 vertex transform) and fsxrumble.exe (controller rumble) ------------------------
build_addons() {
    step addons && return
    mkdir -p "$RUNTIME/addons"
    "$MINGW/i686-w64-mingw32-gcc" -O2 -msse2 -mfpmath=sse -mpreferred-stack-boundary=2 -mincoming-stack-boundary=2 \
        -shared -static -static-libgcc -o "$RUNTIME/addons/fsxopt.dll" "$REPO/tools/fsxopt/fsxopt.c"
    "$MINGW/i686-w64-mingw32-gcc" -O2 -mwindows -o "$RUNTIME/addons/fsxrumble.exe" \
        "$REPO/tools/fsxrumble/fsxrumble.c" -lhid -lsetupapi
    done_step addons
}

# ---- Game Mode: run Wine's loader from an app bundle with a games category (applies in full screen) --------------
build_gamemode() {
    step gamemode && return
    "$REPO/scripts/gamemode-bundle.sh" install "$WINE_INSTALL" "$BUNDLE"
    done_step gamemode
}

all="deps x87sidecar wine llvm dxmt addons gamemode"
for s in ${@:-$all}; do
    case " $all " in *" $s "*) "build_$s" ;; *) die "unknown build step: $s (steps: $all)" ;; esac
done
ok "build complete: $RUNTIME"
