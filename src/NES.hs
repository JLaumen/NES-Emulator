{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoFieldSelectors #-}

-- | The NES emulator core.
module NES (Cartridge, parseCartridge, Palette, parsePalette, defaultPalette, Button (..), Input (..), Frame (..), frameRate, sampleRate, visualsSize, frames, nestest) where

import APU qualified
import Bus (Bus)
import Bus qualified
import CPU (CPU (..))
import CPU qualified
import Cartridge (Cartridge)
import Cartridge qualified
import Control.Monad (foldM)
import Control.Monad.ST (ST, runST)
import Control.Monad.ST.Lazy (strictToLazyST)
import Control.Monad.ST.Lazy qualified as Lazy
import Controller (Button (..))
import Controller qualified
import Data.ByteString (ByteString)
import Data.STRef (modifySTRef', readSTRef, writeSTRef)
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
    -- order). Drawn only when needed.
    visuals :: ByteString
  }

visualsSize :: (Int, Int)
visualsSize = (Visualise.width, Visualise.height)

-- | What drives a frame: the buttons held, and how fast the console runs
-- relative to the sound card (1 is its own speed; above 1, the frame makes
-- less sound, which then plays faster).
data Input = Input {buttons :: [Button], speed :: Double}

-- | The frames a game shows, given the most sprites to draw on a scanline
-- (8 on the console; 64 ends the flicker of games that take turns
-- drawing more), the palette to show them in, and the input for each
-- frame. Each frame's input is needed only once that frame is.
frames :: Int -> Palette -> Cartridge -> [Input] -> [Frame]
frames spriteLimit palette cart inputs = Lazy.runST $ do
  (bus, cpu) <- strictToLazyST (boot spriteLimit cart)
  let run _ [] = pure []
      run state (input : rest) = do
        (state', out) <- strictToLazyST $ do
          Controller.press bus.controller input.buttons
          modifySTRef' bus.apu (APU.atSpeed input.speed)
          state' <- frame bus state
          picture <- PPU.picture palette bus.ppu
          (sound, voices, apu) <- APU.drain <$> readSTRef bus.apu
          writeSTRef bus.apu apu
          video <- PPU.video bus.ppu
          (readHeat, writeHeat) <- Bus.heat bus
          let visuals = Visualise.picture Snapshot {cpu = state', video, readHeat, writeHeat, sound, voices, palette}
          pure (state', Frame {picture, sound, visuals})
        (out :) <$> run state' rest
  run cpu inputs

boot :: Int -> Cartridge -> ST s (Bus s, CPU)
boot spriteLimit cart = do
  bus <- Bus.new spriteLimit cart (APU.new cpuRate (fromIntegral sampleRate))
  cpu <- CPU.reset bus
  pure (bus, cpu)

-- | Run a frame, from the pre-render line to the end of vblank, with the
-- CPU and APU running alongside each scanline.
frame :: Bus s -> CPU -> ST s CPU
frame bus start = foldM line start [-1 .. scanlines - 2]
  where
    line cpu n = do
      nmi <- PPU.startLine bus.ppu n
      irq <- APU.irq <$> readSTRef bus.apu
      cpu' <- (if nmi then CPU.nmi bus else if irq then CPU.irq bus else pure) cpu
      cpu'' <- runUntil (start.cycles * dotsPerCycle + (n + 2) * dotsPerLine) cpu'
      -- The APU catches up once a line, which is close enough for sound.
      modifySTRef' bus.apu (APU.run bus.cart cpu''.cycles)
      cpu'' <$ PPU.endLine bus.ppu n
    runUntil dot cpu
      | cpu.cycles * dotsPerCycle >= dot = pure cpu
      | otherwise = CPU.step bus cpu >>= runUntil dot

-- | A CPU trace of the nestest ROM's automated mode, which starts at $C000
-- and runs for the 8991 lines of the reference nestest.log.
nestest :: Cartridge -> [String]
nestest cart = runST $ do
  (bus, cpu) <- boot 8 cart
  let run 0 _ = pure []
      run n state = (CPU.trace state :) <$> (CPU.step bus state >>= run (n - 1))
  run (8991 :: Int) cpu {pc = 0xC000}
