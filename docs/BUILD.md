# How the build and setup work

`./fsxsilicon` does all of this; this page explains each step and why it is done that way, for when something
needs fixing or changing. Pinned versions and checksums are in `scripts/lib.sh`; the build commands are in
`scripts/build.sh`.

## Prerequisites (`./fsxsilicon deps`)

- Apple Silicon Mac with Rosetta 2.
- Homebrew: `mingw-w64` (Wine's PE side, fsxopt, fsxrumble, DXMT 64-bit), `bison flex`, `llvm lld` (only for the
  Wine tools build's configure check), `freetype` (arm64, for the Wine tools), `cmake ninja meson` (LLVM, DXMT,
  x87sidecar), `cabextract` and `winetricks` (prefix setup).
- Xcode with the Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`): DXMT compiles Metal shaders.
  The scripts use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (override with `DEVELOPER_DIR`), so
  `xcode-select` can keep pointing at the Command Line Tools.

Homebrew's Wine casks were disabled on 2026-09-01 (Gatekeeper), and the port needs a patched Wine anyway.

## Build (`./fsxsilicon build`)

Steps run in this order and each is skipped once done (stamps in `.work/stamps/`):

| step | result in `runtime/` |
|---|---|
| `deps` | `deps/lib`: x86_64 FreeType 2.13.3, GMP 6.3.0, Nettle 3.10.1, GnuTLS 3.8.9 |
| `wine` | `wine-install/`: Wine 11.0 with `patches/wine/*.diff` |
| `x87sidecar` | `bin/x87sidecar`, built from the pinned release tag |
| `llvm` | (`.work/toolchains/llvm-darwin`) LLVM 15.0.7 for x86_64 macOS, which DXMT links against |
| `dxmt` | `winemetal.so`/`winemetal.dll` in Wine; `dxmt/` d3d11, dxgi, d3d10core for the FSX folder |
| `addons` | `addons/fsxopt.dll`, `addons/fsxrumble.exe` |
| `gamemode` | `Wine FSX.app` (see below) |

**Wine** on macOS runs as x86_64 under Rosetta. Apple's clang can't run under Rosetta (libxcrun is arm64-only),
so Wine is a **cross build**: native arm64 tools first (`.work/build/wine-tools`), then an x86_64 host build with
`--host=x86_64-apple-darwin --with-wine-tools=…`, WoW64 (`--enable-archs=i386,x86_64`). Notes:
- A plain native configure detects the host as aarch64 from `uname` and fails in winnt.h.
- The tools build needs `make nls/locale.nls` or wrc fails with "unable to load locale.nls", and it needs arm64
  FreeType, or sfnt2fon can't generate Wine's bitmap fonts.
- GnuTLS is required: without it Wine's bcrypt/secur32 can't do TLS and Steam can't open its WebSocket connections.
- Run the x86_64 loader (`wine-install/lib/wine/x86_64-unix/wine`, or `build/wine/loader/wine` in the build tree),
  not `build/wine/wine`, which is a symlink to the arm64 tools loader.
- Don't run Wine through `/usr/bin/timeout` or other SIP-protected binaries: they strip `DYLD_*` variables, so
  FreeType and GnuTLS (found through `DYLD_FALLBACK_LIBRARY_PATH`) are not loaded.

**DXMT** (commit 25ea28f, `patches/dxmt/dxmt-fsx.diff`):
- LLVM 15.0.7 is built with the flags from DXMT's CI (`.github/workflows/ci.yml`), plus
  `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` for CMake 4.
- `winemac-dxmt-compat.diff` exports `macdrv_functions`, a compatibility table in the Wine 8 layout DXMT expects.
- DXMT looks for `tools/winebuild/winebuild` inside the Wine build tree; the build symlinks it from the tools build.
- The 64-bit build (`build-win64.txt`, mingw-w64 GCC) makes winemetal.so, the Unix side that talks to Metal.
- The 32-bit DLLs FSX uses are built with llvm-mingw (`patches/dxmt/build-win32-llvm.txt.in`): GCC's SJLJ exceptions
  and emulated TLS cost ~10% of FSX's main thread. `-Dwine_builtin_dll=false` makes them native DLLs.
- DXMT is **per app**: d3d11.dll, dxgi.dll and d3d10core.dll go into the FSX folder with native overrides for
  fsx.exe only. Installed Wine-wide it breaks Steam ("cross-process swapchain not supported").
- The patch: 32-bit uploads become `memcpy` (staging ring and constant buffers in 32-bit-addressable memory),
  vertex shader variants always get an IA layout, and d3d11.dll loads `fsxopt.dll` from the game folder if present.

**x87sidecar** (athei/x87sidecar) with `ntdll-x87sidecar-cooperative.diff`: when `ROSETTA_X87_PATH` names the
sidecar, Wine re-executes every 32-bit process as `x87sidecar --cooperative wine …`. Cooperative mode needs no
entitlements and no password. `./fsxsilicon` sets this unless `FSXSILICON_X87=0`.

## Prefix (`./fsxsilicon setup`)

- `wineboot -i`, skipping the Mono and Gecko prompts (`WINEDLLOVERRIDES=mscoree,mshtml=`).
- `config/wine.reg`, for `fsx.exe` only (`HKCU\Software\Wine\AppDefaults\fsx.exe`):
  - `Direct3D\renderer=gdi`: avoids wined3d's OpenGL probing (crashes in WoW64); FSX only uses D3D9 for caps checks.
    `wined3d-no3d-sm3-caps.diff` makes that adapter report Shader Model 3, or FSX refuses to start
    ("does not meet minimum requirements for shader support").
  - `DllOverrides`: dxgi, d3d11, d3d10core, d3dx10_34, d3dcompiler_34 = `native,builtin`; gameoverlayrenderer = ""
    (the Steam overlay's hooks loop forever in Wine's exception handler).
  - `DirectSound\Resampler=linear` (with `dsound-linear-resampler-sse2.diff`).
  - and `HKCU\Software\Wine\Mac Driver`: `LeftOptionIsAlt=y`, `RightOptionIsAlt=y` (Option opens FSX's menu bar).
- Controller: Wine leaves raw-HID gamepads to its SDL backend, which this build doesn't have (Homebrew's SDL is arm64
  only), so an Xbox Wireless Controller over Bluetooth was ignored ("ignoring hidraw device 045e:0b20"). `setup` sets
  `HKLM\System\CurrentControlSet\Services\winebus\EnableHidraw` to `045E:0B20`; `./fsxsilicon controller A:B C:D` sets
  another list. DirectInput then shows "Xbox Wireless Controller" (6 axes, 16 buttons, D-pad); assign it in FSX under
  Options > Settings > Controls.
- **Effects**: Wine's d3d10 effect compiler can't build FSX's .fx files (E5017), so FSX uses Microsoft's d3dx10_34 and
  d3dcompiler_34, extracted from `JUN2007_d3dx10_34_x86.cab` in the DirectX June 2010 redistributable (downloaded from
  Microsoft) into `syswow64`.
- **Fonts**: FSX's UI (menus, ATC window, kneeboard) reads font *files* from `C:\windows\fonts` and draws the glyphs
  itself, so the prefix needs the Microsoft core fonts (`winetricks corefonts`), or that text is silently missing.
  winetricks waits until every Wine process in the prefix has exited, so quit Steam first.
- **Steam**: Valve's `SteamSetup.exe /S`. The first launch self-updates twice (exit code 42 = restart after update).

## Steam (`./fsxsilicon steam`)

Steam's windows stayed black on macOS: Chromium's GPU process painted into child windows owned by another process,
and winemac's window surfaces are per process. `kernelbase-steamwebhelper-inprocess-gpu.diff` appends
`--in-process-gpu` to the main steamwebhelper.exe, and Steam is started with
`-cef-disable-gpu -cef-disable-gpu-compositing`. It is started detached (ignoring SIGHUP), because Steam exits with its
parent shell; not through `/usr/bin/nohup`, which (being SIP-protected) drops `DYLD_*`. Output: `runtime/steam.log`.

Let Steam install FSX into the prefix's own `steamapps`: a symlinked install folder makes Steam download it again.
FSX's crash handler starts `dxdiag.exe`, which hangs under Wine, and Steam then refuses to start FSX; `./fsxsilicon steam`
kills a leftover one first.

## FSX (`./fsxsilicon install`)

Copies `runtime/dxmt/*.dll`, `fsxopt.dll` and `fsxrumble.exe` into the FSX folder (`runtime/FSX` links to it), writes
`exe.xml` (starts fsxrumble with FSX) if there isn't one, and sets in FSX's config file. That is
`%APPDATA%\Microsoft\FSX\fsx.CFG` when FSX: Steam Edition is the only FSX installed, and `FSX-SE\fsx_se.CFG` when it
sits beside the boxed FSX; `install` picks the folder in which FSX's first run created `scenery.cfg`.
- `[GRAPHICS] D3D10=1`: DX10 preview mode. Without it FSX takes its DX9 path, which can't render here, and quits.
- `[JobScheduler] AffinityMask=62`: FSX's hyper-threading detection gives mask 2 under Rosetta.
- `[Trusted] fsxrumble.exe.<hash>=1`: FSX asks once whether to trust a new add-on executable (and again after every
  rebuild). Under Wine that prompt can be dismissed unseen, which records `=0` or `=-1`. Run `./fsxsilicon install` again
  (FSX closed) after FSX has seen a new fsxrumble.exe.

The first FSX run asks to set the new default key mappings: answer Yes.

**Rumble**: FSX only does force feedback through DirectInput, which Xbox controllers don't support (on Windows
either). `fsxrumble` reads the aircraft state over SimConnect (touchdown sink rate, ground speed, stall and overspeed
warnings, gear in transit) and sends the controller's Bluetooth rumble report through Windows HID. It loads FSX's own
SimConnect.dll from the FSX folder. `fsxrumble.exe --test` sends a single pulse; status goes to `fsxrumble.log`.

**fsxopt.dll**: an SSE2 reimplementation of g2d's GDevice_DrawImmediate (vtbl +0xdc), FSX's CPU vertex transform, for
unlit draws. No code is patched: it points the DrawImmediate slot of g2d's GDX10Device vtable (read-only data) at the
replacement. Its arithmetic mirrors MSVC's x87 precision; the first 4000 draws run both versions and compare (log:
`fsxopt.log` beside fsx.exe; expect "verify done: 0 mismatching draws; replacement active"). Delete
`FSX/fsxopt.dll` to disable. Patching FSX *code* at run time destabilises it under Rosetta/Wine; data-only changes
are fine.

## Game Mode bundle (`./fsxsilicon gamemode on|off`)

`scripts/gamemode-bundle.sh` copies Wine's loader into `runtime/Wine FSX.app/Contents/MacOS/` (Info.plist:
LSApplicationCategoryType simulation-games, LSSupportsGameMode) with an ntdll.so symlink beside it, and makes the
installed loader a relative symlink into the bundle. Game Mode engages only in full screen (Option+Enter).
Don't use a shell-script wrapper instead of the symlink: every 32-bit (x87sidecar) process then crashes.

## Performance

From ~3 FPS to ~55 FPS at Very High (M2 Pro-class Mac, 1337x899, with sound); 26-30 FPS with every slider at maximum, where
FSX's main thread is CPU-bound (GPU ~3 ms per frame):
- **x87sidecar**: FSX is x87 code, which stock Rosetta runs ~270x slower than SSE.
- **DirectSound**: cheap linear resampler.
- **DXMT**: memcpy uploads and the llvm-mingw build.
- **d3d10**: `d3d10-null-variable-buffer.diff` also speeds up effect matrix writes.
- **C runtime maths**: `msvcrt-musl-sse2.diff` compiles Wine's musl-based libm (used by msvcr80, msvcrt, ucrtbase and
  the other CRTs) and msvcrt's math.c with SSE2 on i386. FSX calls `cos`/`sin`/`sqrt` constantly; with Wine's default
  x87 build that was ~24% of FSX's main thread at maximum settings, ~13% with SSE2. The patch also gives
  `_CIsin/_CIcos/_CItan/_CIatan/_CIexp/_CIlog/_CIsqrt` (the x87-register entry points MSVC code calls) a fast path that
  skips Wine's spill and reload of the whole x87 stack for ordinary arguments (~7% of the main thread left).
- **fsxopt.dll**: see above.

Ideas not yet tried: FSX's `FIBER_FRAME_TIME_FRACTION` and `[BufferPools]` settings, per-slider CPU cost, and
x87sidecar's own speed on FSX's hottest blocks.
