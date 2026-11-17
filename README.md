# nes

[![CI](https://github.com/JLaumen/NES-Emulator/actions/workflows/ci.yml/badge.svg)](https://github.com/JLaumen/NES-Emulator/actions/workflows/ci.yml)

A small, simple NES emulator in Haskell. It favours readable code over
perfect accuracy and supports NTSC mapper 0 games without sound.

```sh
cabal run nes -- game.nes
```

Status: the CPU passes nestest's official-opcode tests
(`cabal run nes -- --nestest nestest.nes` prints a trace) and the PPU draws
backgrounds; a window, sprites and input are next.

MIT licensed.
