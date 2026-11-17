{-# LANGUAGE OverloadedRecordDot #-}

-- | The NES emulator core.
module NES (Cartridge, parseCartridge, Button (..), framesPerSecond, frames, nestest) where

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
import PPU qualified

-- * NTSC timing

framesPerSecond, scanlines, dotsPerLine, dotsPerCycle :: Int
framesPerSecond = 60
scanlines = 262
dotsPerLine = 341
dotsPerCycle = 3

parseCartridge :: ByteString -> Either String Cartridge
parseCartridge = Cartridge.parse

-- | The pictures a game shows, given the buttons held during each frame:
-- 256×240 pixels, 3 bytes (RGB) each. Each frame's buttons are needed only
-- once that frame is.
frames :: Cartridge -> [[Button]] -> [ByteString]
frames cart inputs = Lazy.runST $ do
  (bus, cpu) <- strictToLazyST (boot cart)
  let run _ [] = pure []
      run state (buttons : rest) = do
        (state', pic) <- strictToLazyST $ do
          Controller.press bus.controller buttons
          state' <- frame bus state
          (state',) <$> PPU.picture bus.ppu
        (pic :) <$> run state' rest
  run cpu inputs

boot :: Cartridge -> ST s (Bus s, CPU)
boot cart = do
  bus <- Bus.new cart
  cpu <- CPU.reset bus
  pure (bus, cpu)

-- | Run a frame, from the pre-render line to the end of vblank, with the
-- CPU running alongside each scanline.
frame :: Bus s -> CPU -> ST s CPU
frame bus start = foldM line start [-1 .. scanlines - 2]
  where
    line cpu n = do
      nmi <- PPU.startLine bus.ppu n
      cpu' <- (if nmi then CPU.nmi bus else pure) cpu
      cpu'' <- runUntil (start.cycles * dotsPerCycle + (n + 2) * dotsPerLine) cpu'
      cpu'' <$ PPU.endLine bus.ppu n
    runUntil dot cpu
      | cpu.cycles * dotsPerCycle >= dot = pure cpu
      | otherwise = CPU.step bus cpu >>= runUntil dot

-- | A CPU trace of the nestest ROM's automated mode, which starts at $C000
-- and runs for the 8991 lines of the reference nestest.log.
nestest :: Cartridge -> [String]
nestest cart = runST $ do
  (bus, cpu) <- boot cart
  let run 0 _ = pure []
      run n state = (CPU.trace state :) <$> (CPU.step bus state >>= run (n - 1))
  run (8991 :: Int) cpu {pc = 0xC000}
