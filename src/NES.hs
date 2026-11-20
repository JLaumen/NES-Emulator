{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoFieldSelectors #-}

-- | The NES emulator core.
module NES (Cartridge, parseCartridge, Palette, parsePalette, defaultPalette, Button (..), Input (..), Frame (..), frameRate, sampleRate, visualsSize, frames, nestest) where

import APU qualified
import Bus (Bus)
import Bus qualified
import CPU (Registers (..))
import CPU qualified
import Cartridge (Cartridge)
import Cartridge qualified
import Control.Monad (when)
import Control.Monad.ST (ST, runST)
import Control.Monad.ST.Lazy (strictToLazyST)
import Control.Monad.ST.Lazy qualified as Lazy
import Controller (Button (..))
import Controller qualified
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Primitive.PrimVar (readPrimVar, writePrimVar)
import Mapper qualified
import PPU (Palette, defaultPalette, parsePalette)
import PPU qualified
import Visualise (Snapshot (..))
import Visualise qualified

-- * NTSC timing

scanlines, dotsPerLine, dotsPerCycle :: Int
scanlines = 262
dotsPerLine = 341
dotsPerCycle = 3

-- | The CPU's clock rate in Hz.
cpuRate :: Double
cpuRate = 1789773

-- | Frames per second.
frameRate :: Double
frameRate = cpuRate * fromIntegral dotsPerCycle / fromIntegral (scanlines * dotsPerLine)

-- | Sound samples per second.
sampleRate :: Int
sampleRate = 44100

parseCartridge :: ByteString -> Either String Cartridge
parseCartridge = Cartridge.parse

data Frame = Frame
  { -- | 256×240 pixels, 3 bytes (RGB) each.
    picture :: ByteString,
    -- | The sound during the frame: mono, 'sampleRate' samples a second,
    -- from -1 to 1.
    sound :: [Float],
    -- | A look inside: what the PPU, APU and CPU are doing, as a picture of
    -- 'visualsSize' pixels, 4 bytes each (0x00RRGGBB in the machine's byte
    -- order). Drawn only when needed, and empty unless asked for.
    visuals :: ByteString
  }

visualsSize :: (Int, Int)
visualsSize = (Visualise.width, Visualise.height)

-- | What drives a frame: the buttons held, and how fast the console runs
-- relative to the sound card (1 is its own speed; above 1, the frame makes
-- less sound, which then plays faster).
data Input = Input {buttons :: [Button], speed :: Double}

-- | The frames a game shows, given whether to make their visuals (which
-- costs time even when they aren't drawn), the most sprites to draw on a
-- scanline (8 on the console; 64 ends the flicker of games that take
-- turns drawing more), the palette to show them in, and the input for
-- each frame. Each frame's input is needed only once that frame is.
frames :: Bool -> Int -> Palette -> Cartridge -> [Input] -> [Frame]
frames watched spriteLimit palette cart inputs = Lazy.runST $ do
  (bus, cpu) <- strictToLazyST (boot watched spriteLimit cart)
  let run [] = pure []
      run (input : rest) = do
        out <- strictToLazyST $ do
          Controller.press bus.controller input.buttons
          APU.atSpeed bus.apu input.speed
          frame bus cpu
          picture <- PPU.picture palette bus.ppu
          (sound, voices) <- APU.drain bus.apu
          visuals <-
            if watched
              then do
                video <- PPU.video bus.ppu
                (readHeat, writeHeat) <- Bus.heat bus
                state <- CPU.snapshot cpu
                pure (Visualise.picture Snapshot {cpu = state, video, readHeat, writeHeat, sound, voices, palette})
              else pure BS.empty
          pure Frame {picture, sound, visuals}
        (out :) <$> run rest
  run inputs

boot :: Bool -> Int -> Cartridge -> ST s (Bus s, Registers s)
boot watched spriteLimit cart = do
  apu <- APU.new watched cpuRate (fromIntegral sampleRate)
  bus <- Bus.new watched spriteLimit cart apu
  cpu <- CPU.reset bus >>= CPU.new
  pure (bus, cpu)

-- | Run a frame, from the pre-render line to the end of vblank, with the
-- CPU and APU running alongside each scanline. Interrupt requests are
-- answered at the start of a line and at dot 260, where MMC3 counts it.
frame :: Bus s -> Registers s -> ST s ()
frame bus cpu = do
  start <- readPrimVar cpu.clock
  let line n = do
        let lineStart = start * dotsPerCycle + (n + 1) * dotsPerLine
        nmi <- PPU.startLine bus.ppu n
        if nmi then CPU.nmi bus cpu else request
        runUntil (lineStart + 260)
        PPU.hblank bus.ppu n
        request
        runUntil (lineStart + dotsPerLine)
        -- The APU catches up once a line, which is close enough for sound.
        rom <- Mapper.programROM bus.mapper
        readPrimVar cpu.clock >>= APU.run bus.apu rom
        PPU.endLine bus.ppu n
  mapM_ line [-1 .. scanlines - 2]
  where
    request = do
      irq <- (||) <$> APU.irq bus.apu <*> Mapper.irq bus.mapper
      when irq (CPU.irq bus cpu)
    runUntil dot = do
      cycles <- readPrimVar cpu.clock
      when (cycles * dotsPerCycle < dot) $ do
        pc <- readPrimVar cpu.regPC
        sp <- readPrimVar cpu.regSP
        CPU.step bus cpu
        pc' <- readPrimVar cpu.regPC
        sp' <- readPrimVar cpu.regSP
        cycles' <- readPrimVar cpu.clock
        -- A jump or branch to itself waits for an interrupt: skip ahead
        -- by whole turns. (Calls and returns move the stack, so their
        -- next turn differs.)
        let turn = cycles' - cycles
            turns = (dot - cycles' * dotsPerCycle + turn * dotsPerCycle - 1) `div` (turn * dotsPerCycle)
        if pc' == pc && sp' == sp
          then writePrimVar cpu.clock (cycles' + max 0 turns * turn)
          else runUntil dot

-- | A CPU trace of the nestest ROM's automated mode, which starts at $C000
-- and runs for the 8991 lines of the reference nestest.log.
nestest :: Cartridge -> [String]
nestest cart = runST $ do
  (bus, cpu) <- boot False 8 cart
  writePrimVar cpu.regPC 0xC000
  let run 0 = pure []
      run n = (:) . CPU.trace <$> CPU.snapshot cpu <*> (CPU.step bus cpu >> run (n - 1))
  run (8991 :: Int)
