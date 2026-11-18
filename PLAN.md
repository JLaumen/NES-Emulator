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
   by nudging the console's speed (vsync paces the game). Check: games
   sound right without crackles.

9. [x] **Visuals**: `--debug` shows nametables (with the scroll), pattern
   tables, palettes, sprites, the sound channels as oscilloscopes, and the
   CPU's registers and memory traffic, beside the game.
10. [x] **Pacing**: the sound card paces the game; `--vsync` makes the
    screen refresh pace it instead.

11. [x] **Pause**: `--pause`; Escape pauses and resumes.
12. [x] **Any refresh rate**: `--vsync` runs the frames due each refresh,
    so the game keeps its speed at 120 or 144 Hz too. The console's speed
    is an input, so the APU makes exactly the sound needed, unresampled.
13. [x] **Less aliasing**: each sample averages the mix over its cycles,
    instead of taking the level at one moment (10 dB less on a 5.3 kHz
    pulse).
14. [x] **CRT look**: `--crt` darkens the bottom of every three rows of
    the 3× picture, as gaps between scanlines.

## Next

Enhancements are not faithful to the console, but make games nicer to
play; each is off unless its command-line option turns it on.

- **Controls**: turbo buttons; gamepads (SDL's GameController); a second
  controller.
- **Picture**: fullscreen and integer scaling; screenshots; cropping the 8
  overscan rows top and bottom; lifting the 8-sprites-a-scanline limit (no
  flicker); a choice of palettes.
- **Sound**: muting single channels.
- **Time**: fast-forward (no pacing, only some frames drawn); save states
  (freeze the state into a value, thaw it to resume), which needs an API
  to step and resume a machine, not just a list of frames; then rewind,
  from a ring of recent states.
- **Latency**: run-ahead, after save states: run a frame or two ahead
  with the buttons held now and show that, hiding the game's own lag.
  Frame delay (sleep after each refresh, then read the buttons and run
  the frame just in time) was tried and dropped: on GNOME Wayland, in a
  window, the compositor composites about 8 ms before the refresh and
  misses some on its own, so it gained only 1–3 ms. Worth retrying in
  fullscreen or on X11.
- **Maybe not**: CRT shaders and upscalers (`--crt`'s scanline gaps get
  most of the look); Game Genie codes.

Accuracy and coverage, when a game needs them: the known shortcuts below;
band-limited sound synthesis (as blip_buf does), which would end the
aliasing that averaging leaves; more mappers, with battery saves of
PRG-RAM; PAL.

Known shortcuts, to revisit if a game needs them: OAM DMA doesn't stall the
CPU; enabling NMI during vblank doesn't raise one; the leftmost 8 pixels
are never hidden; only controller 1 is connected; the DMC doesn't steal
CPU cycles; the APU catches up once a scanline; averaging each sample
(a box filter) leaves some aliasing, and noise isn't averaged.

## Optimisations

A frame takes about 5.5 ms (a third of a core at 60 Hz), so none is
needed yet; they would buy room for run-ahead and fast-forward, and fewer
garbage-collector pauses. Profile first (`+RTS -p`, or the eventlog).

Doing less:

- The bus marks every read and write in two 64 KB heat maps, and cools
  and copies both each frame, all for `--debug`; do it only with
  `--debug`.
- The APU steps the noise's shift register one tick at a time; a table of
  its 32767- and 93-step sequences would jump straight there. Its tables
  are lists indexed with `!!`, and it builds lists of levels to mix at
  every step; arrays and unboxed values would do.
- The PPU could decode a tile's row once for its 8 pixels, not per pixel.
- The sound queue is a `Seq` of boxed `Float`s; a ring buffer of unboxed
  ones would do.
- Maybe not: skipping a CPU's idle loop while it waits for vblank is fast
  but needs per-game care.

Without changing the algorithms:

- GHC: try `-fllvm`; read the Core of the hot loops (CPU step, PPU line,
  APU run) for boxing and missed specialisation, and add `INLINE`,
  `SPECIALISE` or strictness where it helps.
- The runtime: a larger allocation area (`-with-rtsopts=-A64m`) means
  fewer collections; the non-moving collector shortens pauses, which can
  cost a refresh.
- More cores (the program is already `-threaded`):
  - Draw the `--debug` visuals on another core; they're a pure value
    of each frame.
  - Run the emulation on its own thread, a frame ahead of the one being
    shown, handing frames to the SDL thread through a channel.
  - Run the APU a frame behind on another core, from a log of its register
    writes and their cycles; the CPU would still need the frame IRQ and
    the length counters ($4015) in step.
  - Draw the PPU's pixels on another core from a log of its register
    writes, keeping on the CPU's side only what it can observe (status,
    sprite-0 hit, which needs some pixels after all).
  - With run-ahead, run the frames ahead on another core alongside the
    real one.
