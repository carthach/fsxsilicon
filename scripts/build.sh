#!/bin/bash
# Build everything FSX needs into $RUNTIME, from pinned upstream sources plus the patches in this repository.
#
#   scripts/build.sh [step...]     steps: deps x87sidecar wine llvm dxmt addons gamemode   (default: all, in order)
#
# Each step leaves a stamp in .work/stamps and is skipped next time; delete the stamp (or `./fsxsilicon clean`) to redo.
# Rough times (M-series, 10+ cores): deps ~2 min, wine ~8 min, llvm ~3 min, dxmt ~1 min, the rest seconds.
#   FSXSILICON_CCACHE=0  don't compile through ccache (default: on when installed; cache in .work/ccache, so
#                        rebuilding a step after a patch change only recompiles what changed)
#   FSXSILICON_DEBUG=1   build Wine's PE modules with -g (symbolised Wine backtraces; ~2x the size)
set -eo pipefail
. "$(dirname "$0")/lib.sh"

[ "$(uname -m)" = arm64 ] || die "this port targets Apple Silicon Macs"
arch -x86_64 /usr/bin/true 2>/dev/null || die "Rosetta 2 is needed: softwareupdate --install-rosetta --agree-to-license"

BISON_FLEX="$(brew_prefix bison)/bin:$(brew_prefix flex)/bin"
MINGW="$(brew_prefix mingw-w64)/bin"
# CCL: compiler launcher prefix ("ccache " or nothing); CMAKE_CCL: the same for CMake projects
CCL= CMAKE_CCL=()
if [ "${FSXSILICON_CCACHE:-1}" = 1 ] && command -v ccache >/dev/null; then
    export CCACHE_DIR="${CCACHE_DIR:-$WORK/ccache}" CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-10G}"
    CCL="ccache " CMAKE_CCL=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
fi
X86_CC="${CCL}/usr/bin/clang -arch x86_64"
X86_CXX="${CCL}/usr/bin/clang++ -arch x86_64"
X86_CFLAGS="-O2 -mmacosx-version-min=$MACOS_MIN"
CROSS_CFLAGS="-O2"; [ "${FSXSILICON_DEBUG:-0}" = 1 ] && CROSS_CFLAGS="-g -O2"

# ---- x86_64 FreeType, GMP, Nettle, GnuTLS (Wine runs as x86_64; without GnuTLS Steam can't reach its servers) ----
# autobuild DIR URL SHA256 [configure args...]: build an autotools package as shared x86_64 libraries into $DEPS
autobuild() {
    unpack "$2" "$3" "$1"
    (cd "$SRC/$1" && ./configure --host=x86_64-apple-darwin --build=aarch64-apple-darwin --prefix="$DEPS" \
        --enable-shared --disable-static "${@:4}" && make -j"$JOBS" && make install)
    rm -rf "$SRC/$1"
}
build_deps() {
    step deps && return
    (
        export CC="$X86_CC" CFLAGS="$X86_CFLAGS" CPPFLAGS="-I$DEPS/include" LDFLAGS="-L$DEPS/lib"
        export PKG_CONFIG_PATH="$DEPS/lib/pkgconfig"
        autobuild freetype-2.13.3 "$FREETYPE_URL" "$FREETYPE_SHA256" \
            --without-harfbuzz --without-png --without-brotli --without-bzip2
        autobuild gmp-6.3.0 "$GMP_URL" "$GMP_SHA256" --disable-assembly
        autobuild nettle-3.10.1 "$NETTLE_URL" "$NETTLE_SHA256" --disable-documentation --disable-assembler
        autobuild gnutls-3.8.9 "$GNUTLS_URL" "$GNUTLS_SHA256" \
            --with-included-libtasn1 --with-included-unistring --without-p11-kit --without-idn --without-brotli \
            --without-zstd --without-zlib --without-tpm --without-tpm2 --without-leancrypto --disable-doc \
            --disable-manpages --disable-tests --disable-tools --disable-cxx --disable-guile --disable-nls
    )
    rm -rf "$DEPS/share" "$DEPS/bin"   # only the dylibs (and headers, for the Wine build) are needed
    done_step deps
}

# ---- Wine 11 with our patches: native arm64 tools, then an x86_64 cross build (WoW64: i386 + x86_64 PE) ----------
# Apple's clang can't run under Rosetta, so Wine is cross-built from arm64 (--host=x86_64-apple-darwin).
build_wine() {
    step wine && return
    [ -f "$DEPS/lib/libgnutls.dylib" ] || die "run the deps step first"
    local p ft src="$SRC/wine-$WINE_VERSION"; ft=$(brew_prefix freetype)
    unpack "$WINE_URL" "$WINE_SHA256" "wine-$WINE_VERSION"
    for p in "$REPO"/patches/wine/*.diff; do
        echo "patch: $(basename "$p")"
        patch -s -p1 -d "$src" < "$p"
    done
    # the cooperative handshake's wire protocol comes from x87sidecar itself (MIT; see NOTICE.md)
    x87sidecar_src
    cp "$SRC/x87sidecar/rosetta_loader/src/coop_proto.h" "$src/dlls/ntdll/unix/x87sidecar_coop_proto.h"

    rm -rf "$BLD/wine-tools" "$BLD/wine"; mkdir -p "$BLD/wine-tools" "$BLD/wine"
    # wrc needs nls/locale.nls and sfnt2fon needs (arm64) FreeType, or the tools build is incomplete;
    # llvm/lld are only on the PATH for configure's checks
    (cd "$BLD/wine-tools" && export PATH="$BISON_FLEX:$PATH" \
        && PATH="$(brew_prefix llvm)/bin:$(brew_prefix lld)/bin:$PATH" \
            CC="${CCL}/usr/bin/clang" CXX="${CCL}/usr/bin/clang++" \
            FREETYPE_CFLAGS="-I$ft/include/freetype2" FREETYPE_LIBS="-L$ft/lib -lfreetype" \
            "$src/configure" --without-x --without-gnutls --without-vulkan --disable-tests \
        && make -j"$JOBS" __tooldeps__ tools/sfnt2fon/sfnt2fon nls/locale.nls)

    # install-lib leaves out headers, import libraries and dev tools (DXMT builds against the build tree instead),
    # into an emptied wine-install/ so nothing is left over from an earlier build
    (cd "$BLD/wine" && export PATH="$BISON_FLEX:$MINGW:$PATH" \
        && CC="$X86_CC" CXX="$X86_CXX" i386_CC="${CCL}i686-w64-mingw32-gcc" x86_64_CC="${CCL}x86_64-w64-mingw32-gcc" \
        CFLAGS="$X86_CFLAGS" CROSSCFLAGS="$CROSS_CFLAGS" LDFLAGS="-mmacosx-version-min=$MACOS_MIN" \
        FREETYPE_CFLAGS="-I$DEPS/include/freetype2" FREETYPE_LIBS="-L$DEPS/lib -lfreetype" \
        GNUTLS_CFLAGS="-I$DEPS/include" GNUTLS_LIBS="-L$DEPS/lib -lgnutls" \
        "$src/configure" --host=x86_64-apple-darwin --with-wine-tools="$BLD/wine-tools" \
        --enable-archs=i386,x86_64 --prefix="$WINE_INSTALL" \
        --without-x --without-vulkan --without-gstreamer --without-sane --without-krb5 --without-cups \
        --disable-tests --disable-win16 \
        && make -j"$JOBS" && rm -rf "$WINE_INSTALL" && make install-lib)

    # DXMT's build looks for winebuild inside the Wine build tree
    mkdir -p "$BLD/wine/tools/winebuild"
    ln -sfn "$BLD/wine-tools/tools/winebuild/winebuild" "$BLD/wine/tools/winebuild/winebuild"
    rm -f "$STAMPS/dxmt" "$STAMPS/gamemode"   # the fresh install has neither winemetal nor the bundled loader
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
    cmake -S "$d" -B "$BLD/x87sidecar" -G Ninja -DCMAKE_BUILD_TYPE=Release "${CMAKE_CCL[@]}"
    cmake --build "$BLD/x87sidecar" --target x87sidecar
    mkdir -p "$RUNTIME/bin"
    cp "$BLD/x87sidecar/bin/x87sidecar" "$RUNTIME/bin/x87sidecar"
    done_step x87sidecar
}

# ---- LLVM 15 for x86_64 macOS (DXMT's shader converter links against it) --------------------------------------------
# Only the libraries airconv links (src/airconv/meson.build, from `llvm-config --libs bitwriter passes`) and the headers.
LLVM_LIBS="LLVMPasses LLVMTarget LLVMObjCARCOpts LLVMCoroutines LLVMipo LLVMInstrumentation LLVMVectorize LLVMLinker
    LLVMIRReader LLVMAsmParser LLVMFrontendOpenMP LLVMScalarOpts LLVMInstCombine LLVMAggressiveInstCombine
    LLVMTransformUtils LLVMBitWriter LLVMAnalysis LLVMProfileData LLVMSymbolize LLVMDebugInfoPDB LLVMDebugInfoMSF
    LLVMDebugInfoDWARF LLVMObject LLVMTextAPI LLVMMCParser LLVMMC LLVMDebugInfoCodeView LLVMBitReader LLVMCore
    LLVMRemarks LLVMBitstreamReader LLVMBinaryFormat LLVMSupport LLVMDemangle"
build_llvm() {
    step llvm && return
    # only llvm/ (without its tests) and the shared cmake/ modules: ~170 MB instead of 1.4 GB
    local t=llvm-project-15.0.7.src
    unpack "$LLVM_URL" "$LLVM_SHA256" $t --exclude "$t/llvm/test" "$t/llvm" "$t/cmake"
    cmake -S "$SRC/$t/llvm" -B "$BLD/llvm-darwin" -G Ninja "${CMAKE_CCL[@]}" \
        -DCMAKE_INSTALL_PREFIX="$TOOLCHAINS/llvm-darwin" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=x86_64 -DLLVM_HOST_TRIPLE=x86_64-apple-darwin \
        -DLLVM_ENABLE_ASSERTIONS=On -DLLVM_ENABLE_ZSTD=Off -DLLVM_TARGETS_TO_BUILD="" \
        -DLLVM_BUILD_TOOLS=Off -DLLVM_INCLUDE_BENCHMARKS=Off -DLLVM_INCLUDE_TESTS=Off -DLLVM_INCLUDE_EXAMPLES=Off \
        -DCMAKE_CXX_FLAGS="-D_LIBCPP_KEEP_TRANSITIVE_INCLUDES_LLVM23" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DLLVM_VERSION_PRINTER_SHOW_HOST_TARGET_INFO=Off
    cmake --build "$BLD/llvm-darwin" --target $LLVM_LIBS
    rm -rf "$TOOLCHAINS/llvm-darwin"
    local c
    for c in $LLVM_LIBS llvm-headers; do cmake --install "$BLD/llvm-darwin" --component "$c" >/dev/null; done
    rm -rf "$BLD/llvm-darwin" "$SRC/$t"
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

    # Only what is used: from the 64-bit build winemetal.so + winemetal.dll, from the 32-bit build winemetal.dll and
    # the three DLLs for the FSX folder. (.postproc = winebuild --builtin, which marks the Wine-side winemetal.dll.)
    local common=(--buildtype release -Dnative_llvm_path="$TOOLCHAINS/llvm-darwin" -Dwine_build_path="$BLD/wine")
    rm -rf "$BLD/dxmt64" "$BLD/dxmt32"
    (cd "$d" && PATH="$MINGW:$PATH" meson setup --cross-file build-win64.txt "${common[@]}" "$BLD/dxmt64" \
        && PATH="$MINGW:$PATH" ninja -C "$BLD/dxmt64" \
            src/winemetal/unix/winemetal.so src/winemetal/winemetal.dll.postproc)
    (cd "$d" && meson setup --cross-file build-win32-llvm.txt "${common[@]}" -Dwine_builtin_dll=false "$BLD/dxmt32" \
        && ninja -C "$BLD/dxmt32" src/winemetal/winemetal.dll.postproc \
            src/d3d11/d3d11.dll src/dxgi/dxgi.dll src/d3d10/d3d10core.dll)

    local b64="$BLD/dxmt64/src" b32="$BLD/dxmt32/src" w="$WINE_INSTALL/lib/wine" strip32
    strip32="$TOOLCHAINS/$LLVM_MINGW_NAME/bin/i686-w64-mingw32-strip"
    install -m 755 "$b64/winemetal/unix/winemetal.so" "$w/x86_64-unix/" && strip -x "$w/x86_64-unix/winemetal.so"
    install -m 644 "$b64/winemetal/winemetal.dll" "$w/x86_64-windows/"
    "$MINGW/x86_64-w64-mingw32-strip" "$w/x86_64-windows/winemetal.dll"
    install -m 644 "$b32/winemetal/winemetal.dll" "$w/i386-windows/" && "$strip32" "$w/i386-windows/winemetal.dll"
    mkdir -p "$RUNTIME/dxmt"
    install -m 644 "$b32/d3d11/d3d11.dll" "$b32/dxgi/dxgi.dll" "$b32/d3d10/d3d10core.dll" "$RUNTIME/dxmt/"
    "$strip32" "$RUNTIME/dxmt/"{d3d11,dxgi,d3d10core}.dll
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
