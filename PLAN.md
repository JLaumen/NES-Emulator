# Plan

Each step ends with something we can check.

1. [x] **Cartridge**: parse iNES files; mapper 0 only.
2. [x] **CPU**: official 6502 opcodes; matches the first 5004 lines of
   nestest.log (see CLAUDE.md).
3. [x] **PPU background**: registers $2000–$2007, VRAM with mirroring,
   per-scanline background rendering into a framebuffer, vblank NMI.
   Check: a game's title screen is visible.
4. [x] **Window**: show frames in `app/`, one per screen refresh (vsync).
5. [x] **Sprites**: OAM, OAM DMA ($4014), sprite-0 hit.
6. [x] **Controller**: $4016 reads from the keyboard. Check: games play.
7. [x] **APU**: pulse ×2, triangle, noise and DMC channels, frame counter,
   IRQs, mixer; samples at 44.1 kHz with each frame. Check: SMB's music
   rendered to a WAV file sounds right.
8. [x] **Sound**: play the samples through SDL; keep the audio buffer level
   by nudging the playback rate (vsync paces the game). Check: games sound
   right without crackles.

9. [x] **Visuals**: `--debug` shows nametables (with the scroll), pattern
   tables, palettes, sprites, the sound channels as oscilloscopes, and the
   CPU's registers and memory traffic, beside the game.
10. [x] **Pacing**: the sound card paces the game; `--vsync` makes the
    screen refresh pace it instead.

Known shortcuts, to revisit if a game needs them: OAM DMA doesn't stall the
CPU; enabling NMI during vblank doesn't raise one; the leftmost 8 pixels
are never hidden; only controller 1 is connected; the DMC doesn't steal
CPU cycles; the APU catches up once a scanline and samples without
filtering out aliasing.

Next, enhancements: not faithful to the console, but nicer to play. Each
is off unless its command-line option turns it on.

- [x] **Pause**: `--pause`; P pauses and resumes.
- **In `app/`**: fast-forward (no pacing, every few frames drawn);
  turbo buttons; gamepads (SDL's GameController); fullscreen and integer
  scaling; screenshots; cropping the 8 overscan rows top and bottom.
- **In the core**: an option to lift the 8-sprites-a-scanline limit (no
  flicker); a choice of palettes; a low-pass filter against harsh,
  aliased sound; muting single sound channels.
- **Bigger**: save states (freeze the state into a value, thaw it to
  resume), which needs an API to step and resume a machine, not just a
  list of frames; then rewind, from a ring of recent states; battery saves
  of PRG-RAM, once a mapper has them.
- **Maybe not**: CRT shaders and upscalers (darkening every other row at
  3× gets most of the look); run-ahead; Game Genie codes.

Later, maybe: PAL, more mappers.
