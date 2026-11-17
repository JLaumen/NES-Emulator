# Plan

Each step ends with something we can check.

1. [x] **Cartridge**: parse iNES files; mapper 0 only.
2. [x] **CPU**: official 6502 opcodes; matches the first 5004 lines of
   nestest.log (see CLAUDE.md).
3. [x] **PPU background**: registers $2000–$2007, VRAM with mirroring,
   per-scanline background rendering into a framebuffer, vblank NMI.
   Check: a game's title screen is visible.
4. [x] **Window**: show frames at 60 Hz in `app/`.
5. [ ] **Sprites**: OAM, OAM DMA ($4014), sprite-0 hit.
6. [ ] **Controller**: $4016 reads from the keyboard. Check: games play.

Later, maybe: PAL, more mappers, audio.
