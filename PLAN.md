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
17. [x] **Palettes**: `--palette file.pal` shows the colours as a `.pal`
    file has them; `PALs/` holds standard ones.
18. [x] **Afterglow**: `--ghost` blends each frame half and half with the
    last, so sprites flickered on alternate frames show steady and
    see-through, as on a TV.
19. [x] **MMC3**: mapper 4, with bank switching, mirroring, PRG RAM at
    $6000 and the scanline IRQ, counted at dot 260 of each rendered line.
    Check: Super Mario Bros. 3 plays, its status bar steady.
20. [x] **Shadow mask**: `--mask` tints the three columns of each 3×
    pixel red, green and blue, like a CRT's phosphor stripes.
21. [x] **Speed**: the PPU fetches a background tile once, not for each of
    its 8 pixels, and sprites claim their pixels over the background's;
    `picture` builds the RGB in one pass; loads are strict; the work for
    `--debug` happens only with it; the CPU's registers and the APU's
    timers are unboxed mutable variables; a loop that waits for an
    interrupt is skipped; the program asks for a bigger allocation area.
    600 frames take 0.8 s, not 2.2 s (SMB), and 0.95 s, not 2.3 s
    (SMB3), with the same picture, sound and visuals.

## Next

Enhancements are not faithful to the console, but make games nicer to
play; each is off unless its command-line option turns it on.

- **Controls**: turbo buttons; gamepads (SDL's GameController), with
  rumble as a toy; a second controller; keys of one's own choosing; the
  mouse as a Zapper light gun (Duck Hunt); an overlay of the buttons
  held, for recordings and streams.
- **Picture**: integer scaling; screenshots (SDL saves BMPs); cropping the
  8 overscan rows top and bottom; colour emphasis (with 512-colour
  `.pal` files);
  Scale3x (AdvMAME3x), which rounds diagonals from each pixel's four
  neighbours and fits the 3× picture exactly; NTSC composite colour
  bleeding (a horizontal blur of the signal, as blargg's nes_ntsc does);
  a TV bezel or vignette around the picture; a key that cycles through
  the palettes in `PALs/`, which could gain Game Boy greens, greyscale,
  sepia and Virtual Boy red.
- **Sound**: muting single channels; a volume; the console's other filters
  (a second high-pass and a 14 kHz low-pass); the channels spread across
  stereo; an NSF player (`.nsf` files are music ripped from games: code
  with an init and a play routine, called once a frame), showing the
  oscilloscopes from `--debug`; the music exported as MIDI, from each
  channel's period and volume.
- **Time**: fast-forward (no pacing, only some frames drawn); slow motion;
  frame advance while paused; a reset key; save states (freeze the state
  into a value, thaw it to resume), which needs an API to step and resume
  a machine, not just a list of frames; then rewind, from a ring of
  recent states; slots, each with a thumbnail of its frame; resuming
  where one quit, from a state saved on exit.
- **Recording**: the game is a pure function of its inputs, so a list of
  inputs is a replay (a movie) that plays back exactly; sound to a WAV
  file; video through ffmpeg; an instant replay, saving the last 30
  seconds as a GIF from a ring of frames; TAS tools: editing a movie's
  inputs frame by frame, with save states to branch from.
- **Toys**: `--widescreen`, drawing the background wider than 256 pixels
  from the nametables, which hold more of the level than is shown
  (sprites there aren't drawn, and some games leave junk there); keys
  that hide the background or the sprites; an auto-map, pasting each
  frame's background into a growing picture of the level at its scroll
  (status bars need leaving out, e.g. the rows above a split), saved as a
  BMP; ghost racing, a recorded run played alongside and blended in
  translucently; a cheat finder: search RAM for a value that changed as
  the lives or health did, then hold it fixed.
- **Latency**: run-ahead, after save states: run a frame or two ahead
  with the buttons held now and show that, hiding the game's own lag.
  Frame delay (sleep after each refresh, then read the buttons and run
  the frame just in time) was tried and dropped: on GNOME Wayland, in a
  window, the compositor composites about 8 ms before the refresh and
  misses some on its own, so it gained only 1–3 ms. Worth retrying in
  fullscreen or on X11.
- **Convenience**: dropping a ROM on the window loads it; the ROM's name
  in the title; ROMs inside `.zip` files; a menu of the ROMs in a
  folder; a configuration file for the options; brief on-screen messages
  ("State saved"); pausing when the window loses focus; hiding the mouse
  in fullscreen; a frame rate and speed overlay.
- **Debugging**: with `--debug`, step an instruction or a scanline at a
  time, breakpoints (on the PC, or on reads and writes of an address),
  and a disassembly around the PC; a memory viewer and editor; an event
  view marking where on the screen the CPU wrote each PPU register (to
  see split scrolls); the pattern tables saved as a PNG sprite sheet; a
  code/data log of which ROM bytes ran as code and which were read as
  data.
- **Maybe not**: CRT shaders, screen curvature, bloom and upscalers such
  as xBR (the CPU can't afford them; `--crt`'s scanline gaps get most of
  the look); sprite motion trails and hitbox outlines; HD texture packs;
  Game Genie codes; RetroAchievements; netplay (determinism and save
  states make rollback possible, but it's a project of its own); a web
  build (GHC's WebAssembly backend with SDL through Emscripten).

Accuracy and coverage, when a game needs them:

- More mappers: MMC1 (1), UxROM (2) and CNROM (3) cover most of the
  rest of the library; AxROM (7) next, with single-screen mirroring. A
  mapper sets the bank tables in `Mapper` when its registers are
  written.
- Battery saves: PRG RAM to a file beside the ROM.
- NES 2.0 headers.
- The PPU mask's greyscale and colour-emphasis bits; the sprite-overflow
  flag; open-bus reads (the last value on the bus, not 0).
- Band-limited sound synthesis (as blip_buf does), which would end the
  aliasing that averaging leaves.
- PAL, and Dendy.
- Checks: blargg's CPU, PPU and APU test ROMs, which print their result;
  nestest in CI, if its licence allows; golden frames: run a ROM headless
  for some frames with set inputs and compare a hash of the picture.

Known shortcuts, to revisit if a game needs them: OAM DMA doesn't stall the
CPU; enabling NMI during vblank doesn't raise one; the leftmost 8 pixels
are never hidden; only controller 1 is connected; the DMC doesn't steal
CPU cycles; the APU catches up once a scanline; averaging each sample
(a box filter) leaves some aliasing, and noise isn't averaged; unofficial
opcodes are NOPs; mid-scanline writes to the PPU take effect from the
next line; MMC3 counts every rendered line at dot 260, whichever pattern
table the sprites use.

## Optimisations

A frame takes about 1.5 ms (a tenth of a core at 60 Hz), 6 ms with
`--debug`, so more speed isn't needed; it would only buy room for
run-ahead and fast-forward.

Measured with headless loops over 600 frames of Super Mario Bros. and
Super Mario Bros. 3 (2.2 s and 2.3 s at first, 0.8 s and 0.95 s now; with
`--debug`, 8.2 ms a frame at first), checking that the picture, sound
and visuals stay exactly the same, and with GHC's profiler (build with
`--enable-profiling`). Both games spend their time in the same places.
Done: a background tile fetched once for its 8 pixels; sprites drawn
over the line's background, not searched for at each pixel; `picture`
written in one pass; strict loads; the noise and DMC stepped with a
loop, not `iterate`; `-A16m`; the heat maps and the channels' levels
kept only with `--debug` (7%); the APU's timers and positions in unboxed
mutable variables, not rebuilt records (9%); the CPU's registers likewise
(4–7%); a jump or branch to itself, which waits for an interrupt,
skipped ahead by whole turns, exactly as if run (15% on SMB, which waits
so; nothing on SMB3, which doesn't); in the visuals, a nametable
that mirrors another copied, not drawn again, and tiles drawn without a
`Maybe` a pixel.

Tried, and worth 2% or less, so dropped: unchecked array indexing,
`INLINE` pragmas, `-fspecialise-aggressively` with
`-fexpose-all-unfoldings`, strict fields in the CPU's opcode table, a
strict `address` in the CPU, a list-free `mix`, list-free frame-counter
steps, leaving silent pulses out of the APU's stops, a lighter sprite
search, reading the mirroring once a line, list-free colour sums in the
visuals, the page-crossing cycle as a flag in the opcode table,
`StrictData`, inlining the CPU's step into its loop (2%), `-A64m` and
the non-moving collector (the longest pause is already 0.2 ms). Measured and not worth doing: a table for the noise's shift
register (2% at most, by skipping it); SDL's own audio queue in place of
the `Seq` (which costs 0.03 ms a frame); the visuals on another core
(shown a frame late, for time that fits in a frame already); unboxed
mutable PPU registers (their code takes 0.4% of the time);
unchecked reads of the program banks (3%), or none for NROM (4%, NROM
only).

More cores: the whole program uses 14% of a core (SDL's dummy drivers,
both games): 1.7 ms of emulation and 0.7 ms of the window's work a
frame. More cores only shorten a frame's wall time, which waits for the
sound card or the refresh anyway; they'd matter only for fast-forward.
The emulation on a thread of its own could hide only the 0.7 ms, and
would show the buttons a frame late. The APU on another core could
take at most its 15%, but the CPU still needs its length counters
($4015) and IRQs in step. The PPU's lines are 40% of a frame, but the
CPU reads sprite-0 hits and MMC3 counts lines as they're drawn, and
MMC3 games switch pattern banks mid-frame, so drawing later needs a
snapshot of all that for every line.

Fast-forward, when it comes, can skip drawing the frames it doesn't
show: up to 40% of each, less the sprite-0 checks games still need.

`-fllvm` makes it 10% faster, but GHC 9.14 supports LLVM only up to 20
(LLVM 22 works, with a warning), and every build, CI's too, would need
LLVM; the README mentions it instead.

The GPU already scales the picture to the window and draws it. The
emulation can't move there: it is one long chain of steps, each needing
the last, where a GPU is fast only at many independent ones.
