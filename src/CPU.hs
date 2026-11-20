{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoFieldSelectors #-}

-- | The 6502 CPU (the NES's 2A03 without decimal mode), one instruction at a
-- time. Cycles are counted per instruction, not emulated individually.
-- The registers are unboxed mutable variables, so running it allocates
-- little; 'CPU' is a snapshot of them.
module CPU (CPU (..), Registers (..), new, snapshot, reset, step, nmi, irq, trace) where

import Bus (Bus, load, loadWord, store)
import Control.Monad (unless, when)
import Control.Monad.ST (ST)
import Data.Array (Array, listArray, (!), (//))
import Data.Bits (clearBit, complement, setBit, shiftL, shiftR, testBit, xor, (.&.), (.|.))
import Data.Int (Int8)
import Data.Primitive.PrimVar (PrimVar, newPrimVar, readPrimVar, writePrimVar)
import Data.Primitive.Types (Prim)
import Data.Word (Word16, Word8)
import Text.Printf (printf)

data CPU = CPU
  { a, x, y, sp, p :: !Word8,
    pc :: !Word16,
    cycles :: !Int
  }

data Registers s = Registers
  { regA, regX, regY, regSP, regP :: PrimVar s Word8,
    regPC :: PrimVar s Word16,
    clock :: PrimVar s Int
  }

new :: CPU -> ST s (Registers s)
new cpu = Registers <$> newPrimVar cpu.a <*> newPrimVar cpu.x <*> newPrimVar cpu.y <*> newPrimVar cpu.sp <*> newPrimVar cpu.p <*> newPrimVar cpu.pc <*> newPrimVar cpu.cycles

snapshot :: Registers s -> ST s CPU
snapshot r = CPU <$> readPrimVar r.regA <*> readPrimVar r.regX <*> readPrimVar r.regY <*> readPrimVar r.regSP <*> readPrimVar r.regP <*> readPrimVar r.regPC <*> readPrimVar r.clock

reset :: Bus s -> ST s CPU
reset bus = do
  pc <- loadWord bus 0xFFFC
  pure CPU {a = 0, x = 0, y = 0, sp = 0xFD, p = 0x24, pc, cycles = 7}

-- | Answer a non-maskable interrupt, which the PPU raises at vblank.
nmi :: Bus s -> Registers s -> ST s ()
nmi bus r = do
  modify r.clock (+ 7)
  readPrimVar r.regP >>= interrupt bus r 0xFFFA

-- | Answer an interrupt request, unless interrupts are disabled.
irq :: Bus s -> Registers s -> ST s ()
irq bus r = do
  status <- readPrimVar r.regP
  unless (testBit status interruptDisable) $ do
    modify r.clock (+ 7)
    interrupt bus r 0xFFFE status

-- | Push PC and the given status, then jump through a vector.
interrupt :: Bus s -> Registers s -> Word16 -> Word8 -> ST s ()
interrupt bus r vector status = do
  readPrimVar r.regPC >>= pushWord bus r
  push bus r status
  loadWord bus vector >>= writePrimVar r.regPC
  setFlag r interruptDisable True

-- | One line per state, in the columns of nestest.log.
trace :: CPU -> String
trace cpu =
  printf "%04X A:%02X X:%02X Y:%02X P:%02X SP:%02X CYC:%d" cpu.pc cpu.a cpu.x cpu.y cpu.p cpu.sp cpu.cycles

modify :: (Prim a) => PrimVar s a -> (a -> a) -> ST s ()
modify v f = readPrimVar v >>= writePrimVar v . f

-- * Instructions

data Op
  = ADC
  | AND
  | ASL
  | BCC
  | BCS
  | BEQ
  | BIT
  | BMI
  | BNE
  | BPL
  | BRK
  | BVC
  | BVS
  | CLC
  | CLD
  | CLI
  | CLV
  | CMP
  | CPX
  | CPY
  | DEC
  | DEX
  | DEY
  | EOR
  | INC
  | INX
  | INY
  | JMP
  | JSR
  | LDA
  | LDX
  | LDY
  | LSR
  | NOP
  | ORA
  | PHA
  | PHP
  | PLA
  | PLP
  | ROL
  | ROR
  | RTI
  | RTS
  | SBC
  | SEC
  | SED
  | SEI
  | STA
  | STX
  | STY
  | TAX
  | TAY
  | TSX
  | TXA
  | TXS
  | TYA
  deriving (Eq)

data Mode = Imp | Acc | Imm | Zp | ZpX | ZpY | Abs | AbsX | AbsY | Ind | IndX | IndY | Rel
  deriving (Eq)

data Instr = Instr Op Mode Int

-- | Operand bytes following the opcode.
size :: Mode -> Word16
size mode
  | mode `elem` [Imp, Acc] = 0
  | mode `elem` [Abs, AbsX, AbsY, Ind] = 2
  | otherwise = 1

-- | The official opcodes with their base cycle counts. Unofficial opcodes
-- run as one-byte NOPs.
instructions :: Array Word8 Instr
instructions =
  listArray (0, 255) (repeat (Instr NOP Imp 2))
    // [(opcode, Instr op mode n) | (op, variants) <- table, (opcode, mode, n) <- variants]
  where
    table =
      [ (ADC, [(0x69, Imm, 2), (0x65, Zp, 3), (0x75, ZpX, 4), (0x6D, Abs, 4), (0x7D, AbsX, 4), (0x79, AbsY, 4), (0x61, IndX, 6), (0x71, IndY, 5)]),
        (AND, [(0x29, Imm, 2), (0x25, Zp, 3), (0x35, ZpX, 4), (0x2D, Abs, 4), (0x3D, AbsX, 4), (0x39, AbsY, 4), (0x21, IndX, 6), (0x31, IndY, 5)]),
        (ASL, [(0x0A, Acc, 2), (0x06, Zp, 5), (0x16, ZpX, 6), (0x0E, Abs, 6), (0x1E, AbsX, 7)]),
        (BCC, [(0x90, Rel, 2)]),
        (BCS, [(0xB0, Rel, 2)]),
        (BEQ, [(0xF0, Rel, 2)]),
        (BIT, [(0x24, Zp, 3), (0x2C, Abs, 4)]),
        (BMI, [(0x30, Rel, 2)]),
        (BNE, [(0xD0, Rel, 2)]),
        (BPL, [(0x10, Rel, 2)]),
        (BRK, [(0x00, Imp, 7)]),
        (BVC, [(0x50, Rel, 2)]),
        (BVS, [(0x70, Rel, 2)]),
        (CLC, [(0x18, Imp, 2)]),
        (CLD, [(0xD8, Imp, 2)]),
        (CLI, [(0x58, Imp, 2)]),
        (CLV, [(0xB8, Imp, 2)]),
        (CMP, [(0xC9, Imm, 2), (0xC5, Zp, 3), (0xD5, ZpX, 4), (0xCD, Abs, 4), (0xDD, AbsX, 4), (0xD9, AbsY, 4), (0xC1, IndX, 6), (0xD1, IndY, 5)]),
        (CPX, [(0xE0, Imm, 2), (0xE4, Zp, 3), (0xEC, Abs, 4)]),
        (CPY, [(0xC0, Imm, 2), (0xC4, Zp, 3), (0xCC, Abs, 4)]),
        (DEC, [(0xC6, Zp, 5), (0xD6, ZpX, 6), (0xCE, Abs, 6), (0xDE, AbsX, 7)]),
        (DEX, [(0xCA, Imp, 2)]),
        (DEY, [(0x88, Imp, 2)]),
        (EOR, [(0x49, Imm, 2), (0x45, Zp, 3), (0x55, ZpX, 4), (0x4D, Abs, 4), (0x5D, AbsX, 4), (0x59, AbsY, 4), (0x41, IndX, 6), (0x51, IndY, 5)]),
        (INC, [(0xE6, Zp, 5), (0xF6, ZpX, 6), (0xEE, Abs, 6), (0xFE, AbsX, 7)]),
        (INX, [(0xE8, Imp, 2)]),
        (INY, [(0xC8, Imp, 2)]),
        (JMP, [(0x4C, Abs, 3), (0x6C, Ind, 5)]),
        (JSR, [(0x20, Abs, 6)]),
        (LDA, [(0xA9, Imm, 2), (0xA5, Zp, 3), (0xB5, ZpX, 4), (0xAD, Abs, 4), (0xBD, AbsX, 4), (0xB9, AbsY, 4), (0xA1, IndX, 6), (0xB1, IndY, 5)]),
        (LDX, [(0xA2, Imm, 2), (0xA6, Zp, 3), (0xB6, ZpY, 4), (0xAE, Abs, 4), (0xBE, AbsY, 4)]),
        (LDY, [(0xA0, Imm, 2), (0xA4, Zp, 3), (0xB4, ZpX, 4), (0xAC, Abs, 4), (0xBC, AbsX, 4)]),
        (LSR, [(0x4A, Acc, 2), (0x46, Zp, 5), (0x56, ZpX, 6), (0x4E, Abs, 6), (0x5E, AbsX, 7)]),
        (NOP, [(0xEA, Imp, 2)]),
        (ORA, [(0x09, Imm, 2), (0x05, Zp, 3), (0x15, ZpX, 4), (0x0D, Abs, 4), (0x1D, AbsX, 4), (0x19, AbsY, 4), (0x01, IndX, 6), (0x11, IndY, 5)]),
        (PHA, [(0x48, Imp, 3)]),
        (PHP, [(0x08, Imp, 3)]),
        (PLA, [(0x68, Imp, 4)]),
        (PLP, [(0x28, Imp, 4)]),
        (ROL, [(0x2A, Acc, 2), (0x26, Zp, 5), (0x36, ZpX, 6), (0x2E, Abs, 6), (0x3E, AbsX, 7)]),
        (ROR, [(0x6A, Acc, 2), (0x66, Zp, 5), (0x76, ZpX, 6), (0x6E, Abs, 6), (0x7E, AbsX, 7)]),
        (RTI, [(0x40, Imp, 6)]),
        (RTS, [(0x60, Imp, 6)]),
        (SBC, [(0xE9, Imm, 2), (0xE5, Zp, 3), (0xF5, ZpX, 4), (0xED, Abs, 4), (0xFD, AbsX, 4), (0xF9, AbsY, 4), (0xE1, IndX, 6), (0xF1, IndY, 5)]),
        (SEC, [(0x38, Imp, 2)]),
        (SED, [(0xF8, Imp, 2)]),
        (SEI, [(0x78, Imp, 2)]),
        (STA, [(0x85, Zp, 3), (0x95, ZpX, 4), (0x8D, Abs, 4), (0x9D, AbsX, 5), (0x99, AbsY, 5), (0x81, IndX, 6), (0x91, IndY, 6)]),
        (STX, [(0x86, Zp, 3), (0x96, ZpY, 4), (0x8E, Abs, 4)]),
        (STY, [(0x84, Zp, 3), (0x94, ZpX, 4), (0x8C, Abs, 4)]),
        (TAX, [(0xAA, Imp, 2)]),
        (TAY, [(0xA8, Imp, 2)]),
        (TSX, [(0xBA, Imp, 2)]),
        (TXA, [(0x8A, Imp, 2)]),
        (TXS, [(0x9A, Imp, 2)]),
        (TYA, [(0x98, Imp, 2)])
      ]

-- | Execute the instruction at PC.
step :: Bus s -> Registers s -> ST s ()
step bus r = do
  pc <- readPrimVar r.regPC
  Instr op mode base <- (instructions !) <$> load bus pc
  (addr, crossed) <- address bus r pc mode
  -- Indexed reads take an extra cycle when they cross a page.
  let extra = fromEnum (crossed && op `elem` [ADC, AND, CMP, EOR, LDA, LDX, LDY, ORA, SBC])
      next = pc + 1 + size mode
  writePrimVar r.regPC next
  modify r.clock (+ (base + extra))
  execute bus r op mode addr next

-- | The operand's address, and whether indexing crossed a page.
address :: Bus s -> Registers s -> Word16 -> Mode -> ST s (Word16, Bool)
address bus r pc = \case
  Imp -> pure (0, False)
  Acc -> pure (0, False)
  Imm -> pure (at, False)
  Zp -> plain . fromIntegral <$> byte
  ZpX -> (\i b -> plain (fromIntegral (b + i))) <$> readPrimVar r.regX <*> byte
  ZpY -> (\i b -> plain (fromIntegral (b + i))) <$> readPrimVar r.regY <*> byte
  Abs -> plain <$> word
  AbsX -> indexed <$> readPrimVar r.regX <*> word
  AbsY -> indexed <$> readPrimVar r.regY <*> word
  Ind -> plain <$> (word >>= loadWordInPage bus)
  IndX -> do
    i <- readPrimVar r.regX
    plain <$> (byte >>= loadWordInPage bus . fromIntegral . (+ i))
  IndY -> indexed <$> readPrimVar r.regY <*> (byte >>= loadWordInPage bus . fromIntegral)
  Rel -> plain . (\offset -> at + 1 + fromIntegral (fromIntegral offset :: Int8)) <$> byte
  where
    at = pc + 1
    byte = load bus at
    word = loadWord bus at
    plain addr = (addr, False)
    indexed i base = let addr = base + fromIntegral i in (addr, page addr /= page base)

-- | Load a word whose high byte wraps around within the page, as the 6502
-- does for zero-page pointers and for JMP ($xxFF).
loadWordInPage :: Bus s -> Word16 -> ST s Word16
loadWordInPage bus addr = do
  lo <- load bus addr
  hi <- load bus (addr .&. 0xFF00 .|. (addr + 1) .&. 0x00FF)
  pure $! fromIntegral hi `shiftL` 8 .|. fromIntegral lo

page :: Word16 -> Word16
page = (`shiftR` 8)

-- | Run an operation, given its operand's address and the PC after it.
execute :: Bus s -> Registers s -> Op -> Mode -> Word16 -> Word16 -> ST s ()
execute bus r op mode addr pc = case op of
  LDA -> value >>= setA
  LDX -> value >>= setX
  LDY -> value >>= setY
  STA -> readPrimVar r.regA >>= store bus addr
  STX -> readPrimVar r.regX >>= store bus addr
  STY -> readPrimVar r.regY >>= store bus addr
  TAX -> readPrimVar r.regA >>= setX
  TAY -> readPrimVar r.regA >>= setY
  TXA -> readPrimVar r.regX >>= setA
  TYA -> readPrimVar r.regY >>= setA
  TSX -> readPrimVar r.regSP >>= setX
  TXS -> readPrimVar r.regX >>= writePrimVar r.regSP
  ADC -> value >>= add
  SBC -> value >>= add . complement
  AND -> withA (.&.)
  ORA -> withA (.|.)
  EOR -> withA xor
  CMP -> readPrimVar r.regA >>= compareWith
  CPX -> readPrimVar r.regX >>= compareWith
  CPY -> readPrimVar r.regY >>= compareWith
  BIT -> do
    v <- value
    acc <- readPrimVar r.regA
    modify r.regP (\status -> status .&. 0x3F .|. v .&. 0xC0)
    setFlag r zero (acc .&. v == 0)
  INC -> modifyMemory (+ 1)
  DEC -> modifyMemory (subtract 1)
  INX -> readPrimVar r.regX >>= setX . (+ 1)
  INY -> readPrimVar r.regY >>= setY . (+ 1)
  DEX -> readPrimVar r.regX >>= setX . subtract 1
  DEY -> readPrimVar r.regY >>= setY . subtract 1
  ASL -> shift (\_ v -> v `shiftL` 1) 7
  LSR -> shift (\_ v -> v `shiftR` 1) 0
  ROL -> shift (\c v -> v `shiftL` 1 .|. c) 7
  ROR -> shift (\c v -> v `shiftR` 1 .|. c `shiftL` 7) 0
  BCC -> branch (not <$> flag carry)
  BCS -> branch (flag carry)
  BNE -> branch (not <$> flag zero)
  BEQ -> branch (flag zero)
  BPL -> branch (not <$> flag negative)
  BMI -> branch (flag negative)
  BVC -> branch (not <$> flag overflow)
  BVS -> branch (flag overflow)
  CLC -> setFlag r carry False
  SEC -> setFlag r carry True
  CLI -> setFlag r interruptDisable False
  SEI -> setFlag r interruptDisable True
  CLD -> setFlag r decimal False
  SED -> setFlag r decimal True
  CLV -> setFlag r overflow False
  PHA -> readPrimVar r.regA >>= push bus r
  PHP -> readPrimVar r.regP >>= push bus r . (.|. breakBits)
  PLA -> pull bus r >>= setA
  PLP -> pull bus r >>= writePrimVar r.regP . fromStack
  JMP -> writePrimVar r.regPC addr
  JSR -> pushWord bus r (pc - 1) >> writePrimVar r.regPC addr
  RTS -> pullWord bus r >>= writePrimVar r.regPC . (+ 1)
  RTI -> do
    pull bus r >>= writePrimVar r.regP . fromStack
    pullWord bus r >>= writePrimVar r.regPC
  -- BRK skips a padding byte after the opcode.
  BRK -> do
    writePrimVar r.regPC (pc + 1)
    readPrimVar r.regP >>= interrupt bus r 0xFFFE . (.|. breakBits)
  NOP -> pure ()
  where
    value = load bus addr
    setA v = writePrimVar r.regA v >> setZN r v
    setX v = writePrimVar r.regX v >> setZN r v
    setY v = writePrimVar r.regY v >> setZN r v
    flag i = (`testBit` i) <$> readPrimVar r.regP
    carryIn = (\c -> if c then 1 else 0) <$> flag carry
    withA f = do
      v <- value
      acc <- readPrimVar r.regA
      setA (f acc v)
    add v = do
      acc <- readPrimVar r.regA
      c <- carryIn
      let sum16 = fromIntegral acc + fromIntegral v + fromIntegral c :: Word16
          result = fromIntegral sum16
      setA result
      setFlag r overflow (testBit ((acc `xor` result) .&. (v `xor` result)) 7)
      setFlag r carry (sum16 > 0xFF)
    compareWith reg = do
      v <- value
      setZN r (reg - v)
      setFlag r carry (reg >= v)
    modifyMemory f = do
      v <- f <$> value
      store bus addr v
      setZN r v
    -- Shift or rotate; the carry takes the bit shifted out.
    shift f outBit = do
      c <- carryIn
      if mode == Acc
        then do
          v <- readPrimVar r.regA
          setA (f c v)
          setFlag r carry (testBit v outBit)
        else do
          v <- value
          store bus addr (f c v)
          setZN r (f c v)
          setFlag r carry (testBit v outBit)
    -- A taken branch costs a cycle, two if it lands on another page.
    branch condition = do
      taken <- condition
      when taken $ do
        writePrimVar r.regPC addr
        modify r.clock (+ if page addr == page pc then 1 else 2)

-- * Status flags

carry, zero, interruptDisable, decimal, overflow, negative :: Int
carry = 0
zero = 1
interruptDisable = 2
decimal = 3
overflow = 6
negative = 7

-- | Bits 4 and 5 exist only on the stack copy of the status register.
breakBits :: Word8
breakBits = 0x30

fromStack :: Word8 -> Word8
fromStack v = v .&. 0xCF .|. 0x20

setFlag :: Registers s -> Int -> Bool -> ST s ()
setFlag r i on = modify r.regP (\status -> if on then setBit status i else clearBit status i)

setZN :: Registers s -> Word8 -> ST s ()
setZN r v = modify r.regP (\status -> (if testBit v 7 then setBit else clearBit) ((if v == 0 then setBit else clearBit) status zero) negative)

-- * Stack

push :: Bus s -> Registers s -> Word8 -> ST s ()
push bus r v = do
  sp <- readPrimVar r.regSP
  store bus (0x100 + fromIntegral sp) v
  writePrimVar r.regSP (sp - 1)

pull :: Bus s -> Registers s -> ST s Word8
pull bus r = do
  sp <- (+ 1) <$> readPrimVar r.regSP
  writePrimVar r.regSP sp
  load bus (0x100 + fromIntegral sp)

pushWord :: Bus s -> Registers s -> Word16 -> ST s ()
pushWord bus r w = push bus r (fromIntegral (w `shiftR` 8)) >> push bus r (fromIntegral w)

pullWord :: Bus s -> Registers s -> ST s Word16
pullWord bus r = do
  lo <- pull bus r
  hi <- pull bus r
  pure $! fromIntegral hi `shiftL` 8 .|. fromIntegral lo
