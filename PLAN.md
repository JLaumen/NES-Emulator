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
15. [x] **No flicker**: `--no-flicker` draws every sprite on a scanline,
    not just the first eight, so games that take turns drawing them
    don't flicker.
16. [x] **Picture**: `--fullscreen`; `--wide` for the NES's 8:7 pixels;
    `--smooth` scales the 3× picture to the window linearly (sharp
    bilinear), so pixels look even at any size without blurring.

## Next

Enhancements are not faithful to the console, but make games nicer to
play; each is off unless its command-line option turns it on.

- **Controls**: turbo buttons; gamepads (SDL's GameController); a second
  controller; keys of one's own choosing.
- **Picture**: integer scaling; screenshots (SDL saves BMPs); cropping the
  8 overscan rows top and bottom; a choice of palettes (`.pal` files).
- **Sound**: muting single channels; a volume; the console's other filters
  (a second high-pass and a 14 kHz low-pass); the channels spread across
  stereo.
- **Time**: fast-forward (no pacing, only some frames drawn); slow motion;
  frame advance while paused; a reset key; save states (freeze the state
  into a value, thaw it to resume), which needs an API to step and resume
  a machine, not just a list of frames; then rewind, from a ring of
  recent states.
- **Recording**: the game is a pure function of its inputs, so a list of
  inputs is a replay (a movie) that plays back exactly; sound to a WAV
  file; video through ffmpeg.
- **Latency**: run-ahead, after save states: run a frame or two ahead
  with the buttons held now and show that, hiding the game's own lag.
  Frame delay (sleep after each refresh, then read the buttons and run
  the frame just in time) was tried and dropped: on GNOME Wayland, in a
  window, the compositor composites about 8 ms before the refresh and
  misses some on its own, so it gained only 1–3 ms. Worth retrying in
  fullscreen or on X11.
- **Convenience**: dropping a ROM on the window loads it; the ROM's name
  in the title; ROMs inside `.zip` files.
- **Debugging**: with `--debug`, step an instruction or a scanline at a
  time, breakpoints, and a disassembly around the PC.
- **Maybe not**: CRT shaders and upscalers such as xBR (`--crt`'s scanline
  gaps get most of the look); Game Genie codes; netplay (determinism and
  save states make rollback possible, but it's a project of its own).

Accuracy and coverage, when a game needs them:

- More mappers: MMC1 (1), UxROM (2), CNROM (3) and MMC3 (4), with its
  scanline IRQ, cover most of the library; AxROM (7) next, with
  single-screen mirroring. A mapper is a cartridge's `load`, `store` and
  `resolve`, plus a hook at each scanline.
- PRG-RAM at $6000–$7FFF, with battery saves to a file beside the ROM.
- NES 2.0 headers.
- The PPU mask's greyscale and colour-emphasis bits; the sprite-overflow
  flag; open-bus reads (the last value on the bus, not 0).
- Band-limited sound synthesis (as blip_buf does), which would end the
  aliasing that averaging leaves.
- PAL, and Dendy.
- Checks: blargg's CPU, PPU and APU test ROMs, which print their result;
  nestest in CI, if its licence allows.

Known shortcuts, to revisit if a game needs them: OAM DMA doesn't stall the
CPU; enabling NMI during vblank doesn't raise one; the leftmost 8 pixels
are never hidden; only controller 1 is connected; the DMC doesn't steal
CPU cycles; the APU catches up once a scanline; averaging each sample
(a box filter) leaves some aliasing, and noise isn't averaged; unofficial
opcodes are NOPs; mid-scanline writes to the PPU take effect from the
next line.

## Optimisations

A frame takes about 5.5 ms (a third of a core at 60 Hz), so none is
needed yet; they would buy room for run-ahead and fast-forward, and fewer
garbage-collector pauses.

Measure first: a `--bench` option that runs a ROM for a few thousand
frames without a window, and prints the time a frame; then profile
(`+RTS -p`, or the eventlog with `+RTS -l`).

Doing less:

- Work for `--debug` only: the bus marks every read and write in two
  64 KB heat maps, and cools and copies both each frame; the PPU copies
  its 16 KB of memory each frame for the snapshot; the APU keeps every
  channel's level at every sample for the oscilloscopes. Do all three
  only with `--debug`.
- The PPU: each pixel of the background looks up its tile, attribute and
  pattern again; decode a tile's row once for its 8 pixels. Each pixel
  searches the line's sprites; draw the sprites into a line buffer once
  instead. Each pixel's colour goes through `resolve`; keep the palette
  where it can be read directly.
- The picture: `picture` builds its RGB bytes one at a time with `div`
  and `mod`; write them three at a time into a buffer.
- The CPU: whether an instruction takes the page-crossing cycle is a
  search of a list on every instruction; make it part of the table.
  `prgByte` takes a `mod` on every read where a mask would do.
- The APU steps the noise's shift register one tick at a time; a table of
  its 32767- and 93-step sequences would jump straight there. Its tables
  are lists indexed with `!!`; arrays would do. It builds lists of levels
  to mix at every step; unboxed values would do, and the mix itself is
  two small lookup tables (31 and 203 entries), as nesdev describes.
- The sound queue is a `Seq` of boxed `Float`s; SDL's own queue
  (`SDL_QueueAudio`) would replace it and the callback, and be simpler.
- Fast-forward needn't draw the frames it skips; the picture is already
  lazy, but the PPU still renders every line.
- Maybe not: skipping a CPU's idle loop while it waits for vblank is fast
  but needs per-game care.

Without changing the algorithms:

- GHC: try `-fllvm`, `-fspecialise-aggressively` and
  `-fexpose-all-unfoldings`; read the Core of the hot loops (CPU step, PPU
  line, APU run) for boxing and missed specialisation, and add `INLINE`,
  `SPECIALISE` or strictness where it helps.
- Allocation: the CPU's record is rebuilt with each instruction, and the
  PPU's registers and the APU are records in `STRef`s, rebuilt with each
  change; a worker-wrapped loop, unboxed mutable fields (`primitive`'s
  `MutVar`s, or small unboxed arrays) and strict, unpacked fields
  (`StrictData`) allocate less.
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
- The GPU already scales the picture to the window and draws it (SDL's
  accelerated renderer). The emulation can't move there: it is one long
  chain of steps, each needing the last, where a GPU is fast only at
  many independent ones. Only per-pixel work could: the palette lookup
  (send 61 KB of colour indices a frame, not 184 KB of RGB) and CRT
  effects in a shader. SDL2's renderer has no shaders, so that means
  OpenGL directly, for little gain; worth it only with real CRT shaders.
