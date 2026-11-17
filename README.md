# nes

[![CI](https://github.com/JLaumen/NES-Emulator/actions/workflows/ci.yml/badge.svg)](https://github.com/JLaumen/NES-Emulator/actions/workflows/ci.yml)

A small, simple NES emulator in Haskell. It favours readable code over
perfect accuracy and supports NTSC mapper 0 games without sound.

```sh
cabal run nes -- game.nes
```

It needs SDL2 (`libsdl2-dev` on Debian/Ubuntu, `SDL2-devel` or
`sdl2-compat-devel` on Fedora). Fedora's `sdl2-compat` is invisible to
cabal; tell it where SDL2 is in `cabal.project.local`:

```cabal
package sdl2
  flags: -pkgconfig
  extra-include-dirs: /usr/include/SDL2
```

Status: the CPU passes nestest's official-opcode tests
(`cabal run nes -- --nestest nestest.nes` prints a trace) and the PPU draws
backgrounds in a window; sprites and input are next.

MIT licensed.
