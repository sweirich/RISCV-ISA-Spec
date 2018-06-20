-- See LICENSE for license details

module Read_Hex_File where

-- ================================================================
-- This code is adapted from MIT's riscv-semantics repo

-- This module implements a function that reads a hex-memory file
-- and returns a memory (i.e., list of (addr, byte)).

-- ================================================================
-- Standard Haskell imports

import System.IO
import Data.Word
import Data.Bits
import Numeric (showHex, readHex)

-- Project imports

-- None

-- ================================================================
-- Read a Mem-Hex file (each datum should represent one byte)
-- and return a memory (list of (addr,byte))

read_hex_file :: FilePath -> IO [(Int, Word8)]
read_hex_file f = do
  let
    helper h  line_num  next_addr  mem = do
      s    <- hGetLine h
      if (null s)
        then (do
                 putStrLn ("Finished reading hex file (" ++ show line_num ++ " lines)")
                 return (reverse mem))
        else (do
                 let (next_addr', mem') = process_line s  next_addr  mem
                 done <- hIsEOF h
                 if done
                   then return  (reverse mem')
                   else helper  h  (line_num + 1)  next_addr'  mem')

  h <- openFile f ReadMode
  helper h 0 0 []

-- Process a line from a Mem-Hex file, which is
-- either an address line ('@hex-address')
-- or a data line (a hex byte in memory)

process_line :: String -> Int -> [(Int, Word8)] -> (Int, [(Int, Word8)])
process_line ('@':xs) next_addr mem = (fst $ head $ readHex xs, mem)
process_line  s       next_addr mem = (next_addr + 1,
                                       (next_addr, fst $ head $ readHex s): mem)

-- ================================================================
