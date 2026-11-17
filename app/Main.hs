{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent (getChanContents, newChan, writeChan)
import Control.Monad (unless)
import Data.ByteString qualified as BS
import NES (Button, Cartridge, frames, nestest, parseCartridge)
import NES qualified
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

-- | Play the game in a window, at three times the NES's resolution. Vsync
-- paces the game: one frame per screen refresh, so a 60 Hz display is
-- needed for the right speed.
play :: Cartridge -> IO ()
play cart = do
  SDL.initialize [SDL.InitVideo]
  window <- SDL.createWindow "nes" SDL.defaultWindow {SDL.windowInitialSize = SDL.V2 768 720}
  renderer <- SDL.createRenderer window (-1) SDL.defaultRenderer {SDL.rendererType = SDL.AcceleratedVSyncRenderer}
  texture <- SDL.createTexture renderer SDL.RGB24 SDL.TextureAccessStreaming (SDL.V2 256 240)
  -- The core reads the buttons for each frame lazily from this channel, so
  -- they must be in it before the frame is drawn.
  inputs <- newChan
  let loop pictures = do
        events <- SDL.pollEvents
        held <- SDL.getKeyboardState
        writeChan inputs [button | (key, button) <- keys, held key]
        unless (any ((== SDL.QuitEvent) . SDL.eventPayload) events) $ case pictures of
          picture : rest -> do
            _ <- SDL.updateTexture texture Nothing picture (256 * 3)
            SDL.copy renderer texture Nothing Nothing
            SDL.present renderer -- waits for the refresh
            loop rest
          [] -> pure ()
  loop . frames cart =<< getChanContents inputs
  SDL.quit

keys :: [(SDL.Scancode, Button)]
keys =
  [ (SDL.ScancodeX, NES.A),
    (SDL.ScancodeZ, NES.B),
    (SDL.ScancodeRShift, NES.Select),
    (SDL.ScancodeReturn, NES.Start),
    (SDL.ScancodeUp, NES.Up),
    (SDL.ScancodeDown, NES.Down),
    (SDL.ScancodeLeft, NES.Left),
    (SDL.ScancodeRight, NES.Right)
  ]
