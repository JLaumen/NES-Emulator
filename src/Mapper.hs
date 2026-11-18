{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoFieldSelectors #-}

-- | The chips on a cartridge that decide which banks of its memory the CPU
-- sees at $8000–$FFFF (8 KiB each) and the PPU at $0000–$1FFF (1 KiB
-- each). Mapper 0 (NROM) has none: its banks are fixed. Mapper 4 (MMC3)
-- switches them, sets the mirroring, and counts scanlines to raise IRQs.
module Mapper (Mapper, new, load, store, loadChr, storeChr, mirroring, scanline, irq, programROM, patternTables) where

import Cartridge (Cartridge (..), Mirroring (..))
import Control.Monad (when, zipWithM_)
import Control.Monad.ST (ST)
import Data.Array.ST (STUArray, freeze, getBounds, newArray, newListArray, readArray, writeArray)
import Data.Array.Unboxed (UArray, listArray, (!), (//))
import Data.Bits (shiftR, testBit, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.STRef (STRef, modifySTRef', newSTRef, readSTRef, writeSTRef)
import Data.Word (Word16, Word8)

data Mapper s = Mapper
  { prg :: ByteString,
    -- | Character memory: the cartridge's ROM, or its RAM.
    chr :: STUArray s Int Word8,
    -- | 8 KiB of program RAM at $6000–$7FFF.
    ram :: STUArray s Word16 Word8,
    -- | Where in prg each 8 KiB of $8000–$FFFF starts, and where in chr
    -- each 1 KiB of $0000–$1FFF does.
    prgBanks, chrBanks :: STUArray s Int Int,
    mirroring :: STRef s Mirroring,
    irq :: STRef s Bool,
    -- | Writes to $8000–$FFFF: the mapper's registers.
    control :: Word16 -> Word8 -> ST s (),
    -- | Called once a rendered scanline.
    scanline :: ST s ()
  }

new :: Cartridge -> ST s (Mapper s)
new cart = do
  chr <- newListArray (0, BS.length cart.chr - 1) (BS.unpack cart.chr)
  ram <- newArray (0x6000, 0x7FFF) 0
  -- Mapper 0's fixed banks: the ROM in order, 16 KiB of it twice over.
  prgBanks <- newListArray (0, 3) [i * 0x2000 `mod` BS.length cart.prg | i <- [0 .. 3]]
  chrBanks <- newListArray (0, 7) [i * 0x400 | i <- [0 .. 7]]
  mirroringRef <- newSTRef cart.mirroring
  irqRef <- newSTRef False
  let m = Mapper {prg = cart.prg, chr, ram, prgBanks, chrBanks, mirroring = mirroringRef, irq = irqRef, control = \_ _ -> pure (), scanline = pure ()}
  if cart.mapper == 4 then mmc3 m else pure m

-- | The CPU reads $6000–$FFFF.
load :: Mapper s -> Word16 -> ST s Word8
load m addr
  | addr < 0x8000 = readArray m.ram addr
  | otherwise = (\bank -> inBank m.prg bank addr) <$> readArray m.prgBanks (bankOf addr)

store :: Mapper s -> Word16 -> Word8 -> ST s ()
store m addr value
  | addr < 0x8000 = writeArray m.ram addr value
  | otherwise = m.control addr value

-- | Program ROM as the CPU sees it now, at $8000–$FFFF, for the DMC.
programROM :: forall s. Mapper s -> ST s (Word16 -> Word8)
programROM m = do
  banks <- freeze m.prgBanks :: ST s (UArray Int Int)
  pure (\addr -> inBank m.prg (banks ! bankOf addr) addr)

bankOf :: Word16 -> Int
bankOf addr = fromIntegral (addr - 0x8000) `shiftR` 13

inBank :: ByteString -> Int -> Word16 -> Word8
inBank prg bank addr = BS.index prg (bank + fromIntegral addr .&. 0x1FFF)

-- | The pattern tables as the PPU sees them now, at $0000–$1FFF.
patternTables :: forall s. Mapper s -> ST s (Word16 -> Word8)
patternTables m = do
  banks <- freeze m.chrBanks :: ST s (UArray Int Int)
  chr <- freeze m.chr :: ST s (UArray Int Word8)
  pure (\addr -> chr ! (banks ! (fromIntegral addr `shiftR` 10) + fromIntegral addr .&. 0x3FF))

-- | The PPU reads $0000–$1FFF.
loadChr :: Mapper s -> Word16 -> ST s Word8
loadChr m addr = readArray m.chrBanks (fromIntegral addr `shiftR` 10) >>= \bank -> readArray m.chr (bank + fromIntegral addr .&. 0x3FF)

-- | Writes go to CHR RAM, or to ROM, which games don't write.
storeChr :: Mapper s -> Word16 -> Word8 -> ST s ()
storeChr m addr value = readArray m.chrBanks (fromIntegral addr `shiftR` 10) >>= \bank -> writeArray m.chr (bank + fromIntegral addr .&. 0x3FF) value

mirroring :: Mapper s -> ST s Mirroring
mirroring m = readSTRef m.mirroring

scanline :: Mapper s -> ST s ()
scanline m = m.scanline

-- | Whether the mapper requests an interrupt.
irq :: Mapper s -> ST s Bool
irq m = readSTRef m.irq

-- * MMC3

data MMC3 = MMC3
  { -- | Which bank register $8001 sets (bits 0–2), and the layouts of
    -- program (bit 6) and character banks (bit 7).
    select :: !Word8,
    -- | The banks: two of 2 KiB and four of 1 KiB for the PPU, two of
    -- 8 KiB for the CPU.
    registers :: !(UArray Int Int),
    -- | The scanline counter, and what it reloads from when it reaches 0.
    counter, latch :: !Word8,
    irqOn :: !Bool
  }

-- | MMC3 (mapper 4): two switchable program banks, the last two fixed;
-- six character banks; mirroring; and an IRQ after a set number of
-- scanlines, for split screens such as a status bar.
mmc3 :: Mapper s -> ST s (Mapper s)
mmc3 m = do
  (_, lastChr) <- getBounds m.chr
  state <- newSTRef MMC3 {select = 0, registers = listArray (0, 7) [0, 2, 4, 5, 6, 7, 0, 1], counter = 0, latch = 0, irqOn = False}
  let set s = do
        writeSTRef state s
        let (prg, chr) = layout (BS.length m.prg) (lastChr + 1) s
        zipWithM_ (writeArray m.prgBanks) [0 ..] prg
        zipWithM_ (writeArray m.chrBanks) [0 ..] chr
      control addr value = do
        s <- readSTRef state
        case addr .&. 0xE001 of
          0x8000 -> set s {select = value}
          0x8001 -> set s {registers = s.registers // [(fromIntegral (s.select .&. 7), fromIntegral value)]}
          0xA000 -> writeSTRef m.mirroring (if testBit value 0 then Horizontal else Vertical)
          0xC000 -> writeSTRef state s {latch = value}
          -- The counter reloads at the next scanline.
          0xC001 -> writeSTRef state s {counter = 0}
          0xE000 -> writeSTRef state s {irqOn = False} >> writeSTRef m.irq False
          0xE001 -> writeSTRef state s {irqOn = True}
          _ -> pure ()
      count = do
        modifySTRef' state (\s -> s {counter = if s.counter == 0 then s.latch else s.counter - 1})
        s <- readSTRef state
        when (s.counter == 0 && s.irqOn) (writeSTRef m.irq True)
  set =<< readSTRef state
  pure m {control, scanline = count}

-- | Where the banks that the registers pick start in program and
-- character memory, of the given sizes.
layout :: Int -> Int -> MMC3 -> ([Int], [Int])
layout prgSize chrSize s = (map ((`mod` prgSize) . (* 0x2000)) prg, map ((`mod` chrSize) . (* 0x400)) chr)
  where
    r = (s.registers !)
    secondLast = prgSize `div` 0x2000 - 2
    prg = (if testBit s.select 6 then [secondLast, r 7, r 6] else [r 6, r 7, secondLast]) ++ [secondLast + 1]
    halves = [[r 0 .&. 0xFE, r 0 .|. 1, r 1 .&. 0xFE, r 1 .|. 1], [r 2, r 3, r 4, r 5]]
    chr = concat (if testBit s.select 7 then reverse halves else halves)
