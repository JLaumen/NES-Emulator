{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoFieldSelectors #-}

-- | The standard controller, which the CPU reads one button at a time.
module Controller (Button (..), Controller, new, press, latch, readBit) where

import Control.Monad.ST (ST)
import Data.Bits (setBit, shiftR, (.&.), (.|.))
import Data.STRef (STRef, newSTRef, readSTRef, writeSTRef)
import Data.Word (Word8)

-- | In the order the controller reports them.
data Button = A | B | Select | Start | Up | Down | Left | Right
  deriving (Eq, Enum, Bounded)

data Controller s = Controller
  { -- | The buttons held down, one bit each.
    held :: STRef s Word8,
    -- | The buttons still to report.
    shifter :: STRef s Word8
  }

new :: ST s (Controller s)
new = Controller <$> newSTRef 0 <*> newSTRef 0

press :: Controller s -> [Button] -> ST s ()
press c = writeSTRef c.held . foldr (flip setBit . fromEnum) 0

-- | Take a snapshot of the buttons held, on a write to $4016.
latch :: Controller s -> ST s ()
latch c = readSTRef c.held >>= writeSTRef c.shifter

-- | The next button from the snapshot, on a read from $4016; after all
-- eight, the controller reports 1s.
readBit :: Controller s -> ST s Word8
readBit c = do
  bits <- readSTRef c.shifter
  writeSTRef c.shifter (bits `shiftR` 1 .|. 0x80)
  pure (bits .&. 1)
