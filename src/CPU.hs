{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoFieldSelectors #-}

-- | The 6502 CPU (the NES's 2A03 without decimal mode), one instruction at a
-- time. Cycles are counted per instruction, not emulated individually.
module CPU (CPU (..), reset, step, nmi, trace) where

import Bus (Bus, load, loadWord, store)
import Control.Monad.ST (ST)
import Data.Array (Array, listArray, (!), (//))
import Data.Bits (clearBit, complement, setBit, shiftL, shiftR, testBit, xor, (.&.), (.|.))
import Data.Int (Int8)
import Data.Word (Word16, Word8)
import Text.Printf (printf)

data CPU = CPU
  { a, x, y, sp, p :: !Word8,
    pc :: !Word16,
    cycles :: !Int
  }

reset :: Bus s -> ST s CPU
reset bus = do
  pc <- loadWord bus 0xFFFC
  pure CPU {a = 0, x = 0, y = 0, sp = 0xFD, p = 0x24, pc, cycles = 7}

-- | Answer a non-maskable interrupt, which the PPU raises at vblank.
nmi :: Bus s -> CPU -> ST s CPU
nmi bus cpu = interrupt bus 0xFFFA cpu.p cpu {cycles = cpu.cycles + 7}

-- | Push PC and the given status, then jump through a vector.
interrupt :: Bus s -> Word16 -> Word8 -> CPU -> ST s CPU
interrupt bus vector status cpu = do
  cpu' <- pushWord bus cpu.pc cpu >>= push bus status
  target <- loadWord bus vector
  pure (setFlag interruptDisable True cpu' {pc = target})

-- | One line per state, in the columns of nestest.log.
trace :: CPU -> String
trace cpu =
  printf "%04X A:%02X X:%02X Y:%02X P:%02X SP:%02X CYC:%d" cpu.pc cpu.a cpu.x cpu.y cpu.p cpu.sp cpu.cycles

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
step :: Bus s -> CPU -> ST s CPU
step bus cpu = do
  Instr op mode base <- (instructions !) <$> load bus cpu.pc
  (addr, crossed) <- address bus cpu mode
  -- Indexed reads take an extra cycle when they cross a page.
  let extra = fromEnum (crossed && op `elem` [ADC, AND, CMP, EOR, LDA, LDX, LDY, ORA, SBC])
  execute bus op mode addr cpu {pc = cpu.pc + 1 + size mode, cycles = cpu.cycles + base + extra}

-- | The operand's address, and whether indexing crossed a page.
address :: Bus s -> CPU -> Mode -> ST s (Word16, Bool)
address bus cpu = \case
  Imp -> pure (0, False)
  Acc -> pure (0, False)
  Imm -> pure (at, False)
  Zp -> plain . fromIntegral <$> byte
  ZpX -> plain . fromIntegral . (+ cpu.x) <$> byte
  ZpY -> plain . fromIntegral . (+ cpu.y) <$> byte
  Abs -> plain <$> word
  AbsX -> indexed cpu.x <$> word
  AbsY -> indexed cpu.y <$> word
  Ind -> plain <$> (word >>= loadWordInPage bus)
  IndX -> plain <$> (byte >>= loadWordInPage bus . fromIntegral . (+ cpu.x))
  IndY -> indexed cpu.y <$> (byte >>= loadWordInPage bus . fromIntegral)
  Rel -> plain . (\offset -> at + 1 + fromIntegral (fromIntegral offset :: Int8)) <$> byte
  where
    at = cpu.pc + 1
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
  pure (fromIntegral hi `shiftL` 8 .|. fromIntegral lo)

page :: Word16 -> Word16
page = (`shiftR` 8)

execute :: Bus s -> Op -> Mode -> Word16 -> CPU -> ST s CPU
execute bus op mode addr cpu = case op of
  LDA -> withValue setA
  LDX -> withValue setX
  LDY -> withValue setY
  STA -> cpu <$ store bus addr cpu.a
  STX -> cpu <$ store bus addr cpu.x
  STY -> cpu <$ store bus addr cpu.y
  TAX -> pure (setX cpu.a)
  TAY -> pure (setY cpu.a)
  TXA -> pure (setA cpu.x)
  TYA -> pure (setA cpu.y)
  TSX -> pure (setX cpu.sp)
  TXS -> pure cpu {sp = cpu.x}
  ADC -> withValue add
  SBC -> withValue (add . complement)
  AND -> withValue (setA . (cpu.a .&.))
  ORA -> withValue (setA . (cpu.a .|.))
  EOR -> withValue (setA . xor cpu.a)
  CMP -> withValue (compareWith cpu.a)
  CPX -> withValue (compareWith cpu.x)
  CPY -> withValue (compareWith cpu.y)
  BIT -> withValue $ \v -> setFlag zero (cpu.a .&. v == 0) cpu {p = cpu.p .&. 0x3F .|. v .&. 0xC0}
  INC -> modify (+ 1)
  DEC -> modify (subtract 1)
  INX -> pure (setX (cpu.x + 1))
  INY -> pure (setY (cpu.y + 1))
  DEX -> pure (setX (cpu.x - 1))
  DEY -> pure (setY (cpu.y - 1))
  ASL -> shift (`shiftL` 1) 7
  LSR -> shift (`shiftR` 1) 0
  ROL -> shift (\v -> v `shiftL` 1 .|. carryIn) 7
  ROR -> shift (\v -> v `shiftR` 1 .|. carryIn `shiftL` 7) 0
  BCC -> branch (not (flag carry))
  BCS -> branch (flag carry)
  BNE -> branch (not (flag zero))
  BEQ -> branch (flag zero)
  BPL -> branch (not (flag negative))
  BMI -> branch (flag negative)
  BVC -> branch (not (flag overflow))
  BVS -> branch (flag overflow)
  CLC -> pure (setFlag carry False cpu)
  SEC -> pure (setFlag carry True cpu)
  CLI -> pure (setFlag interruptDisable False cpu)
  SEI -> pure (setFlag interruptDisable True cpu)
  CLD -> pure (setFlag decimal False cpu)
  SED -> pure (setFlag decimal True cpu)
  CLV -> pure (setFlag overflow False cpu)
  PHA -> push bus cpu.a cpu
  PHP -> push bus (cpu.p .|. breakBits) cpu
  PLA -> do
    (cpu', v) <- pull bus cpu
    pure (setZN v cpu' {a = v})
  PLP -> do
    (cpu', v) <- pull bus cpu
    pure cpu' {p = fromStack v}
  JMP -> pure cpu {pc = addr}
  JSR -> jumpTo addr <$> pushWord bus (cpu.pc - 1) cpu
  RTS -> do
    (cpu', ret) <- pullWord bus cpu
    pure cpu' {pc = ret + 1}
  RTI -> do
    (cpu', v) <- pull bus cpu
    (cpu'', ret) <- pullWord bus cpu'
    pure cpu'' {p = fromStack v, pc = ret}
  -- BRK skips a padding byte after the opcode.
  BRK -> interrupt bus 0xFFFE (cpu.p .|. breakBits) cpu {pc = cpu.pc + 1}
  NOP -> pure cpu
  where
    withValue f = f <$> load bus addr
    setA v = setZN v cpu {a = v}
    setX v = setZN v cpu {x = v}
    setY v = setZN v cpu {y = v}
    flag = testBit cpu.p
    carryIn = if flag carry then 1 else 0
    jumpTo target c = c {pc = target}
    add v =
      let sum16 = fromIntegral cpu.a + fromIntegral v + fromIntegral carryIn :: Word16
          r = fromIntegral sum16
       in setFlag carry (sum16 > 0xFF) $
            setFlag overflow (testBit ((cpu.a `xor` r) .&. (v `xor` r)) 7) (setA r)
    compareWith reg v = setFlag carry (reg >= v) (setZN (reg - v) cpu)
    modify f = do
      v <- load bus addr
      store bus addr (f v)
      pure (setZN (f v) cpu)
    -- Shift or rotate; the carry takes the bit shifted out.
    shift f outBit
      | mode == Acc = pure (setFlag carry (testBit cpu.a outBit) (setA (f cpu.a)))
      | otherwise = do
          v <- load bus addr
          store bus addr (f v)
          pure (setFlag carry (testBit v outBit) (setZN (f v) cpu))
    -- A taken branch costs a cycle, two if it lands on another page.
    branch taken
      | taken = pure cpu {pc = addr, cycles = cpu.cycles + if page addr == page cpu.pc then 1 else 2}
      | otherwise = pure cpu

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

setFlag :: Int -> Bool -> CPU -> CPU
setFlag i on cpu = cpu {p = if on then setBit cpu.p i else clearBit cpu.p i}

setZN :: Word8 -> CPU -> CPU
setZN v = setFlag zero (v == 0) . setFlag negative (testBit v 7)

-- * Stack

push :: Bus s -> Word8 -> CPU -> ST s CPU
push bus v cpu = cpu {sp = cpu.sp - 1} <$ store bus (0x100 + fromIntegral cpu.sp) v

pull :: Bus s -> CPU -> ST s (CPU, Word8)
pull bus cpu = (cpu',) <$> load bus (0x100 + fromIntegral cpu'.sp)
  where
    cpu' = cpu {sp = cpu.sp + 1}

pushWord :: Bus s -> Word16 -> CPU -> ST s CPU
pushWord bus w cpu = push bus (fromIntegral (w `shiftR` 8)) cpu >>= push bus (fromIntegral w)

pullWord :: Bus s -> CPU -> ST s (CPU, Word16)
pullWord bus cpu = do
  (cpu', lo) <- pull bus cpu
  (cpu'', hi) <- pull bus cpu'
  pure (cpu'', fromIntegral hi `shiftL` 8 .|. fromIntegral lo)
