# CLAUDE.md

Goal: the simplest NES emulator, not the most accurate. Code and docs alike
should be minimal, clear, and elegant. Common games should still play.
Simplest means the implementation, not the features: enhancements that
make games nicer to play (pause, save states, no sprite flicker, …) are
welcome, even when the console couldn't do them. Each is off unless its
command-line option turns it on, like `--debug`, `--vsync` and `--pause`.

- Scope: NTSC NES: 6502 CPU, PPU, APU, controller, mapper 0, plus
  enhancements (see PLAN.md).
  No cycle accuracy, no PAL (yet).
- NTSC timing: 262 scanlines, 3 PPU dots per CPU cycle, the CPU's clock rate.
  These constants live in one place (`NES`; the APU's tables are NTSC too)
  so PAL can be added later. The sound card paces the game: each frame
  waits for the sound queue to run low. `--vsync` paces it by the screen
  refresh instead: each refresh runs the frames due, one every k refreshes
  at about k × 60.1 Hz, else at the NES's rate (`frameRate`).
- Pure core in `src/`, IO in `app/` (an SDL2 window and audio device via the
  `sdl2` package; with `--vsync`, the sound plays up to 0.5% faster or
  slower to keep its queue level; with `--pause`, Escape pauses and
  resumes).
  `--debug` puts the visuals beside the game in the same window: a second
  window breaks vsync on GNOME Wayland.
- Warnings are errors. Use any GHC language feature or package, bundled or
  external, when it improves the quality of the code; don't add one that
  doesn't.
- Core state lives in `ST` (mutable unboxed arrays for memory); the core's
  API stays pure via `runST`. Records use `OverloadedRecordDot` with
  `NoFieldSelectors`.
- Modules: `Cartridge` (iNES parsing), `Bus` (CPU memory map), `CPU` (official
  6502 opcodes, per-instruction cycle counts; unofficial opcodes act as 1-byte
  NOPs), `PPU` (registers, VRAM, OAM; renders background and
  sprites a scanline at a time), `APU` (a pure state machine in an `STRef`,
  caught up once a scanline; samples at 44.1 kHz), `Controller` ($4016),
  `Visualise` (draws a snapshot of the PPU, APU and CPU into one picture),
  `NES` (public API: a lazy list of frames, each a picture, its sound and
  its visuals, drawn only when used, from a lazy list of buttons held, run
  scanline by scanline).
- CPU check: get `nestest.nes` and `nestest.log` (e.g. from
  christopherpow/nes-test-roms, `other/`), then
  `sed -E 's/^(....).*(A:.. X:.. Y:.. P:.. SP:..).*(CYC:[0-9]+)\r?$/\1 \2 \3/' nestest.log > expected.txt`
  and `diff expected.txt <(cabal run -v0 nes -- --nestest nestest.nes)`.
  The first 5004 lines (all official opcodes) must match; the rest test
  unofficial opcodes.
- Toolchain: GHC 9.14 (pinned in `cabal.project`), GHC2024, cabal 3.18.
- Build: `cabal build`. Run: `cabal run nes -- game.nes`.
- Before committing: `ormolu -i $(git ls-files '*.hs')`, `cabal-gild nes.cabal`,
  `hlint .`, and `cabal build` must all pass cleanly. CI
  (`.github/workflows/ci.yml`) checks the same; keep tool versions in sync.
- Keep README.md (for users), CLAUDE.md (for Claude) and PLAN.md (where we
  are, what's next) current with every change.
