# Notices

## Licences in this repository

| Files | Licence |
|---|---|
| `fsxsilicon`, `scripts/`, `config/`, `tools/`, `docs/` | MIT ([LICENSE](LICENSE)) |
| `patches/wine/*.diff` | modify [Wine](https://www.winehq.org) 11.0: LGPL-2.1-or-later ([LICENSES/LGPL-2.1.txt](LICENSES/LGPL-2.1.txt)) |
| `patches/dxmt/*` | modify [DXMT](https://github.com/3Shain/dxmt): LGPL-2.1 ([LICENSES/LGPL-2.1.txt](LICENSES/LGPL-2.1.txt)) |

## Third-party software used by the build

None of these are included in this repository. `./fsxsilicon build` downloads them from their official sources (URLs and
checksums in `scripts/lib.sh`) and builds them on your Mac; their licences apply to what it builds:

| Project | Licence |
|---|---|
| [Wine](https://www.winehq.org) 11.0 | LGPL-2.1-or-later |
| [DXMT](https://github.com/3Shain/dxmt) | LGPL-2.1 (plus the licences of its submodules) |
| [x87sidecar](https://github.com/athei/x87sidecar) | MIT. The build also copies its `rosetta_loader/src/coop_proto.h` (the cooperative handshake protocol) into Wine's source tree for `ntdll-x87sidecar-cooperative.diff`. |
| [LLVM](https://llvm.org) 15.0.7 | Apache-2.0 with LLVM exception |
| [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) | Apache-2.0 with LLVM exception, and mingw-w64's licences |
| [FreeType](https://freetype.org) 2.13.3 | FreeType License or GPL-2.0 |
| [GnuTLS](https://gnutls.org) 3.8.9, [Nettle](https://www.lysator.liu.se/~nisse/nettle/) 3.10.1, [GMP](https://gmplib.org) 6.3.0 | LGPL-2.1-or-later / LGPL-3.0-or-later or GPL-2.0-or-later |
| Homebrew packages (`./fsxsilicon deps`) | their own licences |

If you redistribute a build (for example a packaged `runtime/`), you take on those projects' obligations, such as
offering the corresponding source of the LGPL components including these patches.

## Microsoft and Valve software

This project does not include, and must not be used to distribute, any part of Microsoft Flight Simulator X,
Microsoft redistributables (DirectX/D3DX runtime, Visual C++ runtime, MFC, core fonts) or Valve's Steam client.
`./fsxsilicon setup` downloads, from Microsoft and Valve directly to your own Mac, the DirectX June 2010 redistributable
(only `d3dx10_34.dll` and `d3dcompiler_34.dll` are extracted, into your own Wine prefix), the Microsoft core fonts
(through winetricks) and Valve's Steam installer, under the terms those vendors offer them. You need your own licensed
copy of FSX: Steam Edition, installed through Steam. Nothing here bypasses or alters Steam's or FSX's licensing or DRM.

Microsoft Flight Simulator, DirectX and Steam are trademarks of their respective owners. This project is not
affiliated with or endorsed by Microsoft or Valve.

## SimConnect

`tools/fsxrumble` uses FSX's SimConnect interface. It includes no SimConnect SDK headers or libraries: the few
functions and structures it needs are declared from the public SimConnect documentation, and it loads the
`SimConnect.dll` that ships with your own FSX installation at run time.

## Interoperability

To make FSX work with independently created software (Wine, DXMT, fsxopt), its binaries were analysed locally to
find out how they use Direct3D, sound and input. This repository contains no FSX code (decompiled or otherwise), no
FSX shader sources and no FSX data. The only information about FSX's internals here is what the interoperability code
itself needs (for example, function and vtable addresses in `tools/fsxopt`, and descriptions of behaviour in
docs/BUILD.md). fsxopt patches no FSX code: it replaces one pointer in a function table in memory while FSX runs.
