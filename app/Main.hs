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
import Data.Vector.Storable qualified as SV
import Data.Vector.Storable.Mutable qualified as MV
import Foreign (nullPtr, peek, with)
import NES (Button, Cartridge, Frame, Input (..), Palette, defaultPalette, frameRate, frames, nestest, parseCartridge, parsePalette, sampleRate, visualsSize)
import NES qualified
import SDL qualified
import SDL.Internal.Types (Window (..))
import SDL.Raw qualified as Raw
import System.Environment (getArgs)
import System.Exit (die)

main :: IO ()
main = do
  args <- getArgs
  case valued "--palette" args of
    (_, ["--nestest", rom]) -> load parseCartridge rom >>= mapM_ putStrLn . nestest
    (file, rest)
      | (given, [rom]) <- partition (`elem` flags) rest,
        let on flag = flag `elem` given -> do
          palette <- maybe (pure defaultPalette) (load parsePalette) file
          load parseCartridge rom
            >>= play
              Options
                { debug = on "--debug",
                  vsync = on "--vsync",
                  pause = on "--pause",
                  crt = on "--crt",
                  mask = on "--mask",
                  noFlicker = on "--no-flicker",
                  fullscreen = on "--fullscreen",
                  wide = on "--wide",
                  smooth = on "--smooth",
                  ghost = on "--ghost",
                  palette
                }
    _ -> die ("usage: nes " ++ unwords ["[" ++ flag ++ "]" | flag <- flags] ++ " [--palette <file.pal>] <rom.nes> | nes --nestest <rom.nes>")

flags :: [String]
flags = ["--debug", "--vsync", "--pause", "--crt", "--mask", "--no-flicker", "--fullscreen", "--wide", "--smooth", "--ghost"]

-- | The value of the option given as @name value@, if any, and the other
-- arguments.
valued :: String -> [String] -> (Maybe String, [String])
valued name (option : value : rest) | option == name = (Just value, rest)
valued name (arg : rest) = (arg :) <$> valued name rest
valued _ [] = (Nothing, [])

data Options = Options {debug, vsync, pause, crt, mask, noFlicker, fullscreen, wide, smooth, ghost :: Bool, palette :: Palette}

load :: (BS.ByteString -> Either String a) -> FilePath -> IO a
load parse file = BS.readFile file >>= either (die . (("nes: " ++ file ++ ": ") ++)) pure . parse

-- | Play the game in a window, at three times the NES's resolution or
-- scaled to fit it. The sound goes through a queue that the audio device
-- empties at its own pace, and that queue paces the game: each frame waits
-- for it to run low. With vsync on, the screen paces the game instead:
-- each refresh runs the frames due by then, so the game keeps its speed at
-- any refresh rate and is smoothest at 60 or 120 Hz. With debug on, the
-- visuals of what the emulator is doing go beside the game. (In a window
-- of their own, they would upset the vsync.) With pause on, Escape pauses
-- and resumes the game. With crt on, the bottom of every three rows is
-- darker, like the gaps between a CRT's scanlines. With mask on, the three
-- columns of every 3× pixel are tinted red, green and blue, like a CRT's
-- phosphor stripes. With no-flicker on, every sprite on a scanline is
-- drawn, not just the first eight, so games needn't take turns drawing
-- them. With fullscreen on, the window fills
-- the screen. With wide on, the NES's pixels are wider than tall, 8:7, as
-- on a TV. With smooth on, the picture is scaled smoothly from three times
-- the NES's resolution, so its pixels look even at any size. With ghost
-- on, each frame shows blended half and half with the one before, like a
-- CRT's afterglow, so sprites drawn on alternate frames show steady and
-- see-through. The palette gives the RGB of the NES's colours.
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
      across = if options.wide then 878 else 768 -- 768 × 8/7, if wide
      height = if options.debug then max 720 h else 720
      size = SDL.V2 (if options.debug then across + w else across) height
      game = SDL.Rectangle (SDL.P (SDL.V2 0 ((height - 720) `div` 2))) (SDL.V2 across 720)
      gaps = SV.generate 240 (\row -> SDL.Rectangle (SDL.P (SDL.V2 0 (3 * fromIntegral row + 2))) (SDL.V2 768 1))
      -- Each column multiplies the picture by its colour, so most of a
      -- channel shows only in its own column, as through an aperture grille.
      stripes = [(colour, SV.generate 256 (\x -> SDL.Rectangle (SDL.P (SDL.V2 (3 * fromIntegral x + i) 0)) (SDL.V2 1 720))) | (i, colour) <- zip [0 ..] [SDL.V4 255 160 160 255, SDL.V4 160 255 160 255, SDL.V4 160 160 255 255]]
      beside = SDL.Rectangle (SDL.P (SDL.V2 across 0)) (SDL.V2 w h)
  window <-
    SDL.createWindow
      "nes"
      SDL.defaultWindow
        { SDL.windowInitialSize = fromIntegral <$> size,
          SDL.windowResizable = True,
          SDL.windowMode = if options.fullscreen then SDL.FullscreenDesktop else SDL.Windowed
        }
  when options.fullscreen (SDL.cursorVisible SDL.$= False)
  renderer <- SDL.createRenderer window (-1) SDL.defaultRenderer {SDL.rendererType = if options.vsync then SDL.AcceleratedVSyncRenderer else SDL.AcceleratedRenderer}
  -- Draw at this size whatever the window's, with bars around if need be.
  SDL.rendererLogicalSize renderer SDL.$= Just (fromIntegral <$> size)
  SDL.rendererDrawBlendMode renderer SDL.$= SDL.BlendAlphaBlend
  texture <- SDL.createTexture renderer SDL.RGB24 SDL.TextureAccessStreaming (SDL.V2 256 240)
  -- The frame before, laid half see-through over the picture, with ghost on.
  previous <- SDL.createTexture renderer SDL.RGB888 SDL.TextureAccessTarget (SDL.V2 256 240)
  SDL.textureBlendMode previous SDL.$= SDL.BlendAlphaBlend
  SDL.textureAlphaMod previous SDL.$= 128
  -- The picture at three times the NES's resolution, with the CRT's gaps,
  -- before it's scaled to the window: smoothly, it blends only where its
  -- big pixels meet, so they stay sharp.
  screen <- SDL.createTexture renderer SDL.RGB888 SDL.TextureAccessTarget (SDL.V2 768 720)
  SDL.textureScaleMode screen SDL.$= if options.smooth then SDL.ScaleModeLinear else SDL.ScaleModeNearest
  visuals <- SDL.createTexture renderer SDL.RGB888 SDL.TextureAccessStreaming (fromIntegral <$> SDL.V2 w h)
  -- The core reads the buttons for each frame lazily from this channel, so
  -- they must be in it before the frame is drawn.
  inputs <- newChan
  let draw = do
        SDL.rendererRenderTarget renderer SDL.$= Just screen
        SDL.copy renderer texture Nothing Nothing
        when options.ghost (SDL.copy renderer previous Nothing Nothing)
        when options.crt $ do
          SDL.rendererDrawColor renderer SDL.$= SDL.V4 0 0 0 128
          SDL.fillRects renderer gaps
        when options.mask $ do
          SDL.rendererDrawBlendMode renderer SDL.$= SDL.BlendMod
          sequence_ [(SDL.rendererDrawColor renderer SDL.$= colour) >> SDL.fillRects renderer columns | (colour, columns) <- stripes]
          SDL.rendererDrawBlendMode renderer SDL.$= SDL.BlendAlphaBlend
        SDL.rendererRenderTarget renderer SDL.$= Nothing
        SDL.rendererDrawColor renderer SDL.$= SDL.V4 14 16 22 255
        SDL.clear renderer
        SDL.copy renderer screen Nothing (Just (fromIntegral <$> game))
        when options.debug (SDL.copy renderer visuals Nothing (Just (fromIntegral <$> beside)))
        SDL.present renderer -- with vsync, waits for the refresh
      loop paused owed outputs = do
        unless (options.vsync || paused) (drain queue)
        events <- map SDL.eventPayload <$> SDL.pollEvents
        let paused' = paused /= (options.pause && odd (length (filter (pressed SDL.ScancodeEscape) events)))
        unless (SDL.QuitEvent `elem` events) $
          -- Paused, the last frame stays on screen and the sound runs dry.
          if paused'
            then draw >> unless options.vsync (SDL.delay 16) >> loop True owed outputs
            else do
              held <- SDL.getKeyboardState
              -- Without vsync, one frame; with it, as many as are due.
              due <- if options.vsync then (owed +) . perRefresh <$> refreshRate window else pure 1
              let count = floor due
              run count [button | (key, button) <- keys, held key] outputs >>= \case
                Just rest -> draw >> loop False (due - fromIntegral count) rest
                Nothing -> pure ()
      run :: Int -> [Button] -> [Frame] -> IO (Maybe [Frame])
      run 0 _ outputs = pure (Just outputs)
      run count buttons outputs = do
        queued <- Seq.length <$> readIORef queue
        writeChan inputs Input {buttons, speed = if options.vsync then speed queued else 1}
        case outputs of
          out : rest -> do
            atomicModifyIORef' queue (\q -> (q <> Seq.fromList out.sound, ()))
            -- Keep the frame before, as this one replaces it.
            when options.ghost $ do
              SDL.rendererRenderTarget renderer SDL.$= Just previous
              SDL.copy renderer texture Nothing Nothing
              SDL.rendererRenderTarget renderer SDL.$= Nothing
            _ <- SDL.updateTexture texture Nothing out.picture (256 * 3)
            when options.debug (void (SDL.updateTexture visuals Nothing out.visuals (fromIntegral w * 4)))
            run (count - 1) buttons rest
          [] -> pure Nothing
  loop False 0 . frames options.debug (if options.noFlicker then 64 else 8) options.palette cart =<< getChanContents inputs
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

-- | With vsync, game frames per screen refresh. At about k times the NES's
-- frame rate, one every k refreshes, so every frame shows equally long and
-- the sound's speed takes up the difference. Otherwise, the NES's rate, and
-- some frames show for a refresh longer than others.
perRefresh :: Double -> Double
perRefresh hz
  | abs (hz / k / frameRate - 1) < 0.003 = 1 / k
  | otherwise = frameRate / hz
  where
    k = max 1 (fromIntegral (round (hz / frameRate) :: Int))

-- | The refresh rate of the screen the window is on, assumed 60 Hz if SDL
-- doesn't know it.
refreshRate :: SDL.Window -> IO Double
refreshRate (Window window) = do
  display <- Raw.getWindowDisplayIndex window
  with (Raw.DisplayMode 0 0 0 0 nullPtr) $ \mode -> do
    _ <- Raw.getCurrentDisplayMode display mode
    hz <- Raw.displayModeRefreshRate <$> peek mode
    pure (if hz > 0 then fromIntegral hz else 60)

-- | With vsync, the display and the sound card keep slightly different
-- time, so the console runs up to 0.5% faster or slower relative to the
-- sound card (its picture keeps pace with the display) to keep the queue
-- near its target.
speed :: Int -> Double
speed queued = 1 + 0.005 * max (-1) (min 1 (fromIntegral (queued - target) / 1024))

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
