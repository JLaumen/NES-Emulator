{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoFieldSelectors #-}

-- | Cartridges in the iNES file format, with mapper 0 (NROM) or 4 (MMC3).
module Cartridge (Cartridge (..), Mirroring (..), parse) where

import Data.Bits (testBit, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Word (Word8)

data Mirroring = Horizontal | Vertical

data Cartridge = Cartridge
  { -- | Program ROM: 16 KiB or more, mapped from $8000.
    prg :: ByteString,
    -- | Character (tile) ROM: 8 KiB or more, or 8 KiB of zeros if the
    -- board has CHR RAM.
    chr :: ByteString,
    mirroring :: Mirroring,
    -- | Which chips map the ROM into memory; see "Mapper".
    mapper :: Word8
  }

parse :: ByteString -> Either String Cartridge
parse rom
  | BS.length rom < 16 || BS.take 4 rom /= "NES\x1A" = Left "not an iNES file"
  | mapper `notElem` [0, 4] = Left ("unsupported mapper " ++ show mapper)
  | BS.length rom < chrStart + chrSize = Left "truncated file"
  | otherwise =
      Right
        Cartridge
          { prg = slice prgStart prgSize,
            chr = if chrSize == 0 then BS.replicate 0x2000 0 else slice chrStart chrSize,
            mirroring = if testBit flags6 0 then Vertical else Horizontal,
            mapper
          }
  where
    flags6 = BS.index rom 6
    mapper = (flags6 `div` 16) .|. (BS.index rom 7 .&. 0xF0)
    prgStart = if testBit flags6 2 then 16 + 512 else 16 -- skip the trainer
    prgSize = 0x4000 * fromIntegral (BS.index rom 4)
    chrStart = prgStart + prgSize
    chrSize = 0x2000 * fromIntegral (BS.index rom 5)
    slice start size = BS.take size (BS.drop start rom)
