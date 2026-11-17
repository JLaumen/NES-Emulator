# CLAUDE.md

Goal: the simplest NES emulator, not the most accurate. Code and docs alike
should be minimal, clear, and elegant. Common games should still play.

- Scope: NTSC NES: 6502 CPU, PPU, controller, mapper 0.
  No audio, no cycle accuracy, no PAL (yet).
- NTSC timing: 60 Hz, 262 scanlines, 3 PPU dots per CPU cycle. These
  constants live in one place (`NES`) so PAL can be added later.
- Pure core in `src/`, IO in `app/` (an SDL2 window via the `sdl2` package).
- Warnings are errors. Use any GHC language feature or package, bundled or
  external, when it improves the quality of the code; don't add one that
  doesn't.
- Core state lives in `ST` (mutable unboxed arrays for memory); the core's
  API stays pure via `runST`. Records use `OverloadedRecordDot` with
  `NoFieldSelectors`.
- Modules: `Cartridge` (iNES parsing), `Bus` (CPU memory map), `CPU` (official
  6502 opcodes, per-instruction cycle counts; unofficial opcodes act as 1-byte
  NOPs), `PPU` (registers, VRAM, per-scanline rendering), `NES` (public API:
  a lazy list of frames, run scanline by scanline).
- CPU check: get `nestest.nes` and `nestest.log` (e.g. from
  christopherpow/nes-test-roms, `other/`), then
  `sed -E 's/^(....).*(A:.. X:.. Y:.. P:.. SP:..).*(CYC:[0-9]+)\r?$/\1 \2 \3/' nestest.log > expected.txt`
  and `diff expected.txt <(cabal run -v0 nes -- --nestest nestest.nes)`.
  The first 5004 lines (all official opcodes) must match; the rest test
  unofficial opcodes.
- Toolchain: GHC 9.14 (pinned in `cabal.project`), GHC2024, cabal 3.18.
- Build: `cabal build`. Run: `cabal run nes -- game.nes`.
- Before committing: `ormolu -i $(git ls-files '*.hs')`, `cabal-gild --io=nes.cabal`,
  `hlint .`, and `cabal build` must all pass cleanly. CI
  (`.github/workflows/ci.yml`) checks the same; keep tool versions in sync.
- Keep README.md (for users), CLAUDE.md (for Claude) and PLAN.md (where we
  are, what's next) current with every change.
