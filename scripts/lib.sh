# Shared settings and helpers for ./fsxsilicon and scripts/*.sh. Sourced, not run.
#
# Directories (all overridable from the environment):
#   FSXSILICON_RUNTIME  what FSX needs at run time: Wine, libraries, x87sidecar, the Wine prefix  (default: ./runtime)
#   FSXSILICON_WORK     downloads, sources, build trees, toolchains; safe to delete after a build (default: ./.work)

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="${FSXSILICON_RUNTIME:-$REPO/runtime}"
WORK="${FSXSILICON_WORK:-$REPO/.work}"

DL="$WORK/downloads"
SRC="$WORK/src"
BLD="$WORK/build"
TOOLCHAINS="$WORK/toolchains"
STAMPS="$WORK/stamps"

WINE_INSTALL="$RUNTIME/wine-install"
DEPS="$RUNTIME/deps"
PREFIX="${WINEPREFIX:-$RUNTIME/prefix}"
BUNDLE="$RUNTIME/Wine FSX.app"
FSX_DIR="$PREFIX/drive_c/Program Files (x86)/Steam/steamapps/common/FSX"

JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
MACOS_MIN=11.0

# ---- pinned versions ---------------------------------------------------------------------------------------------
WINE_VERSION=11.0
WINE_URL=https://dl.winehq.org/wine/source/11.0/wine-11.0.tar.xz
WINE_SHA256=c07a6857933c1fc60dff5448d79f39c92481c1e9db5aa628db9d0358446e0701

FREETYPE_URL=https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz
FREETYPE_SHA256=0550350666d427c74daeb85d5ac7bb353acba5f76956395995311a9c6f063289
GMP_URL=https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz
GMP_SHA256=a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898
NETTLE_URL=https://ftp.gnu.org/gnu/nettle/nettle-3.10.1.tar.gz
NETTLE_SHA256=b0fcdd7fc0cdea6e80dcf1dd85ba794af0d5b4a57e26397eee3bc193272d9132
GNUTLS_URL=https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.9.tar.xz
GNUTLS_SHA256=69e113d802d1670c4d5ac1b99040b1f2d5c7c05daec5003813c049b5184820ed

DXMT_REPO=https://github.com/3Shain/dxmt.git
DXMT_COMMIT=25ea28f
LLVM_URL=https://github.com/llvm/llvm-project/releases/download/llvmorg-15.0.7/llvm-project-15.0.7.src.tar.xz
LLVM_SHA256=8b5fcb24b4128cf04df1b0b9410ce8b1a729cb3c544e6da885d234280dedeac6
LLVM_MINGW_NAME=llvm-mingw-20260908-ucrt-macos-universal
LLVM_MINGW_URL=https://github.com/mstorsjo/llvm-mingw/releases/download/20260908/$LLVM_MINGW_NAME.tar.xz
LLVM_MINGW_SHA256=d1dc5d1ecf3a3ced5ed5544c72f1acd0c8e84eb3024d520ecc6b143eec62a149

X87SIDECAR_REPO=https://github.com/athei/x87sidecar.git
X87SIDECAR_TAG=v1.9.1

# Microsoft's DirectX June 2010 redistributable: FSX needs d3dx10_34 + d3dcompiler_34 from it (Wine's d3dx10
# can't compile FSX's effects). Downloaded from Microsoft at setup time; never stored in this repository.
DXREDIST_URL=https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe
DXREDIST_SHA256=053f76dcbb28802e23341b6a787e3b0791c0fa5c8d4d011b1044172dbf89c73b
STEAMSETUP_URL=https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe

BREW_PACKAGES="mingw-w64 bison flex llvm lld cmake ninja meson ccache cabextract winetricks freetype"

# ---- helpers -----------------------------------------------------------------------------------------------------
if [ -t 1 ]; then _b=$'\033[1m'; _r=$'\033[31m'; _g=$'\033[32m'; _0=$'\033[0m'; else _b= _r= _g= _0=; fi
log()  { printf '%s==>%s %s\n' "$_b" "$_0" "$*"; }
ok()   { printf '%s ok%s %s\n' "$_g" "$_0" "$*"; }
die()  { printf '%serror:%s %s\n' "$_r" "$_0" "$*" >&2; exit 1; }

# step NAME: true if NAME was already completed (stamp present). done_step NAME marks it complete.
step()      { [ -f "$STAMPS/$1" ] && { ok "$1 (already done; rm $STAMPS/$1 to redo)"; return 0; }; log "$1"; return 1; }
done_step() { mkdir -p "$STAMPS"; touch "$STAMPS/$1"; }

# fetch URL SHA256: download into $DL once, verify, print the local path
fetch() {
    local url=$1 sum=$2 f="$DL/$(basename "$1")"
    mkdir -p "$DL"
    if [ ! -f "$f" ]; then
        curl -fL --retry 3 -o "$f.part" "$url" >&2 || die "download failed: $url"
        mv "$f.part" "$f"
    fi
    if [ -n "$sum" ]; then
        echo "$sum  $f" | shasum -a 256 -c --status || die "checksum mismatch: $f (delete it to download again)"
    fi
    echo "$f"
}

# unpack URL SHA256 DIR [tar args...]: fetch and extract an archive into $SRC/DIR (fresh); extra args select members
unpack() {
    local f; f=$(fetch "$1" "$2")
    rm -rf "$SRC/$3"; mkdir -p "$SRC"
    tar -xf "$f" -C "$SRC" "${@:4}"
    [ -d "$SRC/$3" ] || die "$f did not contain $3"
}

brew_prefix() { brew --prefix "$1" 2>/dev/null || die "Homebrew package $1 missing (./fsxsilicon deps)"; }

# Xcode with the Metal toolchain; DXMT compiles Metal shaders at build time
xcode_dev() {
    local d=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
    [ -d "$d" ] || die "Xcode not found at $d (set DEVELOPER_DIR)"
    echo "$d"
}

# Environment for running the runtime Wine.
# Don't run Wine through /usr/bin/timeout or other SIP-protected tools: they strip DYLD_* variables.
wine_env() {
    export WINEPREFIX="$PREFIX"
    export WINESERVER="$WINE_INSTALL/bin/wineserver"
    export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"
    export WINEDEBUG="${WINEDEBUG:--all}"
    export DYLD_FALLBACK_LIBRARY_PATH="$DEPS/lib${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"
    # 32-bit processes start through x87sidecar (fast x87 under Rosetta); FSXSILICON_X87=0 turns it off
    if [ "${FSXSILICON_X87:-1}" = 1 ] && [ -x "$RUNTIME/bin/x87sidecar" ]; then
        export ROSETTA_X87_PATH="$RUNTIME/bin/x87sidecar"
    else
        unset ROSETTA_X87_PATH
    fi
}
WINE="$WINE_INSTALL/lib/wine/x86_64-unix/wine"
wine() { wine_env; "$WINE" "$@"; }

wine_running() { pgrep -f "$WINE_INSTALL/" >/dev/null 2>&1 || pgrep -f "$BUNDLE/" >/dev/null 2>&1; }
wine_wait()    { WINEPREFIX="$PREFIX" "$WINE_INSTALL/bin/wineserver" -w; }
