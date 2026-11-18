# nes

[![CI](https://github.com/JLaumen/NES-Emulator/actions/workflows/ci.yml/badge.svg)](https://github.com/JLaumen/NES-Emulator/actions/workflows/ci.yml)

A small, simple NES emulator in Haskell. It favours readable code over
perfect accuracy and supports NTSC mapper 0 games, with sound.

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

Keys: arrows, X (A), Z (B), Enter (Start), right Shift (Select).

`cabal run nes -- --debug game.nes` shows, beside the game, what the
emulator is doing: the nametables with the part on screen outlined, the
pattern tables, palettes and sprites, each sound channel as an
oscilloscope, and the CPU's registers and memory reads and writes.

The game runs at your display's refresh rate, so it needs a 60 Hz display
to run at the right speed.

The CPU passes nestest's official-opcode tests
(`cabal run nes -- --nestest nestest.nes` prints a trace).

MIT licensed.
