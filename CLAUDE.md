# CLAUDE.md

Goal: the simplest NES emulator, not the most accurate. Code and docs alike
should be minimal, clear, and elegant. Common games should still play.

- Scope: NTSC NES: 6502 CPU, PPU, controller, mapper 0.
  No audio, no cycle accuracy, no PAL (yet).
- NTSC timing: 60 Hz, 262 scanlines, 3 PPU dots per CPU cycle. Keep these
  constants in one place so PAL can be added later.
- Pure core in `src/`, IO in `app/`.
- Warnings are errors; add dependencies only when they clearly pay off.
- Toolchain: GHC 9.14 (pinned in `cabal.project`), GHC2024, cabal 3.18.
- Build: `cabal build`. Run: `cabal run nes -- game.nes`.
- Before committing: `ormolu -i $(git ls-files '*.hs')`, `cabal-gild nes.cabal`,
  `hlint .`, and `cabal build` must all pass cleanly. CI
  (`.github/workflows/ci.yml`) checks the same; keep tool versions in sync.
- Keep README.md (for users) and CLAUDE.md (for Claude) current with every
  change.
