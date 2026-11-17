-- | The NES emulator core.
module NES (Cartridge, parseCartridge, nestest) where

import Bus qualified
import CPU (CPU (..))
import CPU qualified
import Cartridge (Cartridge)
import Cartridge qualified
import Control.Monad.ST (runST)
import Data.ByteString (ByteString)

parseCartridge :: ByteString -> Either String Cartridge
parseCartridge = Cartridge.parse

-- | A CPU trace of the nestest ROM's automated mode, which starts at $C000
-- and runs for the 8991 lines of the reference nestest.log.
nestest :: Cartridge -> [String]
nestest cart = runST $ do
  bus <- Bus.new cart
  cpu <- CPU.reset bus
  let run 0 _ = pure []
      run n state = (CPU.trace state :) <$> (CPU.step bus state >>= run (n - 1))
  run (8991 :: Int) cpu {pc = 0xC000}
