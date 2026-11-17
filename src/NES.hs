{-# LANGUAGE OverloadedRecordDot #-}

-- | The NES emulator core.
module NES (Cartridge, parseCartridge, framesPerSecond, frames, nestest) where

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
import Data.ByteString (ByteString)
import PPU (PPU)
import PPU qualified

-- * NTSC timing

framesPerSecond, scanlines, dotsPerLine, dotsPerCycle :: Int
framesPerSecond = 60
scanlines = 262
dotsPerLine = 341
dotsPerCycle = 3

parseCartridge :: ByteString -> Either String Cartridge
parseCartridge = Cartridge.parse

-- | The pictures a game shows: 256×240 pixels, 3 bytes (RGB) each.
frames :: Cartridge -> [ByteString]
frames cart = Lazy.runST $ do
  (ppu, bus, cpu) <- strictToLazyST (boot cart)
  let run state = do
        (state', pic) <- strictToLazyST $ do
          state' <- frame ppu bus state
          (state',) <$> PPU.picture ppu
        (pic :) <$> run state'
  run cpu

boot :: Cartridge -> ST s (PPU s, Bus s, CPU)
boot cart = do
  ppu <- PPU.new cart
  bus <- Bus.new cart ppu
  cpu <- CPU.reset bus
  pure (ppu, bus, cpu)

-- | Run a frame, from the pre-render line to the end of vblank, with the
-- CPU running alongside each scanline.
frame :: PPU s -> Bus s -> CPU -> ST s CPU
frame ppu bus start = foldM line start [-1 .. scanlines - 2]
  where
    line cpu n = do
      nmi <- PPU.startLine ppu n
      cpu' <- (if nmi then CPU.nmi bus else pure) cpu
      cpu'' <- runUntil (start.cycles * dotsPerCycle + (n + 2) * dotsPerLine) cpu'
      cpu'' <$ PPU.endLine ppu n
    runUntil dot cpu
      | cpu.cycles * dotsPerCycle >= dot = pure cpu
      | otherwise = CPU.step bus cpu >>= runUntil dot

-- | A CPU trace of the nestest ROM's automated mode, which starts at $C000
-- and runs for the 8991 lines of the reference nestest.log.
nestest :: Cartridge -> [String]
nestest cart = runST $ do
  (_, bus, cpu) <- boot cart
  let run 0 _ = pure []
      run n state = (CPU.trace state :) <$> (CPU.step bus state >>= run (n - 1))
  run (8991 :: Int) cpu {pc = 0xC000}
