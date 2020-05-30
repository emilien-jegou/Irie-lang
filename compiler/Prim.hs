{-# LANGUAGE LambdaCase, ScopedTypeVariables , MultiWayIf , StandaloneDeriving #-}
-- Primitives: literals and instructions
-- conversions from Prim to llvm instructions/types
-- PrimInstr are roughly equivalent to LLVM.AST.Instructions
module Prim
where
import Data.Text as T

data Literal
 = Char Char
 | Int Integer -- convenience
-- | Frac Rational
 | PolyInt   T.Text
 | PolyFrac  T.Text
 | String String
 | Array [Literal] -- incl. tuples ?
-- | Tuple [Literal]
-- | WildCard      -- errors on evaluation

-----------
-- types --
-----------
data PrimType
 = PrimInt Int -- typeBits
 | PrimFloat FloatTy
 | PrimArr PrimType
 | PrimTuple [PrimType]
 | PtrTo PrimType
 | PrimExtern   [PrimType]
 | PrimExternVA [PrimType]
 | PrimSet -- type of types

data FloatTy = HalfTy | FloatTy | DoubleTy | FP128 | PPC_FP128

------------------
-- Instructions -- 
------------------
data PrimInstr
 = IntInstr   IntInstrs
 | NatInstr   NatInstrs
 | FracInstr  FracInstrs
 | MemInstr   ArrayInstrs
 | ArrowTy    -- types functions : Set->Set->Set
 | ExprHole   -- errors on eval, but will typecheck
 | MkNum      -- instantiation must happen via function call
 | MkReal
 | MkTuple
 | Alloc
 | SizeOf
 | Len -- len of PrimArray
 -- TODO conversion instructions, bitcasts,
 -- Maybe va_arg, aggregate instrs, vector, SIMD

data IntInstrs   = Add | Sub | Mul | SDiv | SRem | ICmp
                 | And | Or | Xor | Shl | Shr
data FracInstrs  = FAdd | FSub | FMul | FDiv | FRem | FCmp
data NatInstrs   = UDiv | URem
data ArrayInstrs = ExtractVal | InsertVal | Gep

--deriving instance Eq PrimType
--deriving instance Eq FloatTy

deriving instance Show Literal
instance Show PrimType where
 show = \case
   PrimInt x -> "%i" ++ show x
   PrimFloat f -> "%f" ++ show f
   PrimArr prim -> "%@[" ++ show prim ++ "]"
   PrimTuple prim -> "%tuple(" ++ show prim ++ ")"
   PtrTo t -> "%ptr(" ++ show t ++ ")"
   PrimExtern   tys -> "%extern(" ++ show tys ++ ")"
   PrimExternVA tys-> "%externVA(" ++ show tys ++ ")"
   PrimSet -> "Set"

deriving instance Show FloatTy
deriving instance Show PrimInstr
deriving instance Show IntInstrs
deriving instance Show NatInstrs
deriving instance Show FracInstrs
deriving instance Show ArrayInstrs

deriving instance Ord Literal
deriving instance Ord PrimType
deriving instance Ord FloatTy
deriving instance Ord PrimInstr
deriving instance Ord IntInstrs
deriving instance Ord NatInstrs
deriving instance Ord FracInstrs
deriving instance Ord ArrayInstrs

deriving instance Eq Literal
deriving instance Eq PrimType
deriving instance Eq FloatTy
deriving instance Eq PrimInstr
deriving instance Eq IntInstrs
deriving instance Eq NatInstrs
deriving instance Eq FracInstrs
deriving instance Eq ArrayInstrs
