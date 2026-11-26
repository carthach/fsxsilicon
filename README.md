# FSX Silicon

**A Claude-generated compatibility framework for Microsoft Flight Simulator X on Apple Silicon.**
The code, patches and documentation were written with Anthropic's Claude (Claude Code). Not affiliated with or
endorsed by Microsoft, Valve or Anthropic.

Run **Microsoft Flight Simulator X: Steam Edition** on Apple Silicon Macs at playable frame rates:
FSX's Direct3D 10 renderer goes to **Metal** through [DXMT](https://github.com/3Shain/dxmt), its
32-bit x87 maths is accelerated with [x87sidecar](https://github.com/athei/x87sidecar), and a patched
**Wine 11** runs everything else (Win32/MFC, sound, input, Steam).

This repository contains **only our own work**: Wine and DXMT patches, two small helper programs, scripts and notes.
It contains no FSX, Microsoft or Valve files. You need your own copy of FSX: Steam Edition.

## Quick start

Needs an Apple Silicon Mac, [Homebrew](https://brew.sh), Xcode (for the Metal compiler) and ~30 GB free
(about 15 GB of that is build files you can delete afterwards).

```sh
git clone <this repo> fsxsilicon && cd fsxsilicon
./fsxsilicon deps      # Homebrew build tools, Xcode Metal toolchain, Rosetta
./fsxsilicon build     # Wine, DXMT, LLVM, x87sidecar, our helpers -> runtime/   (about an hour the first time)
./fsxsilicon setup     # Wine prefix: settings, fonts, d3dx10_34, Windows Steam
./fsxsilicon steam     # sign in, install FSX: Steam Edition, start it once, quit Steam
./fsxsilicon install   # DXMT + helpers into the FSX folder, FSX options
./fsxsilicon fsx       # play
```

After that, `./fsxsilicon steam` or `./fsxsilicon fsx` is all you need; `./fsxsilicon stop` ends every Wine process.
`./fsxsilicon status` shows what is in place, and `./fsxsilicon help` lists everything else.
After a successful build, `./fsxsilicon clean --all` deletes `.work/` and `brew uninstall` removes the build tools:
nothing at run time links against Homebrew.

Everything generated goes into two git-ignored folders: `runtime/` (Wine, libraries, x87sidecar and the Wine
prefix holding Steam and FSX) and `.work/` (downloads, sources, build trees). Set `FSXSILICON_RUNTIME` /
`FSXSILICON_WORK` to put them elsewhere. Every build step is skipped once done; `scripts/build.sh <step>` after
deleting its stamp in `.work/stamps/` redoes one.

Tips: Option+Enter toggles full screen (macOS Game Mode then applies). Option opens FSX's menu bar.
An Xbox Wireless Controller over Bluetooth works out of the box, with rumble; other pads: `./fsxsilicon controller VID:PID`.

## Status

| | |
|---|---|
| Steam (Windows client in Wine) | signs in, library and downloads work |
| FSX start-up screens, free flight | work |
| Rendering | DX10 preview mode on Metal; ~55 FPS at Very High on an M2 Pro-class Mac (60 FPS cap on default settings) |
| Sound | works (DirectSound, cheap resampler) |
| In-flight menu bar, ATC window, kneeboard | work (core fonts are installed by `./fsxsilicon setup`) |
| Xbox Wireless Controller (Bluetooth) | works, with rumble from `tools/fsxrumble` |
| DirectX 9 mode | not supported (Wine's OpenGL D3D9 crashes in WoW64 under Rosetta) |

## How it works

- **Wine 11.0** (x86_64 build run under Rosetta, WoW64 for 32-bit FSX) with the patches in `patches/wine`:
  - `ntdll-x87sidecar-cooperative.diff` re-launches 32-bit processes through x87sidecar when `ROSETTA_X87_PATH`
    is set (Rosetta runs x87 code ~270x slower than SSE; FSX is all x87). `./fsxsilicon` sets it; `FSXSILICON_X87=0` doesn't.
  - `dsound-linear-resampler-sse2.diff` makes DirectSound mixing cheap (opt-in per app: `Resampler=linear`).
  - `msvcrt-musl-sse2.diff` builds the C runtime's maths functions with SSE2 instead of x87 on 32-bit.
  - `d3d10-null-variable-buffer.diff` fixes a crash in d3d10 effects that FSX hits and speeds up matrix writes.
  - `wined3d-no3d-sm3-caps.diff` lets FSX's DX9 capability check pass while it renders through DX10.
  - `kernelbase-steamwebhelper-inprocess-gpu.diff` fixes Steam's black window on macOS.
  - `winemac-dxmt-compat.diff`: the window lookup table DXMT expects, in the layout Wine 11 no longer has.
- **DXMT** (`patches/dxmt/dxmt-fsx.diff`), its 32-bit side built with llvm-mingw:
  - 32-bit uploads (staging ring, constant buffers) become `memcpy` instead of a WoW64 call per update.
  - Vertex shader variants without an input layout no longer fail to build a Metal pipeline.
  - Loads `fsxopt.dll` from the game folder when present.
- **fsxopt.dll** (`tools/fsxopt`): an SSE2 reimplementation of FSX's CPU vertex transform
  (`GDevice_DrawImmediate`). It changes no game code: it repoints the DX10 device object at a copy of its
  vtable. It checks itself against FSX's own results for the first 4000 draws before switching over.
- **fsxrumble.exe** (`tools/fsxrumble`): Xbox controller rumble driven by the flight state over SimConnect
  (touchdown, ground roll, stall and overspeed warnings, gear movement), started by FSX through exe.xml.

[docs/BUILD.md](docs/BUILD.md) explains what each `./fsxsilicon` step does and why, including every setting FSX needs
and the problems they solve.

## Layout

| | |
|---|---|
| `fsxsilicon` | the command-line entry point |
| `scripts/` | `build.sh` (all build steps), `lib.sh` (paths, pinned versions and checksums), helpers |
| `config/` | Wine registry settings and FSX's add-on launcher file |
| `patches/` | our changes to Wine 11.0 and DXMT |
| `tools/` | fsxopt and fsxrumble sources |
| `LICENSES/` | the LGPL text that applies to `patches/` |

## Legal

See [NOTICE.md](NOTICE.md). Our own code is MIT licensed ([LICENSE](LICENSE)); patches are under the
licences of the projects they modify (LGPL-2.1). No Microsoft or Valve files are included: `./fsxsilicon setup`
downloads Steam, the DirectX redistributable and the core fonts from their vendors onto your own Mac.
