{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import Data.ByteString qualified as BS
import GHC.Clock (getMonotonicTime)
import NES (Cartridge, frames, framesPerSecond, nestest, parseCartridge)
import SDL qualified
import System.Environment (getArgs)
import System.Exit (die)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--nestest", rom] -> load rom >>= mapM_ putStrLn . nestest
    [rom] -> load rom >>= play
    _ -> die "usage: nes [--nestest] <rom.nes>"

load :: FilePath -> IO Cartridge
load rom = BS.readFile rom >>= either (die . ("nes: " ++)) pure . parseCartridge

-- | Show the game's frames in a window, at three times the NES's resolution.
play :: Cartridge -> IO ()
play cart = do
  SDL.initialize [SDL.InitVideo]
  window <- SDL.createWindow "nes" SDL.defaultWindow {SDL.windowInitialSize = SDL.V2 768 720}
  renderer <- SDL.createRenderer window (-1) SDL.defaultRenderer
  texture <- SDL.createTexture renderer SDL.RGB24 SDL.TextureAccessStreaming (SDL.V2 256 240)
  let loop deadline pictures = do
        events <- SDL.pollEvents
        unless (any ((== SDL.QuitEvent) . SDL.eventPayload) events) $ case pictures of
          picture : rest -> do
            _ <- SDL.updateTexture texture Nothing picture (256 * 3)
            SDL.copy renderer texture Nothing Nothing
            SDL.present renderer
            now <- getMonotonicTime
            threadDelay (round ((deadline - now) * 1e6))
            loop (max now deadline + 1 / fromIntegral framesPerSecond) rest
          [] -> pure ()
  start <- getMonotonicTime
  loop start (frames cart)
  SDL.quit
