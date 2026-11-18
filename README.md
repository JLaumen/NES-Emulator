# nes

[![CI](https://github.com/JLaumen/NES-Emulator/actions/workflows/ci.yml/badge.svg)](https://github.com/JLaumen/NES-Emulator/actions/workflows/ci.yml)

A small, simple NES emulator in Haskell. It favours readable code over
perfect accuracy and supports NTSC games on mapper 0 (NROM, as Super
Mario Bros.) and mapper 4 (MMC3, as Super Mario Bros. 3), with sound.

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

The sound card keeps the game at the right speed. With `--vsync`, the
display does instead, in step with its refreshes: perfectly smooth on a
60 or 120 Hz display, and the right speed on any other.

With `--pause`, Escape pauses and resumes the game.

With `--crt`, the picture has dark gaps between its rows, like an old TV's
scanlines.

With `--no-flicker`, every sprite on a line is drawn, not just the first
eight the NES could, so games no longer flicker when sprites crowd a line.

With `--fullscreen`, the game fills the screen. With `--wide`, its pixels
are a little wider than tall (8:7), as on a TV. With `--smooth`, the
picture scales smoothly, so its pixels look even at any size, without
blurring.

With `--ghost`, each frame is blended with the one before, like an old
TV's afterglow: sprites that games draw only every other frame show
steady and see-through, as they did on a TV, instead of flickering.

With `--palette file.pal`, the game shows its colours as that palette
has them. The NES makes a TV signal, not RGB, so no one palette is right;
`PALs/` holds well-known ones, from FCEUX's collection, as in
`--palette PALs/Smooth_FBX.pal`.

The options combine, as in `cabal run nes -- --debug --vsync game.nes`.

The CPU passes nestest's official-opcode tests
(`cabal run nes -- --nestest nestest.nes` prints a trace).

MIT licensed.
