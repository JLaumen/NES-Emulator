module Main (main) where

import Data.ByteString qualified as BS
import NES (Cartridge, nestest, parseCartridge)
import System.Environment (getArgs)
import System.Exit (die)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--nestest", rom] -> load rom >>= mapM_ putStrLn . nestest
    [rom] -> load rom >> putStrLn "Loaded. Graphics are not implemented yet."
    _ -> die "usage: nes [--nestest] <rom.nes>"

load :: FilePath -> IO Cartridge
load rom = BS.readFile rom >>= either (die . ("nes: " ++)) pure . parseCartridge
