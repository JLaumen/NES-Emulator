{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoFieldSelectors #-}

-- | A picture of what the emulator is doing: the nametables with the part
-- on screen outlined, the pattern tables, palettes and sprites; the sound
-- channels as oscilloscopes; and the CPU's registers and memory traffic.
module Visualise (Snapshot (..), width, height, picture) where

import CPU (CPU (..))
import Control.Monad (forM_, when, zipWithM_)
import Control.Monad.ST (ST, runST)
import Data.Array.Unboxed (UArray, listArray, (!))
import Data.Bits (shiftL, shiftR, testBit, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString.Internal qualified as BS
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Vector.Storable qualified as V
import Data.Vector.Storable.Mutable qualified as MV
import Data.Word (Word16, Word32, Word8)
import PPU (Video (..))
import PPU qualified
import Text.Printf (printf)

data Snapshot = Snapshot
  { cpu :: CPU,
    video :: Video,
    -- | How recently the CPU read and wrote each address, from 255 (just
    -- now) down to 0.
    readHeat, writeHeat :: UArray Word16 Word8,
    -- | The frame's samples, and the channels' levels at each.
    sound :: [Float],
    voices :: [[Int]],
    palette :: PPU.Palette
  }

width, height :: Int
width = 1072
height = 860

-- | Colours as 0x00RRGGBB.
type Color = Word32

background, panel, line, label, unlit, bright, highlight, readColor, writeColor :: Color
background = 0x0E1016
panel = 0x171A23
line = 0x2A2F3D
label = 0x7C8599
unlit = 0x3A4050
bright = 0xE6E9EF
highlight = 0xFFD166
readColor = 0x3FA9F5
writeColor = 0xFF7A45

-- | The picture: 'width'×'height' pixels of 4 bytes, each a 'Color' in
-- the machine's byte order.
picture :: Snapshot -> ByteString
picture s = runST $ do
  canvas <- MV.replicate (width * height) background
  let c = Canvas canvas
  -- The 32 palette entries (8 palettes of 4) in RGB.
  let colors = listArray (0, 31) [color s.palette s.video p i | p <- [0 .. 7], i <- [0 .. 3]]
  nametables c s.video colors 16 16
  sound c s 16 544
  patternTables c s.video colors 544 16
  palettes c colors 544 320
  sprites c s.video colors 544 392
  processor c s 544 600
  pixels <- V.unsafeCast <$> V.unsafeFreeze canvas
  pure (BS.BS (fst (V.unsafeToForeignPtr0 pixels)) (V.length pixels))

-- * Sections, each drawn below a title at the given position

nametables :: Canvas s -> Video -> UArray Int Color -> Int -> Int -> ST s ()
nametables c v colors x y = do
  title c x y "NAMETABLES"
  frame c x (y + 24) 512 480
  let base n = 0x2000 + 0x400 * fromIntegral n
      left n = x + n `mod` 2 * 256
      top n = y + 24 + n `div` 2 * 240
      same m n = all (\i -> v.memory ! (base m + i) == v.memory ! (base n + i)) [0 .. 0x3FF]
  forM_ [0 .. 3 :: Int] $ \n -> case filter (`same` n) [0 .. n - 1] of
    -- Mirroring makes most nametables a copy of another.
    m : _ -> copy c (left m) (top m) (left n) (top n) 256 240
    [] -> forM_ [0 .. 29] $ \row -> forM_ [0 .. 31] $ \col -> do
      let at = fromIntegral (row * 32 + col)
          tile = v.memory ! (base n + at)
          attribute = v.memory ! (base n + 0x3C0 + fromIntegral (row `div` 4 * 8 + col `div` 4))
          palette = fromIntegral (attribute `shiftR` ((row .&. 2) `shiftL` 1 .|. col .&. 2)) .&. 3
          table = if testBit v.ctrl 4 then 0x1000 else 0
      drawTile c v (left n + col * 8) (top n + row * 8) 1 (table + fromIntegral tile * 16) False False False $
        \p -> colors ! (palette * 4 + p)
  -- Outline the part on screen, line by line, so that split screens show
  -- each part where it is.
  let at line' = (v.scrollX ! line' `mod` 512, v.scrollY ! line' `mod` 480)
      across (sx, sy) = forM_ [0 .. 255] $ \dx -> pixel c (x + (sx + dx) `mod` 512) (y + 24 + sy) highlight
  forM_ [0 .. 239] $ \n -> do
    let (sx, sy) = at n
    pixel c (x + sx) (y + 24 + sy) highlight
    pixel c (x + (sx + 255) `mod` 512) (y + 24 + sy) highlight
    let (px, py) = at (n - 1)
    when (n == 0 || sx /= px || sy /= (py + 1) `mod` 480) $ do
      across (sx, sy)
      when (n > 0) (across (px, py))
    when (n == 239) (across (sx, sy))

patternTables :: Canvas s -> Video -> UArray Int Color -> Int -> Int -> ST s ()
patternTables c v colors x y = do
  title c x y "PATTERN TABLES"
  frame c x (y + 24) 512 256
  forM_ [0 .. 1] $ \t -> forM_ [0 .. 255] $ \i -> do
    -- Each table in the colours of whatever it's used for.
    let palette = if fromEnum (testBit v.ctrl 3) == t then 4 else 0
    drawTile c v (x + t * 256 + i `mod` 16 * 16) (y + 24 + i `div` 16 * 16) 2 (fromIntegral (t * 0x1000 + i * 16)) False False False $
      \p -> colors ! (palette * 4 + p)

palettes :: Canvas s -> UArray Int Color -> Int -> Int -> ST s ()
palettes c colors x y = do
  title c x y "PALETTES"
  forM_ [0 .. 31] $ \i -> rect c (x + i `div` 4 * 64 + i `mod` 4 * 14) (y + 24) 14 24 (colors ! i)

sprites :: Canvas s -> Video -> UArray Int Color -> Int -> Int -> ST s ()
sprites c v colors x y = do
  title c x y "SPRITES"
  forM_ [0 .. 63] $ \i -> do
    let cx = x + i `mod` 16 * 32
        cy = y + 24 + i `div` 16 * 40
        top = v.oam ! (4 * i)
        tile = fromIntegral (v.oam ! (4 * i + 1)) :: Word16
        attributes = v.oam ! (4 * i + 2)
        tall = testBit v.ctrl 5
        flipH = testBit attributes 6
        flipV = testBit attributes 7
        palette = 4 + fromIntegral attributes .&. 3
        -- Sprites below the picture are hidden; show them faded.
        shade = if top >= 0xEF then \col -> add (scale 77 col) (scale 178 panel) else id
        -- The pattern addresses of the sprite's tiles, top to bottom.
        tiles
          | tall = [(0x1000 * (tile .&. 1) + (tile .&. 0xFE + k) * 16, fromIntegral k) | k <- [0, 1]]
          | otherwise = [((if testBit v.ctrl 3 then 0x1000 else 0) + tile * 16, 0 :: Int)]
    rect c cx cy 30 38 panel
    forM_ tiles $ \(t, k) -> do
      let dy = (if flipV && tall then 1 - k else k) * 16
          sy = cy + if tall then 3 else 11
      drawTile c v (cx + 7) (sy + dy) 2 t flipH flipV True $ \p ->
        shade (colors ! (palette * 4 + p))

sound :: Canvas s -> Snapshot -> Int -> Int -> ST s ()
sound c s x y = do
  title c x y "SOUND"
  let channel k full = [fromIntegral (levels !! k) / full | levels <- s.voices]
      scopes =
        [ ("PULSE 1", 0xFF6B6B, True, channel 0 15),
          ("PULSE 2", 0xFFB86B, True, channel 1 15),
          ("TRIANGLE", 0x6BCB77, True, channel 2 15),
          ("NOISE", 0x4D96FF, False, channel 3 15),
          ("DMC", 0xB07CFF, True, channel 4 127),
          ("MIX", bright, False, [0.5 + 1.2 * realToFrac v | v <- s.sound])
        ]
  zipWithM_ (\k (name, col, triggered, values) -> scope c x (y + 24 + k * 46) name col triggered values) [0 ..] scopes

-- | A channel's levels (0–1) over the frame. Periodic waves start at a
-- rising edge, as on an oscilloscope, so that they stand still.
scope :: Canvas s -> Int -> Int -> String -> Color -> Bool -> [Double] -> ST s ()
scope c x y name col triggered values = do
  text c x (y + 13) col name
  frame c (x + 104) y w h
  forM_ (zip [0 ..] (zip ys (drop 1 ys))) $ \(px, (a, b)) ->
    forM_ [min a b .. max a b] $ \py -> pixel c (x + 104 + px) py col
  where
    (w, h) = (408, 40)
    n = length values
    samples = listArray (0, max 0 (n - 1)) values :: UArray Int Double
    lo = minimum (1 : values)
    hi = maximum (0 : values)
    mid = (lo + hi) / 2
    span' = if triggered then n `div` 2 else n
    start
      | not triggered || hi == lo = 0
      | otherwise = fromMaybe 0 (find (\i -> samples ! (i - 1) < mid && samples ! i >= mid) [1 .. n - span' - 1])
    ys
      | n == 0 = []
      | otherwise =
          [ y + h - 3 - round (max 0 (min 1 (samples ! (start + px * span' `div` w))) * fromIntegral (h - 6))
          | px <- [0 .. w - 1]
          ]

processor :: Canvas s -> Snapshot -> Int -> Int -> ST s ()
processor c s x y = do
  title c x y "CPU"
  text c (x + 380) y readColor "READ"
  text c (x + 440) y writeColor "WRITE"
  let registers =
        [ ("PC", printf "%04X" s.cpu.pc),
          ("A", printf "%02X" s.cpu.a),
          ("X", printf "%02X" s.cpu.x),
          ("Y", printf "%02X" s.cpu.y),
          ("SP", printf "%02X" s.cpu.sp)
        ]
      columns = scanl (+) x [12 * (length name + length value) + 24 | (name, value) <- registers]
  forM_ (zip columns registers) $ \(cx, (name, value)) -> do
    text c cx (y + 24) label name
    text c (cx + 12 * length name + 6) (y + 24) bright value
  -- The status flags, lit when set.
  forM_ (zip [0 ..] "NV-BDIZC") $ \(k, flag) ->
    text c (x + 416 + k * 12) (y + 24) (if testBit s.cpu.p (7 - k) then highlight else unlit) [flag]
  -- Every address from $0000 to $FFFF, 512 to a row: RAM at the top,
  -- the program at the bottom.
  frame c x (y + 48) 512 128
  forM_ [0 .. 0xFFFF :: Int] $ \a -> do
    let r = fromIntegral (s.readHeat ! fromIntegral a)
        w = fromIntegral (s.writeHeat ! fromIntegral a)
    when (r > 0 || w > 0)
      $ pixel c (x + a `mod` 512) (y + 48 + a `div` 512)
      $ add panel (add (scale r readColor) (scale w writeColor))

-- * Drawing

newtype Canvas s = Canvas (MV.MVector s Color)

{-# INLINE pixel #-}
pixel :: Canvas s -> Int -> Int -> Color -> ST s ()
pixel (Canvas v) x y col = when (x >= 0 && x < width && y >= 0 && y < height) $ MV.unsafeWrite v (y * width + x) col

rect :: Canvas s -> Int -> Int -> Int -> Int -> Color -> ST s ()
rect (Canvas v) x y w h col = forM_ [max 0 y .. min height (y + h) - 1] $ \py ->
  MV.set (MV.slice (py * width + x') (max 0 (min width (x + w) - x')) v) col
  where
    x' = max 0 x

-- | Copy a w×h block of the canvas from one place to another.
copy :: Canvas s -> Int -> Int -> Int -> Int -> Int -> Int -> ST s ()
copy (Canvas v) fromX fromY toX toY w h = forM_ [0 .. h - 1] $ \row ->
  MV.copy (MV.slice ((toY + row) * width + toX) w v) (MV.slice ((fromY + row) * width + fromX) w v)

-- | A panel to draw on, with a thin border.
frame :: Canvas s -> Int -> Int -> Int -> Int -> ST s ()
frame c x y w h = rect c (x - 1) (y - 1) (w + 2) (h + 2) line >> rect c x y w h panel

title :: Canvas s -> Int -> Int -> String -> ST s ()
title c x y = text c x y label

-- | Text in a 5×7 pixel font, drawn twice as large.
text :: Canvas s -> Int -> Int -> Color -> String -> ST s ()
text c x y col str = forM_ (zip [0 ..] str) $ \(k, ch) ->
  forM_ (zip [0 ..] (glyph ch)) $ \(r, bits) -> forM_ [0 .. 4] $ \b ->
    when (testBit bits (4 - b)) $ rect c (x + k * 12 + b * 2) (y + r * 2) 2 2 col

-- | One 8×8 tile from the pattern tables at a scale, its pixels (0–3)
-- coloured by the given function, or left out where 0 if see-through.
{-# INLINE drawTile #-}
drawTile :: Canvas s -> Video -> Int -> Int -> Int -> Word16 -> Bool -> Bool -> Bool -> (Int -> Color) -> ST s ()
drawTile c v x y size addr flipH flipV seeThrough colorOf = forM_ [0 .. 7] $ \row -> do
  let lo = v.memory ! (addr + fromIntegral row)
      hi = v.memory ! (addr + fromIntegral row + 8)
  forM_ [0 .. 7] $ \col -> do
    let bit b = fromEnum (testBit b (7 - col))
        dx = if flipH then 7 - col else col
        dy = if flipV then 7 - row else row
        p = bit lo .|. bit hi `shiftL` 1
    when (p /= 0 || not seeThrough) $
      (if size == 1 then pixel c (x + dx) (y + dy) else rect c (x + dx * size) (y + dy * size) size size) (colorOf p)

-- | Entry i (0–3) of palette p (0–3 background, 4–7 sprites), in RGB.
color :: PPU.Palette -> Video -> Int -> Int -> Color
color colors v p i = sum [fromIntegral (colors ! (3 * index + k)) `shiftL` (16 - 8 * k) | k <- [0 .. 2]]
  where
    index = fromIntegral (v.memory ! (0x3F00 + fromIntegral (if i == 0 then 0 else p * 4 + i)) .&. 0x3F)

-- | Each channel times f/255.
scale :: Word32 -> Color -> Color
scale f col = sum [((col `shiftR` s .&. 255) * f `div` 255) `shiftL` s | s <- [0, 8, 16]]

-- | Add colours, channel by channel, up to white.
add :: Color -> Color -> Color
add a b = sum [min 255 ((a `shiftR` s .&. 255) + (b `shiftR` s .&. 255)) `shiftL` s | s <- [0, 8, 16]]

-- | The rows of a character, 5 bits each.
glyph :: Char -> [Word8]
glyph ch = fromMaybe (replicate 7 0) (lookup ch font)

font :: [(Char, [Word8])]
font =
  [ ('0', [0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E]),
    ('1', [0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E]),
    ('2', [0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F]),
    ('3', [0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E]),
    ('4', [0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02]),
    ('5', [0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E]),
    ('6', [0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E]),
    ('7', [0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08]),
    ('8', [0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E]),
    ('9', [0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C]),
    ('A', [0x0E, 0x11, 0x11, 0x11, 0x1F, 0x11, 0x11]),
    ('B', [0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E]),
    ('C', [0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E]),
    ('D', [0x1C, 0x12, 0x11, 0x11, 0x11, 0x12, 0x1C]),
    ('E', [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F]),
    ('F', [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10]),
    ('G', [0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F]),
    ('H', [0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11]),
    ('I', [0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E]),
    ('J', [0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0C]),
    ('K', [0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11]),
    ('L', [0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F]),
    ('M', [0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11]),
    ('N', [0x11, 0x11, 0x19, 0x15, 0x13, 0x11, 0x11]),
    ('O', [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E]),
    ('P', [0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10]),
    ('Q', [0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D]),
    ('R', [0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11]),
    ('S', [0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E]),
    ('T', [0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04]),
    ('U', [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E]),
    ('V', [0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04]),
    ('W', [0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0A]),
    ('X', [0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11]),
    ('Y', [0x11, 0x11, 0x11, 0x0A, 0x04, 0x04, 0x04]),
    ('Z', [0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F]),
    ('-', [0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00])
  ]
