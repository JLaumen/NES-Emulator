{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoFieldSelectors #-}

-- | The CPU's view of memory.
module Bus (Bus, new, load, store, loadWord) where

import Cartridge (Cartridge (..))
import Control.Monad (forM_)
import Control.Monad.ST (ST)
import Data.Array.ST (STUArray, newArray, readArray, writeArray)
import Data.Bits (shiftL, (.&.), (.|.))
import Data.ByteString qualified as BS
import Data.Word (Word16, Word8)
import PPU (PPU)
import PPU qualified

data Bus s = Bus
  { ram :: STUArray s Word16 Word8,
    ppu :: PPU s,
    cart :: Cartridge
  }

new :: Cartridge -> PPU s -> ST s (Bus s)
new cart ppu = do
  ram <- newArray (0, 0x7FF) 0
  pure Bus {ram, ppu, cart}

-- | Memory map: 2 KiB RAM mirrored up to $2000, PPU registers mirrored up
-- to $4000, cartridge from $8000. Of the IO registers in between, only
-- OAM DMA is connected.
load :: Bus s -> Word16 -> ST s Word8
load bus addr
  | addr < 0x2000 = readArray bus.ram (addr .&. 0x7FF)
  | addr < 0x4000 = PPU.readRegister bus.ppu addr
  | addr >= 0x8000 = pure (BS.index prg (fromIntegral (addr - 0x8000) `mod` BS.length prg))
  | otherwise = pure 0
  where
    prg = bus.cart.prg

store :: Bus s -> Word16 -> Word8 -> ST s ()
store bus addr value
  | addr < 0x2000 = writeArray bus.ram (addr .&. 0x7FF) value
  | addr < 0x4000 = PPU.writeRegister bus.ppu addr value
  -- OAM DMA: copy a page to the sprites. (The CPU stalls for 513 cycles,
  -- which we skip.)
  | addr == 0x4014 = forM_ [0 .. 255] $ \i ->
      load bus (fromIntegral value `shiftL` 8 + i) >>= PPU.writeRegister bus.ppu 0x2004
  | otherwise = pure ()

-- | Load a little-endian word.
loadWord :: Bus s -> Word16 -> ST s Word16
loadWord bus addr = do
  lo <- load bus addr
  hi <- load bus (addr + 1)
  pure (fromIntegral hi `shiftL` 8 .|. fromIntegral lo)
