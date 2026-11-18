{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoFieldSelectors #-}

-- | The audio processing unit: two pulse waves, a triangle wave, noise, and
-- delta-modulated samples (the DMC), mixed into output samples. A pure
-- state machine, run a few CPU cycles at a time.
module APU (APU, new, write, readStatus, run, irq, drain) where

import Cartridge (Cartridge, prgByte)
import Data.Bits (shiftL, shiftR, testBit, xor, (.&.), (.|.))
import Data.List (mapAccumL)
import Data.Maybe (isNothing)
import Data.Word (Word16, Word8)

data APU = APU
  { pulse1, pulse2, triangle, noise :: !Channel,
    dmc :: !DMC,
    -- | The frame counter clocks envelopes, sweeps and length counters.
    fiveStep, irqInhibit, frameIrq :: !Bool,
    frameCycle :: !Int,
    -- | The CPU cycle the APU has run up to.
    cycle :: !Int,
    cyclesPerSample, untilSample :: !Double,
    -- | A high-pass filter, as in the console, takes out the DC offset.
    filterGain, lastIn, lastOut :: !Float,
    -- | The channels' levels at each sample since the last 'drain', newest
    -- first.
    voices :: [[Int]]
  }

-- | A pulse, triangle or noise channel; each uses only some fields.
data Channel = Channel
  { on :: !Bool,
    -- | The timer's period, as written to the registers (in CPU cycles
    -- for noise), and the cycles until it next clocks the sequencer.
    period, timer :: !Int,
    -- | The length counter silences the channel when it runs out, unless
    -- halted. Halt doubles as the envelope's loop flag, and for the
    -- triangle as the linear counter's control flag.
    length :: !Int,
    halt :: !Bool,
    -- | The position in the waveform; for noise, the shift register.
    step :: !Int,
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
    -- | Cycles per output bit, and cycles until the next one.
    rate, clock :: !Int,
    level :: !Int,
    sampleStart, address :: !Word16,
    sampleLength, remaining :: !Int,
    -- | The byte being played and its bits left; the next byte.
    shifter :: !Word8,
    bits :: !Int,
    silent :: !Bool,
    buffer :: !(Maybe Word8)
  }

-- | Given the CPU's clock rate and the output sample rate, in Hz.
new :: Double -> Double -> APU
new cpuRate sampleRate =
  APU
    { pulse1 = silence {sweep = silence.sweep {onesComplement = True}},
      pulse2 = silence,
      triangle = silence,
      noise = silence {period = 4, step = 1},
      dmc =
        DMC
          { irqOn = False,
            looping = False,
            irqFlag = False,
            rate = 428,
            clock = 428,
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
      frameCycle = 0,
      cycle = 0,
      cyclesPerSample = cpuRate / sampleRate,
      untilSample = cpuRate / sampleRate,
      filterGain = realToFrac (rc / (rc + 1 / sampleRate)),
      lastIn = 0,
      lastOut = 0,
      voices = []
    }
  where
    rc = 1 / (2 * pi * 90) -- a 90 Hz cutoff
    silence =
      Channel
        { on = False,
          period = 0,
          timer = 1,
          length = 0,
          halt = False,
          step = 0,
          duty = 0,
          envelope = Envelope {constant = False, volume = 0, restart = False, divider = 0, decay = 0},
          sweep = Sweep {sweeping = False, negated = False, reloading = False, interval = 0, shift = 0, countdown = 0, onesComplement = False},
          linear = 0,
          linearLoad = 0,
          linearReload = False,
          mode = False
        }

-- * Registers $4000–$4017

write :: Word16 -> Word8 -> APU -> APU
write addr value apu
  | addr < 0x4004 = apu {pulse1 = pulseRegister r v apu.pulse1}
  | addr < 0x4008 = apu {pulse2 = pulseRegister r v apu.pulse2}
  | addr < 0x400C = apu {triangle = triangleRegister r v apu.triangle}
  | addr < 0x4010 = apu {noise = noiseRegister r v apu.noise}
  | addr < 0x4014 = apu {dmc = dmcRegister r v apu.dmc}
  | addr == 0x4015 =
      apu
        { pulse1 = enable 0 apu.pulse1,
          pulse2 = enable 1 apu.pulse2,
          triangle = enable 2 apu.triangle,
          noise = enable 3 apu.noise,
          dmc = enableDmc apu.dmc
        }
  | addr == 0x4017 =
      let apu' = apu {fiveStep = testBit v 7, irqInhibit = testBit v 6, frameIrq = apu.frameIrq && not (testBit v 6), frameCycle = 0}
       in if apu'.fiveStep then halfFrame (quarterFrame apu') else apu'
  | otherwise = apu
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
  _ -> (loadLength v c) {period = c.period .&. 0xFF .|. (v .&. 7) `shiftL` 8, step = 0, envelope = c.envelope {restart = True}}

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
readStatus :: APU -> (Word8, APU)
readStatus apu = (status, apu {frameIrq = False})
  where
    status =
      sum
        [ v
        | (v, active) <-
            [ (0x01, apu.pulse1.length > 0),
              (0x02, apu.pulse2.length > 0),
              (0x04, apu.triangle.length > 0),
              (0x08, apu.noise.length > 0),
              (0x10, apu.dmc.remaining > 0),
              (0x40, apu.frameIrq),
              (0x80, apu.dmc.irqFlag)
            ],
          active
        ]

-- | Whether the APU requests an interrupt.
irq :: APU -> Bool
irq apu = apu.frameIrq || apu.dmc.irqFlag

-- | Take the sound made so far, oldest first: the samples, and the
-- channels' levels at each (pulse 1, pulse 2, triangle and noise from 0 to
-- 15, the DMC from 0 to 127).
drain :: APU -> ([Float], [[Int]], APU)
drain apu = (sound, voices, apu {voices = [], lastIn, lastOut})
  where
    voices = reverse apu.voices
    ((lastIn, lastOut), sound) = mapAccumL highPass (apu.lastIn, apu.lastOut) (map mix voices)
    highPass (i, o) x = let o' = apu.filterGain * (o + x - i) in ((x, o'), o')

-- * Running

-- | Run up to the given CPU cycle. The DMC reads its samples from the
-- cartridge.
run :: Cartridge -> Int -> APU -> APU
run cart target apu
  | n <= 0 = apu
  | otherwise = run cart target (sampleIfDue (frameStep (advance cart k apu)))
  where
    n = target - apu.cycle
    k = minimum [n, nextStep apu - apu.frameCycle, ceiling apu.untilSample]

-- | The cycles at which the frame counter clocks the channels; at the
-- last, it starts over.
steps :: Bool -> [Int]
steps five = if five then [7457, 14913, 22371, 37281, 37282] else [7457, 14913, 22371, 29829, 29830]

nextStep :: APU -> Int
nextStep apu = minimum [s | s <- steps apu.fiveStep, s > apu.frameCycle]

frameStep :: APU -> APU
frameStep apu = case apu.frameCycle of
  7457 -> quarterFrame apu
  14913 -> halfFrame (quarterFrame apu)
  22371 -> quarterFrame apu
  29829 | not apu.fiveStep -> (halfFrame (quarterFrame apu)) {frameIrq = apu.frameIrq || not apu.irqInhibit}
  37281 -> halfFrame (quarterFrame apu)
  c | c == last (steps apu.fiveStep) -> apu {frameCycle = 0}
  _ -> apu

-- | Envelopes and the triangle's linear counter.
quarterFrame :: APU -> APU
quarterFrame apu =
  apu
    { pulse1 = clockEnvelope apu.pulse1,
      pulse2 = clockEnvelope apu.pulse2,
      triangle = clockLinear apu.triangle,
      noise = clockEnvelope apu.noise
    }

-- | Length counters and sweeps.
halfFrame :: APU -> APU
halfFrame apu =
  apu
    { pulse1 = clockSweep (clockLength apu.pulse1),
      pulse2 = clockSweep (clockLength apu.pulse2),
      triangle = clockLength apu.triangle,
      noise = clockLength apu.noise
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
advance :: Cartridge -> Int -> APU -> APU
advance cart n apu =
  apu
    { pulse1 = sequencer 8 (2 * (apu.pulse1.period + 1)) apu.pulse1,
      pulse2 = sequencer 8 (2 * (apu.pulse2.period + 1)) apu.pulse2,
      -- The triangle pauses rather than play inaudibly high notes.
      triangle = if t.length > 0 && t.linear > 0 && t.period >= 2 then sequencer 32 (t.period + 1) t else t,
      noise =
        let (timer, ticks) = countDown apu.noise.period n apu.noise.timer
         in apu.noise {timer, step = iterate shiftNoise apu.noise.step !! ticks},
      dmc =
        let (clock, ticks) = countDown apu.dmc.rate n apu.dmc.clock
         in iterate (playBit cart) (fetch cart apu.dmc {clock}) !! ticks,
      frameCycle = apu.frameCycle + n,
      cycle = apu.cycle + n,
      untilSample = apu.untilSample - fromIntegral n
    }
  where
    t = apu.triangle
    sequencer len cycles c =
      let (timer, ticks) = countDown cycles n c.timer
       in c {timer, step = (c.step + ticks) `mod` len}
    shiftNoise r = r `shiftR` 1 .|. ((r `xor` r `shiftR` (if apu.noise.mode then 6 else 1)) .&. 1) `shiftL` 14

-- | Count a timer with the given period down by n cycles: the cycles left
-- until it next expires, and how often it expired.
countDown :: Int -> Int -> Int -> (Int, Int)
countDown period n timer
  | n < timer = (timer - n, 0)
  | otherwise = (period - (n - timer) `mod` period, (n - timer) `div` period + 1)

-- | Play the DMC's next bit: move the level up or down by 2.
playBit :: Cartridge -> DMC -> DMC
playBit cart d = fetch cart (next shifted)
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

-- | Fetch the sample's next byte when the buffer is empty; at the end,
-- loop or raise an IRQ.
fetch :: Cartridge -> DMC -> DMC
fetch cart d
  | isNothing d.buffer && d.remaining > 0 = ended d {buffer = Just (prgByte cart d.address), address = d.address + 1 .|. 0x8000, remaining = d.remaining - 1}
  | otherwise = d
  where
    ended e
      | e.remaining > 0 = e
      | e.looping = e {address = e.sampleStart, remaining = e.sampleLength}
      | otherwise = e {irqFlag = e.irqOn}

-- * Output

sampleIfDue :: APU -> APU
sampleIfDue apu
  | apu.untilSample > 0 = apu
  | otherwise = apu {voices = levels apu : apu.voices, untilSample = apu.untilSample + apu.cyclesPerSample}

-- | The channels' levels combined, the console's non-linear way.
mix :: [Int] -> Float
mix voices = pulses + others
  where
    p = fromIntegral (sum (take 2 voices))
    pulses = if p == 0 then 0 else 95.88 / (8128 / p + 100)
    tnd = sum (zipWith (\v w -> fromIntegral v / w) (drop 2 voices) [8227, 12241, 22638])
    others = if tnd == 0 then 0 else 159.79 / (1 / tnd + 100)

-- | The channels' levels now.
levels :: APU -> [Int]
levels apu = [pulse apu.pulse1, pulse apu.pulse2, triangleLevel apu.triangle, noiseLevel apu.noise, apu.dmc.level]
  where
    pulse c
      | c.length == 0 || muted c || not (testBit (dutyCycles !! c.duty) (7 - c.step)) = 0
      | otherwise = volume c
    triangleLevel c = if c.step < 16 then 15 - c.step else c.step - 16
    noiseLevel c = if c.length == 0 || testBit c.step 0 then 0 else volume c
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
