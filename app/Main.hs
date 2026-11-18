{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoFieldSelectors #-}

module Main (main) where

import Control.Concurrent (getChanContents, newChan, writeChan)
import Control.Monad (unless, void, when)
import Data.ByteString qualified as BS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (partition)
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
    _
      | (flags, [rom]) <- partition (`elem` ["--debug", "--vsync", "--pause"]) args,
        let on flag = flag `elem` flags ->
          load rom >>= play Options {debug = on "--debug", vsync = on "--vsync", pause = on "--pause"}
    _ -> die "usage: nes [--debug] [--vsync] [--pause] <rom.nes> | nes --nestest <rom.nes>"

data Options = Options {debug, vsync, pause :: Bool}

load :: FilePath -> IO Cartridge
load rom = BS.readFile rom >>= either (die . ("nes: " ++)) pure . parseCartridge

-- | Play the game in a window, at three times the NES's resolution. The
-- sound goes through a queue that the audio device empties at its own
-- pace, and that queue paces the game: each frame waits for it to run low.
-- With vsync on, the screen paces the game instead: one frame per refresh,
-- smoother but only the right speed on a 60 Hz display. With debug on, the
-- visuals of what the emulator is doing go beside the game. (In a window
-- of their own, they would upset the vsync.) With pause on, Escape pauses
-- and resumes the game.
play :: Options -> Cartridge -> IO ()
play options cart = do
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
      height = if options.debug then max 720 h else 720
      size = SDL.V2 (if options.debug then 768 + w else 768) height
      game = SDL.Rectangle (SDL.P (SDL.V2 0 ((height - 720) `div` 2))) (SDL.V2 768 720)
      beside = SDL.Rectangle (SDL.P (SDL.V2 768 0)) (SDL.V2 w h)
  window <- SDL.createWindow "nes" SDL.defaultWindow {SDL.windowInitialSize = fromIntegral <$> size, SDL.windowResizable = True}
  renderer <- SDL.createRenderer window (-1) SDL.defaultRenderer {SDL.rendererType = if options.vsync then SDL.AcceleratedVSyncRenderer else SDL.AcceleratedRenderer}
  -- Draw at this size whatever the window's, with bars around if need be.
  SDL.rendererLogicalSize renderer SDL.$= Just (fromIntegral <$> size)
  SDL.rendererDrawColor renderer SDL.$= SDL.V4 14 16 22 255
  texture <- SDL.createTexture renderer SDL.RGB24 SDL.TextureAccessStreaming (SDL.V2 256 240)
  visuals <- SDL.createTexture renderer SDL.RGB888 SDL.TextureAccessStreaming (fromIntegral <$> SDL.V2 w h)
  -- The core reads the buttons for each frame lazily from this channel, so
  -- they must be in it before the frame is drawn.
  inputs <- newChan
  let draw = do
        SDL.clear renderer
        SDL.copy renderer texture Nothing (Just (fromIntegral <$> game))
        when options.debug (SDL.copy renderer visuals Nothing (Just (fromIntegral <$> beside)))
        SDL.present renderer -- with vsync, waits for the refresh
      loop paused outputs = do
        unless (options.vsync || paused) (drain queue)
        events <- map SDL.eventPayload <$> SDL.pollEvents
        let paused' = paused /= (options.pause && odd (length (filter (pressed SDL.ScancodeEscape) events)))
        unless (SDL.QuitEvent `elem` events) $
          -- Paused, the last frame stays on screen and the sound runs dry.
          if paused'
            then draw >> unless options.vsync (SDL.delay 16) >> loop True outputs
            else do
              held <- SDL.getKeyboardState
              writeChan inputs [button | (key, button) <- keys, held key]
              case outputs of
                out : rest -> do
                  queued <- Seq.length <$> readIORef queue
                  let sound = Seq.fromList (if options.vsync then resample (speed queued) out.sound else out.sound)
                  atomicModifyIORef' queue (\q -> (q <> sound, ()))
                  _ <- SDL.updateTexture texture Nothing out.picture (256 * 3)
                  when options.debug (void (SDL.updateTexture visuals Nothing out.visuals (fromIntegral w * 4)))
                  draw
                  loop False rest
                [] -> pure ()
  loop False . frames cart =<< getChanContents inputs
  SDL.closeAudioDevice device
  SDL.quit

-- | About this many samples stay queued: enough to ride out a late frame.
target :: Int
target = 2048

-- | Without vsync, wait for the queue to run below its target.
drain :: IORef (Seq Float) -> IO ()
drain queue = do
  queued <- Seq.length <$> readIORef queue
  when (queued >= target) (SDL.delay 1 >> drain queue)

-- | With vsync, the display and the sound card keep slightly different
-- time, so the sound plays up to 0.5% faster or slower to keep the queue
-- near its target.
speed :: Int -> Double
speed queued = 1 + 0.005 * max (-1) (min 1 (fromIntegral (queued - target) / 1024))

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

-- | Whether this event is the key going down, not held and repeating.
pressed :: SDL.Scancode -> SDL.EventPayload -> Bool
pressed key (SDL.KeyboardEvent (SDL.KeyboardEventData _ SDL.Pressed False keysym)) = SDL.keysymScancode keysym == key
pressed _ _ = False

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
