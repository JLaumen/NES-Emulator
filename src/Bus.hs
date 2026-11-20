{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoFieldSelectors #-}

-- | The CPU's view of memory.
module Bus (Bus (ppu, apu, controller, mapper), new, load, store, loadWord, heat) where

import APU (APU)
import APU qualified
import Cartridge (Cartridge)
import Control.Monad (forM_, when)
import Control.Monad.ST (ST)
import Controller (Controller)
import Controller qualified
import Data.Array.ST (STUArray, freeze, newArray, readArray, writeArray)
import Data.Array.Unboxed (UArray)
import Data.Bits (shiftL, (.&.), (.|.))
import Data.Word (Word16, Word8)
import Mapper (Mapper)
import Mapper qualified
import PPU (PPU)
import PPU qualified

data Bus s = Bus
  { ram :: STUArray s Word16 Word8,
    ppu :: PPU s,
    apu :: APU s,
    controller :: Controller s,
    mapper :: Mapper s,
    -- | Whether to keep the heat below, for a look inside.
    watched :: Bool,
    -- | How recently the CPU read and wrote each address: 255 just now,
    -- cooling off with each 'heat'.
    readHeat, writeHeat :: STUArray s Word16 Word8
  }

new :: Bool -> Int -> Cartridge -> APU s -> ST s (Bus s)
new watched spriteLimit cart apu = do
  ram <- newArray (0, 0x7FF) 0
  mapper <- Mapper.new cart
  ppu <- PPU.new spriteLimit mapper
  controller <- Controller.new
  readHeat <- newArray (0, 0xFFFF) 0
  writeHeat <- newArray (0, 0xFFFF) 0
  pure Bus {ram, ppu, apu, controller, mapper, watched, readHeat, writeHeat}

-- | Memory map: 2 KiB RAM mirrored up to $2000, PPU registers mirrored up
-- to $4000, APU and IO registers, and the cartridge from $6000. Only the
-- first controller is connected.
load :: Bus s -> Word16 -> ST s Word8
load bus addr = when bus.watched (writeArray bus.readHeat addr 255) >> value
  where
    value
      | addr < 0x2000 = readArray bus.ram (addr .&. 0x7FF)
      | addr < 0x4000 = PPU.readRegister bus.ppu addr
      | addr == 0x4015 = APU.readStatus bus.apu
      | addr == 0x4016 = Controller.readBit bus.controller
      | addr >= 0x6000 = Mapper.load bus.mapper addr
      | otherwise = pure 0

store :: Bus s -> Word16 -> Word8 -> ST s ()
store bus addr value = when bus.watched (writeArray bus.writeHeat addr 255) >> effect
  where
    effect
      | addr < 0x2000 = writeArray bus.ram (addr .&. 0x7FF) value
      | addr < 0x4000 = PPU.writeRegister bus.ppu addr value
      -- OAM DMA: copy a page to the sprites. (The CPU stalls for 513
      -- cycles, which we skip.)
      | addr == 0x4014 = forM_ [0 .. 255] $ \i ->
          load bus (fromIntegral value `shiftL` 8 + i) >>= PPU.writeRegister bus.ppu 0x2004
      | addr == 0x4016 = Controller.latch bus.controller
      | addr < 0x4018 = APU.write bus.apu addr value
      | addr >= 0x6000 = Mapper.store bus.mapper addr value
      | otherwise = pure ()

-- | Load a little-endian word.
loadWord :: Bus s -> Word16 -> ST s Word16
loadWord bus addr = do
  lo <- load bus addr
  hi <- load bus (addr + 1)
  pure $! fromIntegral hi `shiftL` 8 .|. fromIntegral lo

-- | How recently the CPU read and wrote each address (see 'readHeat'); then
-- cool them off a little.
heat :: Bus s -> ST s (UArray Word16 Word8, UArray Word16 Word8)
heat bus = do
  hot <- (,) <$> freeze bus.readHeat <*> freeze bus.writeHeat
  forM_ [bus.readHeat, bus.writeHeat] $ \a -> forM_ [0 .. 0xFFFF :: Int] $ \i ->
    readArray a (fromIntegral i) >>= writeArray a (fromIntegral i) . \h -> h - min h 8
  pure hot
