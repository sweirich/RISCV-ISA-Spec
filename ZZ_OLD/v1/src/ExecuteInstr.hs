module ExecuteInstr (executeInstr) where

-- ================================================================
-- This module contains the execution semantics for each RISC-V instruction
-- Each clause below pattern-matches on a different instruction opcode
-- and specifies its semantics.

-- ================================================================
-- Standard Haskell imports

import System.IO
import Data.Int
import Data.List
import Data.Word
import Data.Bits
import Numeric (showHex, readHex)

-- Project imports

import BitManipulation
import ArchDefs
import ArchState
import Decode
import CSRFile

-- ================================================================
-- Each opcode of course does something unique, but they all end with
-- a few common actions:
--     - updating the PC with either PC+4 or a new PC
--     - upating the MINSTRET register (number of instructions retired)
--     - updating a CSR
-- These 'exec_end_...' functions encapsulate those standard endings.

-- Every completed instruction increments minstret
incr_minstret :: ArchState -> IO (ArchState)
incr_minstret  astate = do
  let minstret = archstate_csr_read  astate  csr_addr_minstret
  archstate_csr_write  astate  csr_addr_minstret  (minstret+1)

-- Most common ending: optionally update Rd; incr PC by 4; increment MINSTRET
exec_end_common :: ArchState -> Maybe (Register, UInt) -> IO ArchState
exec_end_common  astate  m_rd_rdval = do
  astate1 <- case m_rd_rdval of
               Just (rd, rd_val) -> archstate_gpr_write  astate  rd  rd_val
               Nothing           -> return astate
  let pc   = archstate_pc_read  astate1
  astate2 <- archstate_pc_write  astate1  (pc + 4)
  incr_minstret  astate2

-- Ending for control transfers: store saved PC in Rd; set PC to new PC; increment MINSTRET
exec_end_jump :: ArchState -> Register -> UInt -> UInt -> IO ArchState
exec_end_jump  astate  rd  save_PC  target_PC = do
  if ((mod  target_PC  4) /= 0)
    then raiseException  astate  0  0
    else do
      astate1 <- archstate_gpr_write  astate  rd  save_PC
      astate2 <- archstate_pc_write   astate1  target_PC
      incr_minstret astate2

-- Ending for BRANCH instrs: PC = if taken then newPC else PC+4; increment MINSTRET
exec_end_branch :: ArchState -> UInt -> Bool -> UInt -> IO ArchState
exec_end_branch  astate  pc  taken  target_PC = do
  if (taken && (mod target_PC 4 /= 0))
    then
      raiseException  astate  0  0
    else do
      let nextPC = if taken then target_PC else pc + 4
      astate1 <- archstate_pc_write  astate  nextPC
      incr_minstret  astate1

-- Ending on traps
-- TODO: Currently stopping execution; should trap instead
exec_end_trap :: ArchState -> Exc_Code -> UInt -> IO ArchState
exec_end_trap  astate  exc_code  tval =
  upd_ArchState_on_trap  astate  False  exc_code  tval

exec_end_ret :: ArchState -> Priv_Level -> IO ArchState
exec_end_ret  astate  priv = do
  astate1 <- upd_ArchState_on_ret  astate  priv
  incr_minstret  astate1

-- ================================================================
-- 'executeInstr' takes current arch state and a decoded instruction
-- and returns a new arch state after executing that instruction.

executeInstr :: ArchState -> Instruction -> IO ArchState

-- ================================================================
-- RV32I Base Instruction Set (Vol I)

-- Immediate constants: LUI AUIPC

executeInstr  astate  (LUI rd imm20) = do
  let x      = shiftL  imm20  12
      rd_val = signExtend  x  32
  exec_end_common  astate  (Just (rd, rd_val))
  
executeInstr  astate  (AUIPC rd imm20) = do
  let pc     = archstate_pc_read  astate
      x1     = shiftL  imm20  12
      x2     = signExtend  x1  32
      rd_val = cvt_s_to_u ((cvt_u_to_s  x2) + (cvt_u_to_s  pc))
  exec_end_common  astate  (Just (rd, rd_val))

-- Jumps : JAL JALR

executeInstr  astate  (JAL rd jimm20) = do
  let pc        = archstate_pc_read  astate
      save_PC   = pc + 4
      x1        = shiftL  jimm20  1
      x2        = signExtend  x1  21
      target_PC = cvt_s_to_u  ((cvt_u_to_s  pc) + (cvt_u_to_s  x2))
  exec_end_jump  astate  rd  save_PC  target_PC

executeInstr  astate (JALR rd rs1 oimm12) = do
  let pc        = archstate_pc_read  astate
      save_PC   = pc + 4
      rs1_val   = archstate_gpr_read  astate  rs1
      x         = signExtend  oimm12  12
      target_PC = cvt_s_to_u  ((cvt_u_to_s  rs1_val) + (cvt_u_to_s  x))
  exec_end_jump  astate  rd  save_PC  target_PC

-- Branches: BEQ BNE BLT BLTU BGE BGEU

executeInstr  astate  (BEQ rs1 rs2 sbimm12) = do
  let rs1_val   = archstate_gpr_read  astate  rs1
      rs2_val   = archstate_gpr_read  astate  rs2
      pc        = archstate_pc_read  astate
      x1        = shiftL  sbimm12  1
      x2        = signExtend  x1  13
      target_PC = cvt_s_to_u  ((cvt_u_to_s  pc) + (cvt_u_to_s  x2))
  exec_end_branch  astate  pc  (rs1_val == rs2_val)  target_PC

executeInstr  astate  (BNE rs1 rs2 sbimm12) = do
  let rs1_val   = archstate_gpr_read  astate  rs1
      rs2_val   = archstate_gpr_read  astate  rs2
      pc        = archstate_pc_read  astate
      x1        = shiftL  sbimm12  1
      x2        = signExtend  x1  13
      target_PC = cvt_s_to_u  ((cvt_u_to_s  pc) + (cvt_u_to_s  x2))
  exec_end_branch  astate  pc  (rs1_val /= rs2_val)  target_PC

executeInstr  astate  (BLT rs1 rs2 sbimm12) = do
  let rs1_val   = archstate_gpr_read  astate  rs1
      rs1_val_s = cvt_u_to_s  rs1_val
      rs2_val   = archstate_gpr_read  astate  rs2
      rs2_val_s = cvt_u_to_s  rs2_val
      pc        = archstate_pc_read  astate
      x1        = shiftL  sbimm12  1
      x2        = signExtend  x1  13
      target_PC = cvt_s_to_u  ((cvt_u_to_s  pc) + (cvt_u_to_s  x2))
  exec_end_branch  astate  pc  (rs1_val_s < rs2_val_s)  target_PC

executeInstr  astate  (BGE rs1 rs2 sbimm12) = do
  let rs1_val   = archstate_gpr_read  astate  rs1
      rs1_val_s = cvt_u_to_s  rs1_val
      rs2_val   = archstate_gpr_read  astate  rs2
      rs2_val_s = cvt_u_to_s  rs2_val
      pc        = archstate_pc_read  astate
      x1        = shiftL  sbimm12  1
      x2        = signExtend  x1  13
      target_PC = cvt_s_to_u  ((cvt_u_to_s  pc) + (cvt_u_to_s  x2))
  exec_end_branch  astate  pc  (rs1_val_s >= rs2_val_s)  target_PC

executeInstr  astate  (BLTU rs1 rs2 sbimm12) = do
  let rs1_val   = archstate_gpr_read  astate  rs1
      rs2_val   = archstate_gpr_read  astate  rs2
      pc        = archstate_pc_read  astate
      x1        = shiftL  sbimm12  1
      x2        = signExtend  x1  13
      target_PC = cvt_s_to_u  ((cvt_u_to_s  pc) + (cvt_u_to_s  x2))
  exec_end_branch  astate  pc  (rs1_val < rs2_val)  target_PC

executeInstr  astate  (BGEU rs1 rs2 sbimm12) = do
  let rs1_val   = archstate_gpr_read  astate  rs1
      rs2_val   = archstate_gpr_read  astate  rs2
      pc        = archstate_pc_read  astate
      x1        = shiftL  sbimm12  1
      x2        = signExtend  x1  13
      target_PC = cvt_s_to_u  ((cvt_u_to_s  pc) + (cvt_u_to_s  x2))
  exec_end_branch  astate  pc  (rs1_val >= rs2_val)  target_PC

-- Loads: LB LH LU LBU LHU

executeInstr  astate  (LB rd rs1 oimm12) = do
  let rs1_val           = archstate_gpr_read  astate  rs1
      x                 = signExtend  oimm12  12
      eaddr             = cvt_s_to_u  ((cvt_u_to_s  rs1_val) + (cvt_u_to_s  x))
      (result, astate') = archstate_mem_read8  astate  eaddr
  case result of
    LoadResult_Err exc_code -> exec_end_trap  astate'  exc_code  eaddr
    LoadResult_Ok  u8       ->
      do
        let rd_val = signExtend_u8_to_u  u8
        exec_end_common  astate'  (Just (rd, rd_val))

executeInstr  astate  (LH rd rs1 oimm12) = do
  let rs1_val           = archstate_gpr_read  astate  rs1
      x                 = signExtend  oimm12  12
      eaddr             = cvt_s_to_u  ((cvt_u_to_s  rs1_val) + (cvt_u_to_s  x))
      (result, astate') = archstate_mem_read16  astate  eaddr
  case result of
    LoadResult_Err exc_code -> exec_end_trap  astate'  exc_code  eaddr
    LoadResult_Ok  u16      ->
      do
        let rd_val = signExtend_u16_to_u  u16
        exec_end_common  astate'  (Just (rd, rd_val))

executeInstr  astate  (LW rd rs1 oimm12) = do
  let rs1_val           = archstate_gpr_read  astate  rs1
      x                 = signExtend  oimm12  12
      eaddr             = cvt_s_to_u  ((cvt_u_to_s  rs1_val) + (cvt_u_to_s  x))
      (result, astate') = archstate_mem_read32  astate  eaddr
  case result of
    LoadResult_Err exc_code -> exec_end_trap  astate'  exc_code  eaddr
    LoadResult_Ok  u32      ->
      do
        let rd_val = signExtend_u32_to_u  u32
        exec_end_common  astate'  (Just (rd, rd_val))

executeInstr  astate  (LBU rd rs1 oimm12) = do
  let rs1_val           = archstate_gpr_read  astate  rs1
      x                 = signExtend  oimm12  12
      eaddr             = cvt_s_to_u  ((cvt_u_to_s  rs1_val) + (cvt_u_to_s  x))
      (result, astate') = archstate_mem_read8  astate  eaddr
  case result of
    LoadResult_Err exc_code -> exec_end_trap  astate'  exc_code  eaddr
    LoadResult_Ok  u8       ->
      do
        let rd_val = zeroExtend_u8_to_u  u8
        exec_end_common  astate'  (Just (rd, rd_val))

executeInstr  astate  (LHU rd rs1 oimm12) = do
  let rs1_val           = archstate_gpr_read  astate  rs1
      x                 = signExtend  oimm12  12
      eaddr             = cvt_s_to_u  ((cvt_u_to_s  rs1_val) + (cvt_u_to_s  x))
      (result, astate') = archstate_mem_read16  astate  eaddr
  case result of
    LoadResult_Err exc_code -> exec_end_trap  astate'  exc_code  eaddr
    LoadResult_Ok  u16      ->
      do
        let rd_val = zeroExtend_u16_to_u  u16
        exec_end_common  astate'  (Just (rd, rd_val))

-- Stores: SB SH SW

executeInstr  astate  (SB rs1 rs2 simm12) = do
  let rs1_val = archstate_gpr_read  astate  rs1
      rs2_val = archstate_gpr_read  astate  rs2
      x       = signExtend  simm12  12
      eaddr   = cvt_s_to_u  ((cvt_u_to_s  rs1_val) + (cvt_u_to_s  x))
      u8      = trunc_u_to_u8  rs2_val
  astate1 <- archstate_mem_write8  astate  eaddr  u8
  exec_end_common  astate1  Nothing

executeInstr  astate  (SH rs1 rs2 simm12) = do
  let rs1_val = archstate_gpr_read  astate  rs1
      rs2_val = archstate_gpr_read  astate  rs2
      x       = signExtend  simm12  12
      eaddr   = cvt_s_to_u  ((cvt_u_to_s  rs1_val) + (cvt_u_to_s  x))
      u16     = trunc_u_to_u16  rs2_val
  astate1 <- archstate_mem_write16  astate  eaddr  u16
  exec_end_common  astate1  Nothing

executeInstr  astate  (SW rs1 rs2 simm12) = do
  let rs1_val = archstate_gpr_read  astate  rs1
      rs2_val = archstate_gpr_read  astate  rs2
      x       = signExtend  simm12  12
      eaddr   = cvt_s_to_u  ((cvt_u_to_s  rs1_val) + (cvt_u_to_s  x))
      u32     = trunc_u_to_u32  rs2_val
  astate1 <- archstate_mem_write32  astate  eaddr  u32
  exec_end_common  astate1  Nothing

-- ALU register immediate: ADDI SLTI SLTIU XORI ORI ANDI SLLI SRLI SRAI

executeInstr  astate  (ADDI rd rs1 imm12) = do
  let rs1_val = archstate_gpr_read  astate  rs1
      x       = signExtend  imm12  12
      rd_val  = cvt_s_to_u  ((cvt_u_to_s  rs1_val) + (cvt_u_to_s  x))
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (SLTI rd rs1 imm12) = do
  let rs1_val = archstate_gpr_read  astate  rs1
      x       = signExtend  imm12  12
      rd_val  = if (cvt_u_to_s  rs1_val) < (cvt_u_to_s  x) then 1 else 0
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (SLTIU rd rs1 imm12) = do
  let rs1_val = archstate_gpr_read  astate  rs1
      x       = signExtend  imm12  12
      rd_val  = if rs1_val < x then 1 else 0
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (XORI rd rs1 imm12) = do
  let rs1_val = archstate_gpr_read  astate  rs1
      x       = signExtend  imm12  12
      rd_val  = xor  rs1_val  x
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (ORI rd rs1 imm12) = do
  let rs1_val = archstate_gpr_read  astate  rs1
      x       = signExtend  imm12  12
      rd_val  = rs1_val  .|.  x
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (ANDI rd rs1 imm12) = do
  let rs1_val = archstate_gpr_read  astate  rs1
      x       = signExtend  imm12  12
      rd_val  = rs1_val  .&.  x
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (SLLI rd rs1 shamt6) = do
  let rs1_val = archstate_gpr_read  astate  rs1
      rd_val  = shiftL  rs1_val  (cvt_u_to_Int  shamt6)
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (SRLI rd rs1 shamt6) = do
  let rs1_val = archstate_gpr_read  astate  rs1
      rd_val  = shiftR  rs1_val  (cvt_u_to_Int  shamt6)
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (SRAI rd rs1 shamt6) = do
  let rs1_val = archstate_gpr_read  astate  rs1
      rd_val  = cvt_s_to_u  (shiftR  (cvt_u_to_s  rs1_val)  (cvt_u_to_Int  shamt6))
  exec_end_common  astate  (Just (rd, rd_val))

-- ALU register-register: ADD SUB SLL SLT SLTU SRL SRA XOR OR AND

executeInstr  astate  (ADD rd rs1 rs2) = do
  let rs1_val = archstate_gpr_read  astate  rs1
      rs2_val = archstate_gpr_read  astate  rs2
      rd_val  = cvt_s_to_u  ((cvt_u_to_s  rs1_val) + cvt_u_to_s  (rs2_val))
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (SUB rd rs1 rs2) = do
  let rs1_val = archstate_gpr_read  astate  rs1
      rs2_val = archstate_gpr_read  astate  rs2
      rd_val  = cvt_s_to_u  ((cvt_u_to_s  rs1_val) - cvt_u_to_s  (rs2_val))
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (SLL rd rs1 rs2) = do
  let rv      = archstate_rv_read  astate
      rs1_val = archstate_gpr_read  astate  rs1
      rs2_val = archstate_gpr_read  astate  rs2
      shamt :: Int
      shamt   = cvt_u_to_Int  (rs2_val .&. (if rv==RV32 then 0x1F else 0x3F))
      rd_val  = shiftL  rs1_val  shamt
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (SLT rd rs1 rs2) = do
  let rs1_val = archstate_gpr_read  astate  rs1
      rs2_val = archstate_gpr_read  astate  rs2
      rd_val  = if (cvt_u_to_s  rs1_val) < cvt_u_to_s  (rs2_val) then 1 else 0
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (SLTU rd rs1 rs2) = do
  let rs1_val = archstate_gpr_read  astate  rs1
      rs2_val = archstate_gpr_read  astate  rs2
      rd_val  = if rs1_val < rs2_val then 1 else 0
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (SRL rd rs1 rs2) = do
  let rv      = archstate_rv_read  astate
      rs1_val = archstate_gpr_read  astate  rs1
      rs2_val = archstate_gpr_read  astate  rs2
      shamt :: Int
      shamt   = cvt_u_to_Int  (rs2_val .&. (if rv==RV32 then 0x1F else 0x3F))
      rd_val  = shiftR  rs1_val  shamt
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (SRA rd rs1 rs2) = do
  let rv      = archstate_rv_read  astate
      rs1_val = archstate_gpr_read  astate  rs1
      rs2_val = archstate_gpr_read  astate  rs2
      shamt :: Int
      shamt   = cvt_u_to_Int  (rs2_val .&. (if rv==RV32 then 0x1F else 0x3F))
      rd_val  = cvt_s_to_u  (shiftR  (cvt_u_to_s  rs1_val)  shamt)
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (XOR rd rs1 rs2) = do
  let rs1_val = archstate_gpr_read  astate  rs1
      rs2_val = archstate_gpr_read  astate  rs2
      rd_val  = xor  rs1_val  rs2_val
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (OR rd rs1 rs2) = do
  let rs1_val = archstate_gpr_read  astate  rs1
      rs2_val = archstate_gpr_read  astate  rs2
      rd_val  = rs1_val  .|.  rs2_val
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (AND rd rs1 rs2) = do
  let rs1_val = archstate_gpr_read  astate  rs1
      rs2_val = archstate_gpr_read  astate  rs2
      rd_val  = rs1_val  .&.  rs2_val
  exec_end_common  astate  (Just (rd, rd_val))

-- SYSTEM: ECALL, EBREAK

executeInstr  astate  ECALL = do
  let priv     = archstate_priv_read  astate
      exc_code | priv == m_Priv_Level = exc_code_ECall_from_M
               | priv == s_Priv_Level = exc_code_ECall_from_S
               | priv == u_Priv_Level = exc_code_ECall_from_U
  exec_end_trap  astate  exc_code  0

executeInstr  astate  EBREAK = do
  putStrLn ("Ebreak; STOPPING")
  let pc = archstate_pc_read  astate
  exec_end_trap  astate  exc_code_breakpoint  pc

-- Memory Model: FENCE FENCE.I
-- TODO: currently no-ops; fix up

executeInstr  astate  (FENCE  pred  succ) = do
  exec_end_common  astate  Nothing

executeInstr  astate  FENCE_I = do
  exec_end_common  astate  Nothing

-- CSRRx: CSRRW CSRRS CSRRC CSRRWI CSRRSI CSRRCI

executeInstr  astate  (CSRRW rd rs1 csr12) =
  let permission = archstate_csr_read_permission  astate  (archstate_priv_read  astate)  csr12
  in
    if (permission /= CSR_Permission_RW)
    then
      exec_end_trap  astate  exc_code_illegal_instruction  0    -- TODO: 0 => instr
    else do
      let csr_val = if (rd /= Rg_x0) then
                      archstate_csr_read  astate  csr12
                    else
                      0    -- arbitrary; will be discarded (rd==0)
          rs1_val = archstate_gpr_read  astate  rs1
      astate1 <- archstate_csr_write  astate  csr12  rs1_val
      exec_end_common  astate1  (Just (rd, csr_val))

executeInstr  astate  (CSRRWI rd zimm csr12) =
  let permission = archstate_csr_read_permission  astate  (archstate_priv_read  astate)  csr12
  in
    if (permission /= CSR_Permission_RW)
    then
      exec_end_trap  astate  exc_code_illegal_instruction  0    -- TODO: 0 => instr
    else do
      let csr_val = if (rd /= Rg_x0) then
                      archstate_csr_read  astate  csr12
                    else
                      0    -- arbitrary; will be discarded (rd==0)
      astate1 <- archstate_csr_write  astate  csr12  zimm
      exec_end_common  astate1  (Just (rd, csr_val))

executeInstr  astate  (CSRRS rd rs1 csr12) =
  let permission = archstate_csr_read_permission  astate  (archstate_priv_read  astate)  csr12
  in
    if (permission == CSR_Permission_None) || ((rs1 /= Rg_x0) && (permission == CSR_Permission_RO))
    then
      exec_end_trap  astate  exc_code_illegal_instruction  0    -- TODO: 0 => instr
    else do
      let csr_val = archstate_csr_read  astate  csr12
      astate1 <- (if (rs1 /= Rg_x0) then do
                     let rs1_val = archstate_gpr_read  astate  rs1
                         new_csr_val = csr_val  .|.  rs1_val
                     archstate_csr_write  astate  csr12  new_csr_val
                  else
                    return astate)
      exec_end_common  astate1  (Just (rd, csr_val))

executeInstr  astate  (CSRRSI rd zimm csr12) =
  let permission = archstate_csr_read_permission  astate  (archstate_priv_read  astate)  csr12
  in
    if (permission == CSR_Permission_None) || ((zimm /= 0) && (permission == CSR_Permission_RO))
    then
      exec_end_trap  astate  exc_code_illegal_instruction  0    -- TODO: 0 => instr
    else do
      let csr_val = archstate_csr_read  astate  csr12
      astate1 <- (if (zimm /= 0) then do
                     let new_csr_val = csr_val  .|.  zimm
                     archstate_csr_write  astate  csr12  new_csr_val
                  else
                    return astate)
      exec_end_common  astate1  (Just (rd, csr_val))

executeInstr  astate  (CSRRC rd rs1 csr12) =
  let permission = archstate_csr_read_permission  astate  (archstate_priv_read  astate)  csr12
  in
    if (permission == CSR_Permission_None) || ((rs1 /= Rg_x0) && (permission == CSR_Permission_RO))
    then
      exec_end_trap  astate  exc_code_illegal_instruction  0    -- TODO: 0 => instr
    else do
      let csr_val = archstate_csr_read  astate  csr12
      astate1 <- (if (rs1 /= Rg_x0) then do
                     let rs1_val = archstate_gpr_read  astate  rs1
                         new_csr_val = csr_val  .&.  (complement  rs1_val)
                     archstate_csr_write  astate  csr12  new_csr_val
                  else
                     return astate)
      exec_end_common  astate1  (Just (rd, csr_val))

executeInstr  astate  (CSRRCI rd zimm csr12) =
  let permission = archstate_csr_read_permission  astate  (archstate_priv_read  astate)  csr12
  in
    if (permission == CSR_Permission_None) || ((zimm /= 0) && (permission == CSR_Permission_RO))
    then
      exec_end_trap  astate  exc_code_illegal_instruction  0    -- TODO: 0 => instr
    else do
      let csr_val = archstate_csr_read  astate  csr12
      astate1 <- (if (zimm /= 0) then do
                     let new_csr_val = csr_val  .&.  (complement  zimm)
                     archstate_csr_write  astate  csr12  new_csr_val
                   else
                     return astate)
      exec_end_common  astate1  (Just (rd, csr_val))

-- ================================================================
-- RV64I Base Instruction Set (Vol I)

-- Loads: LWU LD

executeInstr  astate  (LWU rd rs1 oimm12) = do
  let rs1_val           = archstate_gpr_read  astate  rs1
      x                 = signExtend  oimm12  12
      eaddr             = cvt_s_to_u  ((cvt_u_to_s  rs1_val) + (cvt_u_to_s  x))
      (result, astate') = archstate_mem_read32  astate  eaddr
  case result of
    LoadResult_Err cause -> exec_end_trap  astate'  cause  eaddr
    LoadResult_Ok  u32   ->
      do
        let rd_val = zeroExtend_u32_to_u64  u32
        exec_end_common  astate'  (Just (rd, rd_val))

executeInstr  astate  (LD rd rs1 oimm12) = do
  let rs1_val           = archstate_gpr_read  astate  rs1
      x                 = signExtend  oimm12  12
      eaddr             = cvt_s_to_u  ((cvt_u_to_s  rs1_val) + (cvt_u_to_s  x))
      (result, astate') = archstate_mem_read64  astate  eaddr
  case result of
    LoadResult_Err cause -> exec_end_trap  astate'  cause  eaddr
    LoadResult_Ok  u64   ->
      do
        let rd_val = u64
        exec_end_common  astate'  (Just (rd, rd_val))

-- Stores: SD

executeInstr  astate  (SD rs1 rs2 simm12) = do
  let rs1_val = archstate_gpr_read  astate  rs1
      rs2_val = archstate_gpr_read  astate  rs2
      x       = signExtend  simm12  12
      eaddr   = cvt_s_to_u  ((cvt_u_to_s  rs1_val) + (cvt_u_to_s  x))
  astate1 <- archstate_mem_write64  astate  eaddr  rs2_val
  exec_end_common  astate1  Nothing

-- ALU Register-Immediate: ADDIW SLLIW SRLIW SRAIW

executeInstr  astate  (ADDIW  rd  rs1  imm12) = do
  let rs1_val_s32 = trunc_u64_to_s32  (archstate_gpr_read  astate  rs1)
      x_s32       = trunc_u64_to_s32  (signExtend  imm12  12)
      sum_s32     = rs1_val_s32 + x_s32
      rd_val      = signExtend_s32_to_u64  sum_s32
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (SLLIW rd rs1 shamt5) = do
  let rs1_val_u32 = trunc_u64_to_u32  (archstate_gpr_read  astate  rs1)
      n           = cvt_u_to_Int  shamt5
      rd_val      = signExtend_u32_to_u64 (shiftL  rs1_val_u32  n)
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (SRLIW rd rs1 shamt5) = do
  let rs1_val_u32 = trunc_u64_to_u32  (archstate_gpr_read  astate  rs1)
      n           = cvt_u_to_Int  shamt5
      rd_val      = signExtend_u32_to_u64 (shiftR  rs1_val_u32  n)
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (SRAIW rd rs1 shamt5) = do
  let rs1_val_s32 = trunc_u64_to_s32  (archstate_gpr_read  astate  rs1)
      n           = cvt_u_to_Int  shamt5
      rd_val      = signExtend_s32_to_u64 (shiftR  rs1_val_s32  n)
  exec_end_common  astate  (Just (rd, rd_val))

-- ALU register and register: ADDW SUBW SLLW SRLW SRAW

executeInstr  astate  (ADDW rd rs1 rs2) = do
  let rs1_val_s32 = trunc_u64_to_s32  (archstate_gpr_read  astate  rs1)
      rs2_val_s32 = trunc_u64_to_s32  (archstate_gpr_read  astate  rs2)
      rd_val      = signExtend_s32_to_u64 (rs1_val_s32 + rs2_val_s32)
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (SUBW rd rs1 rs2) = do
  let rs1_val_s32 = trunc_u64_to_s32  (archstate_gpr_read  astate  rs1)
      rs2_val_s32 = trunc_u64_to_s32  (archstate_gpr_read  astate  rs2)
      rd_val      = signExtend_s32_to_u64 (rs1_val_s32 - rs2_val_s32)
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (SLLW rd rs1 rs2) = do
  let rs1_val_s32 = trunc_u64_to_s32  (archstate_gpr_read  astate  rs1)
      rs2_val_u64 = archstate_gpr_read  astate  rs2
      shamt      :: Int
      shamt       = fromIntegral (rs2_val_u64 .&. 0x1F)
      result_s32  = shiftL  rs1_val_s32  shamt
      rd_val      = signExtend_s32_to_u64  result_s32
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (SRLW rd rs1 rs2) = do
  let rs1_val_u32 = trunc_u64_to_u32  (archstate_gpr_read  astate  rs1)
      rs2_val_u64 = archstate_gpr_read  astate  rs2
      shamt       = fromIntegral (rs2_val_u64 .&. 0x1F)
      result_u32  = shiftR  rs1_val_u32  shamt
      rd_val      = signExtend_u32_to_u64  result_u32
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (SRAW rd rs1 rs2) = do
  let rs1_val_s32 = trunc_u64_to_s32  (archstate_gpr_read  astate  rs1)
      rs2_val_u64 = archstate_gpr_read  astate  rs2
      shamt       = fromIntegral (rs2_val_u64 .&. 0x1F)
      result_s32  = shiftR  rs1_val_s32  shamt
      rd_val      = signExtend_s32_to_u64  result_s32
  exec_end_common  astate  (Just (rd, rd_val))

-- ================================================================
  -- RV32M Standard Extension

executeInstr  astate  (MUL rd rs1 rs2) = do
  let rs1_val = archstate_gpr_read  astate  rs1
      rs2_val = archstate_gpr_read  astate  rs2
      rd_val  = cvt_s_to_u  ((cvt_u_to_s  rs1_val) * cvt_u_to_s  (rs2_val))
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (MULH rd rs1 rs2) = do
  let rv      = archstate_rv_read  astate
      xlen    = if rv==RV32 then 32 else 64
      rs1_val = archstate_gpr_read  astate  rs1
      rs2_val = archstate_gpr_read  astate  rs2
      v1_i, v2_i, prod_i :: Integer    -- unbounded precision integers
      v1_i   = fromIntegral (cvt_u_to_s  rs1_val)    -- signed
      v2_i   = fromIntegral (cvt_u_to_s  rs2_val)    -- signed
      prod_i = v1_i * v2_i
      rd_val :: UInt
      rd_val = cvt_s_to_u (fromIntegral (bitSlice  prod_i  xlen  (xlen + xlen)))
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (MULHU rd rs1 rs2) = do
  let rv      = archstate_rv_read  astate
      xlen    = if rv==RV32 then 32 else 64
      rs1_val = archstate_gpr_read  astate  rs1
      rs2_val = archstate_gpr_read  astate  rs2
      v1_i, v2_i, prod_i :: Integer    -- unbounded integers
      v1_i   = fromIntegral  rs1_val    -- unsigned
      v2_i   = fromIntegral  rs2_val    -- unsigned
      prod_i = v1_i * v2_i
      rd_val :: UInt
      rd_val = cvt_s_to_u (fromIntegral (bitSlice  prod_i  xlen  (xlen + xlen)))
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (MULHSU rd rs1 rs2) = do
  let rv      = archstate_rv_read  astate
      xlen    = if rv==RV32 then 32 else 64
      rs1_val = archstate_gpr_read  astate  rs1
      rs2_val = archstate_gpr_read  astate  rs2
      v1_i, v2_i, prod_i :: Integer    -- unbounded integers
      v1_i   = fromIntegral (cvt_u_to_s  rs1_val)    -- signed
      v2_i   = fromIntegral  rs2_val                 -- unsigned
      prod_i = v1_i * v2_i
      rd_val :: UInt
      rd_val = cvt_s_to_u (fromIntegral (bitSlice  prod_i  xlen  (xlen + xlen)))
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (DIV rd rs1 rs2) = do
  let rs1_val   = archstate_gpr_read  astate  rs1
      rs2_val   = archstate_gpr_read  astate  rs2
      rs1_val_s = cvt_u_to_s  rs1_val
      rs2_val_s = cvt_u_to_s  rs2_val
      rd_val_s  = if (rs2_val_s == 0) then -1
                  else if (rs1_val_s == minBound) && (rs2_val_s == -1) then rs1_val_s
                       else quot  rs1_val_s  rs2_val_s
      rd_val    = cvt_s_to_u  rd_val_s
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (DIVU rd rs1 rs2) = do
  let rs1_val   = archstate_gpr_read  astate  rs1
      rs2_val   = archstate_gpr_read  astate  rs2
      rd_val    = if (rs2_val == 0) then maxBound
                  else div  rs1_val  rs2_val
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (REM rd rs1 rs2) = do
  let rs1_val   = archstate_gpr_read  astate  rs1
      rs2_val   = archstate_gpr_read  astate  rs2
      rs1_val_s = cvt_u_to_s  rs1_val
      rs2_val_s = cvt_u_to_s  rs2_val
      rd_val_s  = if (rs2_val_s == 0) then rs1_val_s
                  else if (rs1_val_s == minBound) && (rs2_val_s == -1) then 0
                       else rem  rs1_val_s  rs2_val_s
      rd_val    = cvt_s_to_u  rd_val_s
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (REMU rd rs1 rs2) = do
  let rs1_val   = archstate_gpr_read  astate  rs1
      rs2_val   = archstate_gpr_read  astate  rs2
      rd_val    = if (rs2_val == 0) then rs1_val
                  else rem  rs1_val  rs2_val
  exec_end_common  astate  (Just (rd, rd_val))

-- ================================================================
-- RV64M Standard Extension

executeInstr  astate  (MULW rd rs1 rs2) = do
  let rv      = archstate_rv_read  astate
      xlen    = if rv==RV32 then 32 else 64
      rs1_val = archstate_gpr_read  astate  rs1
      rs2_val = archstate_gpr_read  astate  rs2
      v1_i, v2_i, prod_i :: Integer    -- unbounded integers
      v1_i   = fromIntegral (trunc_u64_to_s32  rs1_val)    -- signed
      v2_i   = fromIntegral (trunc_u64_to_s32  rs2_val)    -- signed
      prod_i = v1_i * v2_i
      rd_val :: UInt
      rd_val = cvt_s_to_u (fromIntegral (bitSlice  prod_i  xlen  (xlen + xlen)))
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (DIVW rd rs1 rs2) = do
  let rs1_val  = archstate_gpr_read  astate  rs1
      rs2_val  = archstate_gpr_read  astate  rs2
      v1_s32, v2_s32, quot_s32 :: Int32
      v1_s32   = trunc_u64_to_s32  rs1_val
      v2_s32   = trunc_u64_to_s32  rs2_val
      quot_s32 = if (v2_s32 == 0) then -1
                 else if (v1_s32 == minBound) && (v2_s32 == -1) then v1_s32
                      else quot  v1_s32  v2_s32
      quot_u32 :: Word32
      quot_u32 = fromIntegral  quot_s32
      rd_val   = signExtend_u32_to_u64  quot_u32
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (DIVUW rd rs1 rs2) = do
  let rs1_val  = archstate_gpr_read  astate  rs1
      rs2_val  = archstate_gpr_read  astate  rs2
      v1_u32, v2_u32, quot_u32 :: Word32
      v1_u32   = trunc_u64_to_u32  rs1_val
      v2_u32   = trunc_u64_to_u32  rs2_val
      quot_u32 = if (v2_u32 == 0) then maxBound
                 else div  v1_u32  v2_u32
      rd_val   = signExtend_u32_to_u64  quot_u32
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (REMW rd rs1 rs2) = do
  let rs1_val = archstate_gpr_read  astate  rs1
      rs2_val = archstate_gpr_read  astate  rs2
      v1_s32, v2_s32, rem_s32 :: Int32
      v1_s32  = trunc_u64_to_s32  rs1_val
      v2_s32  = trunc_u64_to_s32  rs2_val
      rem_s32 = if (v2_s32 == 0) then v1_s32
                else if (v1_s32 == minBound) && (v2_s32 == -1) then 0
                     else rem  v1_s32  v2_s32
      rem_u32 :: Word32
      rem_u32 = fromIntegral  rem_s32
      rd_val  = signExtend_u32_to_u64  rem_u32
  exec_end_common  astate  (Just (rd, rd_val))

executeInstr  astate  (REMUW rd rs1 rs2) = do
  let rs1_val  = archstate_gpr_read  astate  rs1
      rs2_val  = archstate_gpr_read  astate  rs2
      v1_u32, v2_u32, rem_u32 :: Word32
      v1_u32   = trunc_u64_to_u32  rs1_val
      v2_u32   = trunc_u64_to_u32  rs2_val
      rem_u32 = if (v2_u32 == 0) then v1_u32
                 else rem  v1_u32  v2_u32
      rd_val = signExtend_u32_to_u64  rem_u32
  exec_end_common  astate  (Just (rd, rd_val))

-- ================================================================
-- TODO: RV32A Standard Extension (Vol I)
-- TODO: RV64A Standard Extension (Vol I)
-- TODO: RV32F Standard Extension (Vol I)
-- TODO: RV64F Standard Extension (Vol I)
-- TODO: RV32D Standard Extension (Vol I)
-- TODO: RV64D Standard Extension (Vol I)

-- ================================================================
-- Privileged Instructions (Vol II)
-- ECALL, EBREAK defined in RV32I section

-- MRET/SRET/URET

executeInstr  astate  MRET = do
  exec_end_ret  astate  m_Priv_Level
executeInstr  astate  SRET = do
  exec_end_ret  astate  s_Priv_Level
executeInstr  astate  URET = do
  exec_end_ret  astate  u_Priv_Level

-- SFENCE.VM: TODO: currently a no-op: FIXUP

executeInstr  astate  (SFENCE_VM rs1 rs2) = do
  exec_end_common  astate  Nothing

-- ================================================================
-- Invalid instructions
-- TODO: trap to trap handler; for now, just stop

executeInstr  astate  ILLEGALINSTRUCTION = do
  putStrLn "  ILLEGAL INSTRUCTION"
  exec_end_trap  astate  exc_code_illegal_instruction  0    -- TODO: 0 => instr

-- ================================================================
-- TODO: raiseException is just a placeholder for now; fix up

raiseException :: ArchState -> Int -> Int -> IO ArchState
raiseException  astate  x  y = do
  putStrLn ("raiseException: x= " ++ show x ++ " y= " ++ show y ++ "; STOPPING")
  archstate_stop_write  astate  Stop_Other
