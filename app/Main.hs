{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent (getChanContents, newChan, writeChan)
import Control.Monad (unless, when)
import Data.ByteString qualified as BS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Tuple (swap)
import Data.Vector.Storable.Mutable qualified as MV
import Data.Vector.Unboxed qualified as V
import NES (Button, Cartridge, frames, nestest, parseCartridge, sampleRate, visualsSize)
import NES qualified
import SDL qualified
import System.Environment (getArgs)
import System.Exit (die)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--nestest", rom] -> load rom >>= mapM_ putStrLn . nestest
    ["--debug", rom] -> load rom >>= play True
    [rom] -> load rom >>= play False
    _ -> die "usage: nes [--nestest | --debug] <rom.nes>"

load :: FilePath -> IO Cartridge
load rom = BS.readFile rom >>= either (die . ("nes: " ++)) pure . parseCartridge

-- | Play the game in a window, at three times the NES's resolution. Vsync
-- paces the game: one frame per screen refresh, so a 60 Hz display is
-- needed for the right speed. The sound goes through a queue that the
-- audio device empties at its own pace. With debug on, the visuals of what
-- the emulator is doing go beside the game. (In a window of their own, they
-- would upset the vsync.)
play :: Bool -> Cartridge -> IO ()
play debug cart = do
  SDL.initialize [SDL.InitVideo, SDL.InitAudio]
  queue <- newIORef Seq.empty
  (device, _) <-
    SDL.openAudioDevice
      SDL.OpenDeviceSpec
        { SDL.openDeviceFreq = SDL.Mandate (fromIntegral sampleRate),
          SDL.openDeviceFormat = SDL.Mandate SDL.FloatingLEAudio,
          SDL.openDeviceChannels = SDL.Mandate SDL.Mono,
          SDL.openDeviceSamples = 512,
          SDL.openDeviceCallback = speaker queue,
          SDL.openDeviceUsage = SDL.ForPlayback,
          SDL.openDeviceName = Nothing
        }
  SDL.setAudioDevicePlaybackState device SDL.Play
  let (w, h) = visualsSize
      height = if debug then max 720 h else 720
      size = SDL.V2 (if debug then 768 + w else 768) height
      game = SDL.Rectangle (SDL.P (SDL.V2 0 ((height - 720) `div` 2))) (SDL.V2 768 720)
      beside = SDL.Rectangle (SDL.P (SDL.V2 768 0)) (SDL.V2 w h)
  window <- SDL.createWindow "nes" SDL.defaultWindow {SDL.windowInitialSize = fromIntegral <$> size, SDL.windowResizable = True}
  renderer <- SDL.createRenderer window (-1) SDL.defaultRenderer {SDL.rendererType = SDL.AcceleratedVSyncRenderer}
  -- Draw at this size whatever the window's, with bars around if need be.
  SDL.rendererLogicalSize renderer SDL.$= Just (fromIntegral <$> size)
  SDL.rendererDrawColor renderer SDL.$= SDL.V4 14 16 22 255
  texture <- SDL.createTexture renderer SDL.RGB24 SDL.TextureAccessStreaming (SDL.V2 256 240)
  visuals <- SDL.createTexture renderer SDL.RGB888 SDL.TextureAccessStreaming (fromIntegral <$> SDL.V2 w h)
  -- The core reads the buttons for each frame lazily from this channel, so
  -- they must be in it before the frame is drawn.
  inputs <- newChan
  let loop outputs = do
        events <- SDL.pollEvents
        held <- SDL.getKeyboardState
        writeChan inputs [button | (key, button) <- keys, held key]
        unless (any ((== SDL.QuitEvent) . SDL.eventPayload) events) $ case outputs of
          out : rest -> do
            queued <- Seq.length <$> readIORef queue
            let sound = Seq.fromList (resample (speed queued) out.sound)
            atomicModifyIORef' queue (\q -> (q <> sound, ()))
            SDL.clear renderer
            _ <- SDL.updateTexture texture Nothing out.picture (256 * 3)
            SDL.copy renderer texture Nothing (Just (fromIntegral <$> game))
            when debug $ do
              _ <- SDL.updateTexture visuals Nothing out.visuals (fromIntegral w * 4)
              SDL.copy renderer visuals Nothing (Just (fromIntegral <$> beside))
            SDL.present renderer -- waits for the refresh
            loop rest
          [] -> pure ()
  loop . frames cart =<< getChanContents inputs
  SDL.closeAudioDevice device
  SDL.quit

-- | The display and the sound card keep slightly different time, so the
-- sound plays up to 0.5% faster or slower to keep about 2048 samples
-- queued: enough to ride out a late frame.
speed :: Int -> Double
speed queued = 1 + 0.005 * max (-1) (min 1 ((fromIntegral queued - 2048) / 1024))

-- | Play samples at the given speed, interpolating between them.
resample :: Double -> [Float] -> [Float]
resample rate samples =
  [ realToFrac (1 - f) * at i + realToFrac f * at (i + 1)
  | t <- takeWhile (< fromIntegral (V.length v)) [rate * fromIntegral k | k <- [0 :: Int ..]],
    let (i, f) = properFraction t
  ]
  where
    v = V.fromList samples
    at i = v V.! min i (V.length v - 1)

-- | Fill the audio device's buffer from the queue, with silence if the
-- queue runs dry.
speaker :: IORef (Seq Float) -> SDL.AudioFormat a -> MV.IOVector a -> IO ()
speaker queue SDL.FloatingLEAudio buffer = do
  samples <- atomicModifyIORef' queue (swap . Seq.splitAt (MV.length buffer))
  MV.set buffer 0
  sequence_ (Seq.mapWithIndex (MV.write buffer) samples)
speaker _ _ _ = error "nes: the audio device ignored the requested format"

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
