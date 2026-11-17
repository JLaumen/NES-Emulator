module Main (main) where

import NES (version)
import System.Environment (getArgs)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [rom] -> putStrLn ("nes " ++ version ++ ": would run " ++ rom)
    _ -> putStrLn "usage: nes <rom.nes>"
