{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoFieldSelectors #-}

-- | The picture processing unit: its registers, its memory, and rendering
-- one scanline at a time.
module PPU (PPU, new, readRegister, writeRegister, startLine, endLine, picture) where

import Cartridge (Cartridge (..), Mirroring (..))
import Control.Monad (forM, forM_, when)
import Control.Monad.ST (ST)
import Data.Array.ST (STUArray, freeze, newArray, newListArray, readArray, writeArray)
import Data.Array.Unboxed (UArray, listArray, (!))
import Data.Bits (clearBit, complement, setBit, shiftL, shiftR, testBit, xor, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.STRef (STRef, modifySTRef', newSTRef, readSTRef, writeSTRef)
import Data.Word (Word16, Word32, Word8)

data Registers = Registers
  { ctrl, mask, status :: !Word8,
    -- | The VRAM address (v) and the address that scroll writes build up
    -- (t). Both hold coarse x and y scroll in tiles, the nametable, and
    -- fine y scroll in pixels.
    v, t :: !Word16,
    fineX :: !Word8,
    -- | Whether the next $2005/$2006 write is the second of a pair.
    latch :: !Bool,
    -- | $2007 reads lag one byte behind, except for the palette.
    buffer :: !Word8,
    oamAddr :: !Word8
  }

data PPU s = PPU
  { regs :: STRef s Registers,
    -- | The 16 KiB PPU address space, of which only the pattern tables, two
    -- nametables and the palette exist; see 'resolve'.
    memory :: STUArray s Word16 Word8,
    -- | Object attribute memory: 64 sprites of 4 bytes (y, tile,
    -- attributes, x).
    oam :: STUArray s Int Word8,
    -- | Palette indices of the picture being drawn, row by row.
    pixels :: STUArray s Int Word8,
    mirroring :: Mirroring
  }

new :: Cartridge -> ST s (PPU s)
new cart = do
  regs <- newSTRef (Registers 0 0 0 0 0 0 False 0 0)
  memory <- newListArray (0, 0x3FFF) (BS.unpack cart.chr ++ repeat 0)
  oam <- newArray (0, 255) 0
  pixels <- newArray (0, 256 * 240 - 1) 0
  pure PPU {regs, memory, oam, pixels, mirroring = cart.mirroring}

-- | Map an address onto the memory that backs it: nametables onto two
-- through mirroring, and the background colour of the sprite palettes onto
-- that of the background palettes.
resolve :: Mirroring -> Word16 -> Word16
resolve mirroring addr
  | a < 0x2000 = a
  | a < 0x3F00 = case mirroring of
      Vertical -> 0x2000 .|. a .&. 0x7FF
      Horizontal -> 0x2000 .|. a .&. 0x3FF .|. (a .&. 0x800) `shiftR` 1
  | a .&. 0x13 == 0x10 = 0x3F00 .|. a .&. 0x0F
  | otherwise = 0x3F00 .|. a .&. 0x1F
  where
    a = addr .&. 0x3FFF

peek :: PPU s -> Word16 -> ST s Word8
peek ppu = readArray ppu.memory . resolve ppu.mirroring

poke :: PPU s -> Word16 -> Word8 -> ST s ()
poke ppu = writeArray ppu.memory . resolve ppu.mirroring

-- * CPU registers $2000–$2007 (mirrored up to $3FFF)

readRegister :: PPU s -> Word16 -> ST s Word8
readRegister ppu addr = do
  r <- readSTRef ppu.regs
  case addr .&. 7 of
    2 -> do
      writeSTRef ppu.regs r {status = clearBit r.status 7, latch = False}
      pure r.status
    4 -> readArray ppu.oam (fromIntegral r.oamAddr)
    7 -> do
      value <- peek ppu r.v
      writeSTRef ppu.regs r {v = r.v + increment r, buffer = value}
      pure (if r.v .&. 0x3FFF >= 0x3F00 then value else r.buffer)
    _ -> pure 0

writeRegister :: PPU s -> Word16 -> Word8 -> ST s ()
writeRegister ppu addr value = do
  r <- readSTRef ppu.regs
  let set = writeSTRef ppu.regs
      w = fromIntegral value :: Word16
  case addr .&. 7 of
    0 -> set r {ctrl = value, t = r.t .&. 0xF3FF .|. (w .&. 3) `shiftL` 10}
    1 -> set r {mask = value}
    3 -> set r {oamAddr = value}
    4 -> do
      writeArray ppu.oam (fromIntegral r.oamAddr) value
      set r {oamAddr = r.oamAddr + 1}
    5
      | r.latch -> set r {t = r.t .&. 0x8C1F .|. (w .&. 7) `shiftL` 12 .|. (w .&. 0xF8) `shiftL` 2, latch = False}
      | otherwise -> set r {t = r.t .&. 0xFFE0 .|. w `shiftR` 3, fineX = value .&. 7, latch = True}
    6
      | r.latch -> let t = r.t .&. 0xFF00 .|. w in set r {t, v = t, latch = False}
      | otherwise -> set r {t = r.t .&. 0x00FF .|. (w .&. 0x3F) `shiftL` 8, latch = True}
    7 -> do
      poke ppu r.v value
      set r {v = r.v + increment r}
    _ -> pure ()

-- | How far $2007 accesses move the VRAM address: across or down.
increment :: Registers -> Word16
increment r = if testBit r.ctrl 2 then 32 else 1

-- * Scanlines

-- | Start a scanline: -1 is the pre-render line, 0–239 are visible, and
-- vblank starts at 241. Returns whether to raise an NMI.
startLine :: PPU s -> Int -> ST s Bool
startLine ppu line
  | line == -1 = False <$ modifySTRef' ppu.regs (\r -> r {status = 0})
  | line < 240 = False <$ render ppu line
  | line == 241 = do
      r <- readSTRef ppu.regs
      writeSTRef ppu.regs r {status = setBit r.status 7}
      pure (testBit r.ctrl 7)
  | otherwise = pure False

-- | End a scanline, after the CPU has run alongside it: move v down a line
-- and back to the left edge, or for the pre-render line, to the top left.
endLine :: PPU s -> Int -> ST s ()
endLine ppu line = modifySTRef' ppu.regs end
  where
    end r
      | r.mask .&. 0x18 == 0 = r
      | line == -1 = r {v = r.t}
      | line < 240 = r {v = nextLine r.v .&. complement 0x041F .|. r.t .&. 0x041F}
      | otherwise = r

-- | Move v down one pixel row, from the bottom of a nametable (row 29)
-- into the one below it.
nextLine :: Word16 -> Word16
nextLine v
  | v .&. 0x7000 /= 0x7000 = v + 0x1000
  | otherwise = case (v .&. 0x03E0) `shiftR` 5 of
      29 -> v' .&. complement 0x03E0 `xor` 0x0800
      31 -> v' .&. complement 0x03E0
      _ -> v' + 0x20
  where
    v' = v .&. 0x0FFF

render :: PPU s -> Int -> ST s ()
render ppu y = do
  r <- readSTRef ppu.regs
  sprites <- if testBit r.mask 4 then spritesOn ppu r y else pure []
  forM_ [0 .. 255] $ \x -> do
    back <- if testBit r.mask 3 then background ppu r x else pure 0
    color <- case [(s, c) | s <- sprites, let c = spritePixel s x, c /= 0] of
      (s, c) : _ -> do
        -- Games time mid-frame effects, such as a fixed status bar, by
        -- when sprite 0 first overlaps the background.
        when (s.index == 0 && back /= 0 && x < 255) $
          modifySTRef' ppu.regs (\r' -> r' {status = setBit r'.status 6})
        pure (if back /= 0 && testBit s.attributes 5 then back else 0x10 .|. c)
      [] -> pure back
    peek ppu (0x3F00 + color) >>= writeArray ppu.pixels (y * 256 + x)

-- | The background's palette entry (0–15) at pixel x of the row that v
-- points at.
background :: PPU s -> Registers -> Int -> ST s Word16
background ppu r x = do
  tile <- peek ppu (0x2000 .|. nametable .|. row `shiftL` 5 .|. column)
  attribute <- peek ppu (0x23C0 .|. nametable .|. (row `shiftR` 2) `shiftL` 3 .|. column `shiftR` 2)
  planes <- patternRow ppu ((if testBit r.ctrl 4 then 0x1000 else 0) + fromIntegral tile * 16 + r.v `shiftR` 12)
  let palette = fromIntegral (attribute `shiftR` fromIntegral ((row .&. 2) `shiftL` 1 .|. column .&. 2)) .&. 3
  pure (shade palette planes (fromIntegral (px .&. 7)))
  where
    px = (r.v .&. 0x1F) * 8 + fromIntegral r.fineX + fromIntegral x
    -- Past the right edge of a nametable lies the next one across.
    nametable = r.v .&. 0x0C00 `xor` (px .&. 0x100) `shiftL` 2
    column = (px `shiftR` 3) .&. 0x1F
    row = (r.v `shiftR` 5) .&. 0x1F

data Sprite = Sprite
  { index, x :: Int,
    -- | Palette (bits 0–1), behind the background (5), flipped
    -- horizontally (6) and vertically (7).
    attributes :: Word8,
    -- | The bit planes of the sprite's row on this scanline.
    planes :: (Word8, Word8)
  }

-- | The first eight sprites on a scanline, front to back.
spritesOn :: PPU s -> Registers -> Int -> ST s [Sprite]
spritesOn ppu r y = do
  rows <- forM [0 .. 63] $ \i -> (i,) . (\top -> y - fromIntegral top - 1) <$> readArray ppu.oam (4 * i)
  forM (take 8 [(i, row) | (i, row) <- rows, row >= 0, row < height]) $ \(i, row) -> do
    tile <- fromIntegral <$> readArray ppu.oam (4 * i + 1)
    attributes <- readArray ppu.oam (4 * i + 2)
    x <- readArray ppu.oam (4 * i + 3)
    let flipped = fromIntegral (if testBit attributes 7 then height - 1 - row else row)
        (table, first)
          | height == 8 = (if testBit r.ctrl 3 then 0x1000 else 0, tile)
          | otherwise = (0x1000 * (tile .&. 1), tile .&. 0xFE)
    -- Rows 8–15 of a tall sprite come from the tile after the first.
    planes <- patternRow ppu (table + first * 16 + flipped + flipped .&. 8)
    pure Sprite {index = i, x = fromIntegral x, attributes, planes}
  where
    height = if testBit r.ctrl 5 then 16 else 8

-- | A sprite's palette entry (0–15) at pixel x of the scanline.
spritePixel :: Sprite -> Int -> Word16
spritePixel s x
  | dx < 0 || dx > 7 = 0
  | otherwise = shade (fromIntegral s.attributes .&. 3) s.planes (if testBit s.attributes 6 then 7 - dx else dx)
  where
    dx = x - s.x

-- | The two bit planes of one row of a tile.
patternRow :: PPU s -> Word16 -> ST s (Word8, Word8)
patternRow ppu addr = (,) <$> peek ppu addr <*> peek ppu (addr + 8)

-- | Pixel i (0–7, from the left) of a pattern row, in one of four
-- palettes: a palette entry 0–15, or 0 when transparent.
shade :: Word16 -> (Word8, Word8) -> Int -> Word16
shade palette (lo, hi) i
  | pixel == 0 = 0
  | otherwise = palette `shiftL` 2 .|. pixel
  where
    pixel = plane lo .|. plane hi `shiftL` 1
    plane b = fromIntegral (b `shiftR` (7 - i) .&. 1)

-- | The finished picture: 256×240 pixels, 3 bytes (RGB) each.
picture :: forall s. PPU s -> ST s ByteString
picture ppu = do
  indices <- freeze ppu.pixels :: ST s (UArray Int Word8)
  let byte i = colors ! (3 * fromIntegral (indices ! (i `div` 3) .&. 0x3F) + i `mod` 3)
  pure (fst (BS.unfoldrN (3 * 256 * 240) (\i -> Just (byte i, i + 1)) 0))

-- | The NES's 64 colours in RGB, three bytes each.
colors :: UArray Int Word8
colors = listArray (0, 191) [fromIntegral (c `shiftR` s) | c <- palette, s <- [16, 8, 0]]
  where
    palette :: [Word32]
    palette =
      [ 0x666666,
        0x002A88,
        0x1412A7,
        0x3B00A4,
        0x5C007E,
        0x6E0040,
        0x6C0600,
        0x561D00,
        0x333500,
        0x0B4800,
        0x005200,
        0x004F08,
        0x00404D,
        0x000000,
        0x000000,
        0x000000,
        0xADADAD,
        0x155FD9,
        0x4240FF,
        0x7527FE,
        0xA01ACC,
        0xB71E7B,
        0xB53120,
        0x994E00,
        0x6B6D00,
        0x388700,
        0x0C9300,
        0x008F32,
        0x007C8D,
        0x000000,
        0x000000,
        0x000000,
        0xFFFEFF,
        0x64B0FF,
        0x9290FF,
        0xC676FF,
        0xF36AFF,
        0xFE6ECC,
        0xFE8170,
        0xEA9E22,
        0xBCBE00,
        0x88D800,
        0x5CE430,
        0x45E082,
        0x48CDDE,
        0x4F4F4F,
        0x000000,
        0x000000,
        0xFFFEFF,
        0xC0DFFF,
        0xD3D2FF,
        0xE8C8FF,
        0xFBC2FF,
        0xFEC4EA,
        0xFECCC5,
        0xF7D8A5,
        0xE4E594,
        0xCFEF96,
        0xBDF4AB,
        0xB3F3CC,
        0xB5EBF2,
        0xB8B8B8,
        0x000000,
        0x000000
      ]
