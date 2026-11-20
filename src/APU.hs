{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoFieldSelectors #-}

-- | The audio processing unit: two pulse waves, a triangle wave, noise, and
-- delta-modulated samples (the DMC), mixed into output samples, run a few
-- CPU cycles at a time. What the registers and the frame counter set is a
-- pure record; the timers and positions that change every few cycles are
-- unboxed mutable variables, so running it allocates little.
module APU (APU, new, atSpeed, write, readStatus, run, irq, drain) where

import Control.Monad (when)
import Control.Monad.ST (ST)
import Data.Bits (shiftL, shiftR, testBit, xor, (.&.), (.|.))
import Data.List (mapAccumL)
import Data.Maybe (isNothing)
import Data.Primitive.PrimVar (PrimVar, newPrimVar, readPrimVar, writePrimVar)
import Data.Primitive.Types (Prim)
import Data.STRef (STRef, modifySTRef', newSTRef, readSTRef, writeSTRef)
import Data.Word (Word16, Word8)

data APU s = APU
  { settings :: STRef s Settings,
    pulse1Wave, pulse2Wave, triangleWave, noiseWave :: Wave s,
    -- | The cycles until the DMC plays its next bit.
    dmcClock :: PrimVar s Int,
    -- | The CPU cycle the APU has run up to, and the frame counter's.
    cycle, frameCycle :: PrimVar s Int,
    -- | The cycles until the next sample.
    untilSample :: PrimVar s Double,
    -- | The mixed output summed over the cycles since the last sample.
    area :: PrimVar s Float,
    -- | The samples since the last 'drain', and the channels' levels at
    -- each if watched, newest first.
    samples :: STRef s [Float],
    voices :: STRef s [[Int]]
  }

-- | A channel's timer, the cycles until it next clocks the sequencer, and
-- its position in the waveform; for noise, the shift register.
data Wave s = Wave {timer, step :: PrimVar s Int}

data Settings = Settings
  { pulse1, pulse2, triangle, noise :: !Channel,
    dmc :: !DMC,
    -- | The frame counter clocks envelopes, sweeps and length counters.
    fiveStep, irqInhibit, frameIrq :: !Bool,
    -- | Cycles per sample at the console's own speed, and the speed it
    -- runs at (see 'atSpeed').
    cyclesPerSample, speed :: !Double,
    -- | A high-pass filter, as in the console, takes out the DC offset.
    filterGain, lastIn, lastOut :: !Float,
    -- | Whether to keep the channels' levels at each sample, for a look
    -- inside.
    watched :: !Bool
  }

-- | A pulse, triangle or noise channel; each uses only some fields.
data Channel = Channel
  { on :: !Bool,
    -- | The timer's period, as written to the registers (in CPU cycles
    -- for noise).
    period :: !Int,
    -- | The length counter silences the channel when it runs out, unless
    -- halted. Halt doubles as the envelope's loop flag, and for the
    -- triangle as the linear counter's control flag.
    length :: !Int,
    halt :: !Bool,
    duty :: !Int,
    envelope :: !Envelope,
    sweep :: !Sweep,
    linear, linearLoad :: !Int,
    linearReload :: !Bool,
    -- | Noise: short (93-step) instead of long sequences.
    mode :: !Bool
  }

data Envelope = Envelope
  { constant :: !Bool,
    -- | The constant volume, or the decay's period.
    volume :: !Int,
    restart :: !Bool,
    divider, decay :: !Int
  }

-- | Pulse channels bend their pitch with a sweep.
data Sweep = Sweep
  { sweeping, negated, reloading :: !Bool,
    interval, shift, countdown :: !Int,
    -- | Pulse 1 subtracts one more when sweeping down.
    onesComplement :: !Bool
  }

data DMC = DMC
  { irqOn, looping, irqFlag :: !Bool,
    -- | Cycles per output bit.
    rate :: !Int,
    level :: !Int,
    sampleStart, address :: !Word16,
    sampleLength, remaining :: !Int,
    -- | The byte being played and its bits left; the next byte.
    shifter :: !Word8,
    bits :: !Int,
    silent :: !Bool,
    buffer :: !(Maybe Word8)
  }

-- | Given whether to keep the channels' levels, for a look inside, and
-- the CPU's clock rate and the output sample rate, in Hz.
new :: Bool -> Double -> Double -> ST s (APU s)
new watched cpuRate sampleRate = do
  settings <-
    newSTRef
      Settings
        { pulse1 = silence {sweep = silence.sweep {onesComplement = True}},
          pulse2 = silence,
          triangle = silence,
          noise = silence {period = 4},
          dmc =
            DMC
              { irqOn = False,
                looping = False,
                irqFlag = False,
                rate = 428,
                level = 0,
                sampleStart = 0xC000,
                address = 0xC000,
                sampleLength = 1,
                remaining = 0,
                shifter = 0,
                bits = 8,
                silent = True,
                buffer = Nothing
              },
          fiveStep = False,
          irqInhibit = False,
          frameIrq = False,
          cyclesPerSample = cpuRate / sampleRate,
          speed = 1,
          filterGain = realToFrac (rc / (rc + 1 / sampleRate)),
          lastIn = 0,
          lastOut = 0,
          watched
        }
  let wave start = Wave <$> newPrimVar 1 <*> newPrimVar start
  pulse1Wave <- wave 0
  pulse2Wave <- wave 0
  triangleWave <- wave 0
  noiseWave <- wave 1
  dmcClock <- newPrimVar 428
  now <- newPrimVar 0
  frameCycle <- newPrimVar 0
  untilSample <- newPrimVar (cpuRate / sampleRate)
  area <- newPrimVar 0
  samples <- newSTRef []
  voices <- newSTRef []
  pure APU {settings, pulse1Wave, pulse2Wave, triangleWave, noiseWave, dmcClock, cycle = now, frameCycle, untilSample, area, samples, voices}
  where
    rc = 1 / (2 * pi * 90) -- a 90 Hz cutoff
    silence =
      Channel
        { on = False,
          period = 0,
          length = 0,
          halt = False,
          duty = 0,
          envelope = Envelope {constant = False, volume = 0, restart = False, divider = 0, decay = 0},
          sweep = Sweep {sweeping = False, negated = False, reloading = False, interval = 0, shift = 0, countdown = 0, onesComplement = False},
          linear = 0,
          linearLoad = 0,
          linearReload = False,
          mode = False
        }

-- | Run at this multiple of the console's speed, relative to the sound
-- card: above 1, the same cycles make fewer samples, which then play
-- faster.
atSpeed :: APU s -> Double -> ST s ()
atSpeed apu speed = modifySTRef' apu.settings (\s -> s {speed})

-- * Registers $4000–$4017

write :: APU s -> Word16 -> Word8 -> ST s ()
write apu addr value = do
  -- The pulses restart their waveform, and the frame counter its count.
  when (addr == 0x4003) (writePrimVar apu.pulse1Wave.step 0)
  when (addr == 0x4007) (writePrimVar apu.pulse2Wave.step 0)
  when (addr == 0x4017) (writePrimVar apu.frameCycle 0)
  modifySTRef' apu.settings (setRegister addr value)

setRegister :: Word16 -> Word8 -> Settings -> Settings
setRegister addr value s
  | addr < 0x4004 = s {pulse1 = pulseRegister r v s.pulse1}
  | addr < 0x4008 = s {pulse2 = pulseRegister r v s.pulse2}
  | addr < 0x400C = s {triangle = triangleRegister r v s.triangle}
  | addr < 0x4010 = s {noise = noiseRegister r v s.noise}
  | addr < 0x4014 = s {dmc = dmcRegister r v s.dmc}
  | addr == 0x4015 =
      s
        { pulse1 = enable 0 s.pulse1,
          pulse2 = enable 1 s.pulse2,
          triangle = enable 2 s.triangle,
          noise = enable 3 s.noise,
          dmc = enableDmc s.dmc
        }
  | addr == 0x4017 =
      let s' = s {fiveStep = testBit v 7, irqInhibit = testBit v 6, frameIrq = s.frameIrq && not (testBit v 6)}
       in if s'.fiveStep then halfFrame (quarterFrame s') else s'
  | otherwise = s
  where
    r = addr .&. 3
    v = fromIntegral value :: Int
    enable i c = if testBit v i then c {on = True} else c {on = False, length = 0}
    enableDmc d
      | not (testBit v 4) = d {remaining = 0, irqFlag = False}
      | d.remaining == 0 = d {address = d.sampleStart, remaining = d.sampleLength, irqFlag = False}
      | otherwise = d {irqFlag = False}

pulseRegister :: Word16 -> Int -> Channel -> Channel
pulseRegister r v c = case r of
  0 -> c {duty = v `shiftR` 6, halt = testBit v 5, envelope = c.envelope {constant = testBit v 4, volume = v .&. 15}}
  1 -> c {sweep = c.sweep {sweeping = testBit v 7, interval = v `shiftR` 4 .&. 7, negated = testBit v 3, shift = v .&. 7, reloading = True}}
  2 -> c {period = c.period .&. 0x700 .|. v}
  _ -> (loadLength v c) {period = c.period .&. 0xFF .|. (v .&. 7) `shiftL` 8, envelope = c.envelope {restart = True}}

triangleRegister :: Word16 -> Int -> Channel -> Channel
triangleRegister r v c = case r of
  0 -> c {halt = testBit v 7, linearLoad = v .&. 0x7F}
  1 -> c
  2 -> c {period = c.period .&. 0x700 .|. v}
  _ -> (loadLength v c) {period = c.period .&. 0xFF .|. (v .&. 7) `shiftL` 8, linearReload = True}

noiseRegister :: Word16 -> Int -> Channel -> Channel
noiseRegister r v c = case r of
  0 -> c {halt = testBit v 5, envelope = c.envelope {constant = testBit v 4, volume = v .&. 15}}
  1 -> c
  2 -> c {mode = testBit v 7, period = noisePeriods !! (v .&. 15)}
  _ -> (loadLength v c) {envelope = c.envelope {restart = True}}

dmcRegister :: Word16 -> Int -> DMC -> DMC
dmcRegister r v d = case r of
  0 -> d {irqOn = testBit v 7, looping = testBit v 6, rate = dmcRates !! (v .&. 15), irqFlag = d.irqFlag && testBit v 7}
  1 -> d {level = v .&. 0x7F}
  2 -> d {sampleStart = 0xC000 + fromIntegral v * 64}
  _ -> d {sampleLength = v * 16 + 1}

loadLength :: Int -> Channel -> Channel
loadLength v c = if c.on then c {length = lengths !! (v `shiftR` 3)} else c

-- | The $4015 status: which channels are still sounding, and the IRQ
-- flags. Reading it acknowledges the frame IRQ.
readStatus :: APU s -> ST s Word8
readStatus apu = do
  s <- readSTRef apu.settings
  writeSTRef apu.settings s {frameIrq = False}
  pure $
    sum
      [ v
      | (v, active) <-
          [ (0x01, s.pulse1.length > 0),
            (0x02, s.pulse2.length > 0),
            (0x04, s.triangle.length > 0),
            (0x08, s.noise.length > 0),
            (0x10, s.dmc.remaining > 0),
            (0x40, s.frameIrq),
            (0x80, s.dmc.irqFlag)
          ],
        active
      ]

-- | Whether the APU requests an interrupt.
irq :: APU s -> ST s Bool
irq apu = (\s -> s.frameIrq || s.dmc.irqFlag) <$> readSTRef apu.settings

-- | Take the sound made so far, oldest first: the samples, and the
-- channels' levels at each (pulse 1, pulse 2, triangle and noise from 0 to
-- 15, the DMC from 0 to 127).
drain :: APU s -> ST s ([Float], [[Int]])
drain apu = do
  s <- readSTRef apu.settings
  samples <- readSTRef apu.samples
  voices <- readSTRef apu.voices
  let highPass (i, o) x = let o' = s.filterGain * (o + x - i) in ((x, o'), o')
      ((lastIn, lastOut), sound) = mapAccumL highPass (s.lastIn, s.lastOut) (reverse samples)
  writeSTRef apu.settings s {lastIn, lastOut}
  writeSTRef apu.samples []
  writeSTRef apu.voices []
  pure (sound, reverse voices)

-- * Running

-- | Run up to the given CPU cycle. The DMC reads its samples from
-- program ROM, as the CPU sees it.
run :: APU s -> (Word16 -> Word8) -> Int -> ST s ()
run apu rom target = do
  n <- (target -) <$> readPrimVar apu.cycle
  when (n > 0) $ do
    s <- readSTRef apu.settings
    frameCycle <- readPrimVar apu.frameCycle
    untilSample <- readPrimVar apu.untilSample
    timers <- mapM readPrimVar [apu.pulse1Wave.timer, apu.pulse2Wave.timer, apu.triangleWave.timer, apu.dmcClock]
    level <- mix <$> levels apu
    -- Only noise changes level within these k cycles.
    let k = minimum (n : nextStep s.fiveStep frameCycle - frameCycle : ceiling untilSample : changes s timers)
    advance apu rom s k
    frameStep apu
    output apu k level
    run apu rom target

-- | The cycles at which the frame counter clocks the channels; at the
-- last, it starts over.
steps :: Bool -> [Int]
steps five = if five then [7457, 14913, 22371, 37281, 37282] else [7457, 14913, 22371, 29829, 29830]

nextStep :: Bool -> Int -> Int
nextStep five frameCycle = minimum [s | s <- steps five, s > frameCycle]

frameStep :: APU s -> ST s ()
frameStep apu = do
  c <- readPrimVar apu.frameCycle
  five <- (.fiveStep) <$> readSTRef apu.settings
  when (c `elem` steps five) $ do
    modifySTRef' apu.settings (clockFrame c)
    when (c == last (steps five)) (writePrimVar apu.frameCycle 0)

-- | What the frame counter clocks at a cycle.
clockFrame :: Int -> Settings -> Settings
clockFrame c s = case c of
  7457 -> quarterFrame s
  14913 -> halfFrame (quarterFrame s)
  22371 -> quarterFrame s
  29829 | not s.fiveStep -> (halfFrame (quarterFrame s)) {frameIrq = s.frameIrq || not s.irqInhibit}
  37281 -> halfFrame (quarterFrame s)
  _ -> s

-- | Envelopes and the triangle's linear counter.
quarterFrame :: Settings -> Settings
quarterFrame s =
  s
    { pulse1 = clockEnvelope s.pulse1,
      pulse2 = clockEnvelope s.pulse2,
      triangle = clockLinear s.triangle,
      noise = clockEnvelope s.noise
    }

-- | Length counters and sweeps.
halfFrame :: Settings -> Settings
halfFrame s =
  s
    { pulse1 = clockSweep (clockLength s.pulse1),
      pulse2 = clockSweep (clockLength s.pulse2),
      triangle = clockLength s.triangle,
      noise = clockLength s.noise
    }

clockEnvelope :: Channel -> Channel
clockEnvelope c = c {envelope = clocked c.envelope}
  where
    clocked e
      | e.restart = e {restart = False, decay = 15, divider = e.volume}
      | e.divider > 0 = e {divider = e.divider - 1}
      | e.decay > 0 = e {divider = e.volume, decay = e.decay - 1}
      | c.halt = e {divider = e.volume, decay = 15}
      | otherwise = e {divider = e.volume}

clockLinear :: Channel -> Channel
clockLinear c = c {linear = linear, linearReload = c.linearReload && c.halt}
  where
    linear
      | c.linearReload = c.linearLoad
      | otherwise = max 0 (c.linear - 1)

clockLength :: Channel -> Channel
clockLength c = if c.length > 0 && not c.halt then c {length = c.length - 1} else c

clockSweep :: Channel -> Channel
clockSweep c
  | s.countdown == 0 || s.reloading = swept {sweep = s {countdown = s.interval, reloading = False}}
  | otherwise = swept {sweep = s {countdown = s.countdown - 1}}
  where
    s = c.sweep
    swept
      | s.countdown == 0 && s.sweeping && s.shift > 0 && not (muted c) = c {period = sweptPeriod c}
      | otherwise = c

-- | Where the sweep takes the period next.
sweptPeriod :: Channel -> Int
sweptPeriod c
  | c.sweep.negated = c.period - change - fromEnum c.sweep.onesComplement
  | otherwise = c.period + change
  where
    change = c.period `shiftR` c.sweep.shift

-- | Too high or too low a pulse is silenced.
muted :: Channel -> Bool
muted c = c.period < 8 || sweptPeriod c > 0x7FF

-- | Run the channels' timers for n cycles.
advance :: APU s -> (Word16 -> Word8) -> Settings -> Int -> ST s ()
advance apu rom s n = do
  sequencer apu.pulse1Wave 8 (2 * (s.pulse1.period + 1))
  sequencer apu.pulse2Wave 8 (2 * (s.pulse2.period + 1))
  when (playing s.triangle) (sequencer apu.triangleWave 32 (s.triangle.period + 1))
  noiseTicks <- countDown apu.noiseWave.timer s.noise.period
  modify apu.noiseWave.step (applyTimes noiseTicks shiftNoise)
  dmcTicks <- countDown apu.dmcClock s.dmc.rate
  when (dmcTicks > 0 || fetching s.dmc) $
    modifySTRef' apu.settings (\s' -> s' {dmc = applyTimes dmcTicks (playBit rom) (fetch rom s'.dmc)})
  modify apu.cycle (+ n)
  modify apu.frameCycle (+ n)
  modify apu.untilSample (subtract (fromIntegral n))
  where
    sequencer c len period = do
      ticks <- countDown c.timer period
      modify c.step (\i -> (i + ticks) `mod` len)
    shiftNoise r = r `shiftR` 1 .|. ((r `xor` r `shiftR` (if s.noise.mode then 6 else 1)) .&. 1) `shiftL` 14
    -- Count a timer with the given period down by n cycles, and return
    -- how often it expired.
    countDown timer period = do
      t <- readPrimVar timer
      if n < t
        then 0 <$ writePrimVar timer (t - n)
        else (n - t) `div` period + 1 <$ writePrimVar timer (period - (n - t) `mod` period)

modify :: (Prim a) => PrimVar s a -> (a -> a) -> ST s ()
modify v f = readPrimVar v >>= writePrimVar v . f

-- | Apply a function n times.
applyTimes :: Int -> (a -> a) -> a -> a
applyTimes n f x
  | n <= 0 = x
  | otherwise = applyTimes (n - 1) f $! f x

-- | The triangle pauses rather than play inaudibly high notes.
playing :: Channel -> Bool
playing t = t.length > 0 && t.linear > 0 && t.period >= 2

-- | The cycles until each audible channel's timer next clocks it, which may
-- change its level, given the timers of the pulses, the triangle and the
-- DMC. Noise is left out: it can change every 4 cycles, which would cost a
-- lot, and noise that folds back is still just noise.
changes :: Settings -> [Int] -> [Int]
changes s timers =
  [t | (c, t) <- zip [s.pulse1, s.pulse2] timers, c.length > 0, not (muted c)]
    ++ [timers !! 2 | playing s.triangle]
    ++ [timers !! 3 | not s.dmc.silent]

-- | Play the DMC's next bit: move the level up or down by 2.
playBit :: (Word16 -> Word8) -> DMC -> DMC
playBit rom d = fetch rom (next shifted)
  where
    played
      | d.silent = d
      | testBit d.shifter 0 = d {level = if d.level <= 125 then d.level + 2 else d.level}
      | otherwise = d {level = if d.level >= 2 then d.level - 2 else d.level}
    shifted = played {shifter = played.shifter `shiftR` 1, bits = played.bits - 1}
    next s
      | s.bits > 0 = s
      | otherwise = case s.buffer of
          Just b -> s {bits = 8, shifter = b, silent = False, buffer = Nothing}
          Nothing -> s {bits = 8, silent = True}

-- | Whether the DMC's buffer is empty and there's a byte to fetch.
fetching :: DMC -> Bool
fetching d = isNothing d.buffer && d.remaining > 0

-- | Fetch the sample's next byte when the buffer is empty; at the end,
-- loop or raise an IRQ.
fetch :: (Word16 -> Word8) -> DMC -> DMC
fetch rom d
  | fetching d = ended d {buffer = Just (rom d.address), address = d.address + 1 .|. 0x8000, remaining = d.remaining - 1}
  | otherwise = d
  where
    ended e
      | e.remaining > 0 = e
      | e.looping = e {address = e.sampleStart, remaining = e.sampleLength}
      | otherwise = e {irqFlag = e.irqOn}

-- * Output

-- | Add the level over the last k cycles to the sample being made, and
-- finish the sample when it's due. Each sample is the average level over
-- its cycles, not the level at one moment, so notes too high for the
-- sample rate don't fold back as false, harsh tones (aliasing).
output :: APU s -> Int -> Float -> ST s ()
output apu k level = do
  untilSample <- readPrimVar apu.untilSample
  area <- readPrimVar apu.area
  if untilSample > 0
    then writePrimVar apu.area (area + level * fromIntegral k)
    else do
      s <- readSTRef apu.settings
      -- The cycles past the sample's end, which count towards the next.
      let over = realToFrac (negate untilSample)
          period = s.cyclesPerSample * s.speed
          sample = (area + level * (fromIntegral k - over)) / realToFrac period
      sample `seq` modifySTRef' apu.samples (sample :)
      when s.watched $ do
        voices <- levels apu
        modifySTRef' apu.voices (voices :)
      writePrimVar apu.area (level * over)
      writePrimVar apu.untilSample (untilSample + period)

-- | The channels' levels combined, the console's non-linear way.
mix :: [Int] -> Float
mix voices = pulses + others
  where
    p = fromIntegral (sum (take 2 voices))
    pulses = if p == 0 then 0 else 95.88 / (8128 / p + 100)
    tnd = sum (zipWith (\v w -> fromIntegral v / w) (drop 2 voices) [8227, 12241, 22638])
    others = if tnd == 0 then 0 else 159.79 / (1 / tnd + 100)

-- | The channels' levels now.
levels :: APU s -> ST s [Int]
levels apu = do
  s <- readSTRef apu.settings
  p1 <- readPrimVar apu.pulse1Wave.step
  p2 <- readPrimVar apu.pulse2Wave.step
  t <- readPrimVar apu.triangleWave.step
  n <- readPrimVar apu.noiseWave.step
  pure [pulse s.pulse1 p1, pulse s.pulse2 p2, triangleLevel t, noiseLevel s.noise n, s.dmc.level]
  where
    pulse c i
      | c.length == 0 || muted c || not (testBit (dutyCycles !! c.duty) (7 - i)) = 0
      | otherwise = volume c
    triangleLevel i = if i < 16 then 15 - i else i - 16
    noiseLevel c i = if c.length == 0 || testBit i 0 then 0 else volume c
    volume c = if c.envelope.constant then c.envelope.volume else c.envelope.decay

-- * Tables (NTSC)

dutyCycles :: [Int]
dutyCycles = [0x40, 0x60, 0x78, 0x9F]

lengths :: [Int]
lengths = [10, 254, 20, 2, 40, 4, 80, 6, 160, 8, 60, 10, 14, 12, 26, 14, 12, 16, 24, 18, 48, 20, 96, 22, 192, 24, 72, 26, 16, 28, 32, 30]

noisePeriods :: [Int]
noisePeriods = [4, 8, 16, 32, 64, 96, 128, 160, 202, 254, 380, 508, 762, 1016, 2034, 4068]

dmcRates :: [Int]
dmcRates = [428, 380, 340, 320, 286, 254, 226, 214, 190, 160, 142, 128, 106, 84, 72, 54]
