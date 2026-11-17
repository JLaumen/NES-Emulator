{-# LANGUAGE OverloadedStrings #-}

-- | Cartridges in the iNES file format. Only mapper 0 is supported.
module Cartridge (Cartridge (..), Mirroring (..), parse) where

import Data.Bits (testBit, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS

data Mirroring = Horizontal | Vertical

data Cartridge = Cartridge
  { -- | Program ROM: 16 or 32 KiB, mapped at $8000.
    prg :: ByteString,
    -- | Character (tile) ROM: 8 KiB, or all zeros if the board has CHR RAM.
    chr :: ByteString,
    mirroring :: Mirroring
  }

parse :: ByteString -> Either String Cartridge
parse rom
  | BS.length rom < 16 || BS.take 4 rom /= "NES\x1A" = Left "not an iNES file"
  | mapper /= 0 = Left ("unsupported mapper " ++ show mapper)
  | BS.length rom < chrStart + chrSize = Left "truncated file"
  | otherwise =
      Right
        Cartridge
          { prg = slice prgStart prgSize,
            chr = if chrSize == 0 then BS.replicate 0x2000 0 else slice chrStart chrSize,
            mirroring = if testBit flags6 0 then Vertical else Horizontal
          }
  where
    flags6 = BS.index rom 6
    mapper = (flags6 `div` 16) .|. (BS.index rom 7 .&. 0xF0)
    prgStart = if testBit flags6 2 then 16 + 512 else 16 -- skip the trainer
    prgSize = 0x4000 * fromIntegral (BS.index rom 4)
    chrStart = prgStart + prgSize
    chrSize = 0x2000 * fromIntegral (BS.index rom 5)
    slice start size = BS.take size (BS.drop start rom)
