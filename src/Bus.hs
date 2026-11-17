{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoFieldSelectors #-}

-- | The CPU's view of memory.
module Bus (Bus (ppu, apu, controller, cart), new, load, store, loadWord) where

import APU (APU)
import APU qualified
import Cartridge (Cartridge, prgByte)
import Control.Monad (forM_)
import Control.Monad.ST (ST)
import Controller (Controller)
import Controller qualified
import Data.Array.ST (STUArray, newArray, readArray, writeArray)
import Data.Bits (shiftL, (.&.), (.|.))
import Data.STRef (STRef, modifySTRef', newSTRef, readSTRef, writeSTRef)
import Data.Word (Word16, Word8)
import PPU (PPU)
import PPU qualified

data Bus s = Bus
  { ram :: STUArray s Word16 Word8,
    ppu :: PPU s,
    apu :: STRef s APU,
    controller :: Controller s,
    cart :: Cartridge
  }

new :: Cartridge -> APU -> ST s (Bus s)
new cart apu0 = do
  ram <- newArray (0, 0x7FF) 0
  ppu <- PPU.new cart
  apu <- newSTRef apu0
  controller <- Controller.new
  pure Bus {ram, ppu, apu, controller, cart}

-- | Memory map: 2 KiB RAM mirrored up to $2000, PPU registers mirrored up
-- to $4000, APU and IO registers, and the cartridge from $8000. Only the
-- first controller is connected.
load :: Bus s -> Word16 -> ST s Word8
load bus addr
  | addr < 0x2000 = readArray bus.ram (addr .&. 0x7FF)
  | addr < 0x4000 = PPU.readRegister bus.ppu addr
  | addr == 0x4015 = do
      (status, apu) <- APU.readStatus <$> readSTRef bus.apu
      status <$ writeSTRef bus.apu apu
  | addr == 0x4016 = Controller.readBit bus.controller
  | addr >= 0x8000 = pure (prgByte bus.cart addr)
  | otherwise = pure 0

store :: Bus s -> Word16 -> Word8 -> ST s ()
store bus addr value
  | addr < 0x2000 = writeArray bus.ram (addr .&. 0x7FF) value
  | addr < 0x4000 = PPU.writeRegister bus.ppu addr value
  -- OAM DMA: copy a page to the sprites. (The CPU stalls for 513 cycles,
  -- which we skip.)
  | addr == 0x4014 = forM_ [0 .. 255] $ \i ->
      load bus (fromIntegral value `shiftL` 8 + i) >>= PPU.writeRegister bus.ppu 0x2004
  | addr == 0x4016 = Controller.latch bus.controller
  | addr < 0x4018 = modifySTRef' bus.apu (APU.write addr value)
  | otherwise = pure ()

-- | Load a little-endian word.
loadWord :: Bus s -> Word16 -> ST s Word16
loadWord bus addr = do
  lo <- load bus addr
  hi <- load bus (addr + 1)
  pure (fromIntegral hi `shiftL` 8 .|. fromIntegral lo)
