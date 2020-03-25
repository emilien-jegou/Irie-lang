module MkStg
where

import Prim
import CoreSyn
import StgSyn
import qualified CoreUtils as CU
import qualified Data.Vector as V
import qualified Data.Vector.Mutable as V
import qualified LLVM.AST as L -- (Operand, Instruction, Type, Name, mkName)
--import GHC.Word
import qualified LLVM.AST  -- (Operand, Instruction, Type, Name, mkName)
import qualified LLVM.AST.Constant as C
import qualified LLVM.AST.IntegerPredicate as IP
import qualified LLVM.AST.FloatingPointPredicate as FP
import qualified LLVM.AST.Type as LT
import qualified LLVM.AST.Float as LF
import           LLVM.AST.AddrSpace
import qualified Data.IntMap as IM
import Data.List
import Data.Char

data StgWIP -- T for temporary
 = TWip
 | TData  StgData
 | TAlias (StgId , StgType)
 | TBind

mkStg :: V.Vector Bind -> StgModule
mkStg allBinds = let
    (datas , tyAliases , binds) = _
  in StgModule {
      stgData  = datas
    , typeDefs = tyAliases
    , binds    = binds
    }

convBind :: Bind -> V.Vector Bind -> V.Vector StgWIP
convBind b coreBinds = case b of
  BindTerm args term ty -> _
  BindType args s -> _
  WIP -> error "panic: wip binding"

----------------
-- Primitives --
----------------

-- cancerous llvm-hs Name policy
-- TODO name clashes ?
-- core inames are unique, but llvm will complain that they are
-- not given sequentially (since they don't all end up in stg)
-- prepending a '_' to force a string name is not ideal
convName :: IName -> Maybe HName -> StgId
convName i = \case
  Nothing -> LLVM.AST.mkName $ '_' : show i
--Nothing -> LLVM.AST.UnName $ fromIntegral i
--Just h  -> LLVM.AST.mkName $ CU.hNm2Str h -- ++ show i

--typedLit2Stg :: Literal -> Type -> StgConst = \l t ->
--  let mkChar c = C.Int 8 $ toInteger $ ord c 
--      unEither f = fst . either error id . f
--  in case t of
--  TyMono (MonoTyPrim p) -> case p of
--    PrimInt bits  -> let ti = case l of { PolyInt i -> i }
--      in C.Int (fromIntegral bits) $ unEither TR.decimal ti
--    PrimFloat fTy -> let tf = case l of { PolyInt t->t ; PolyFrac t->t}
--      in case fTy of
--      FloatTy  -> C.Float (LF.Single $ unEither TR.rational tf)
--      DoubleTy -> C.Float (LF.Double $ unEither TR.rational tf) -- fromRational
--    PrimArr ty -> let String s = l in
--      C.Array (LLVM.AST.IntegerType 8) (mkChar <$> (s++['\0']))
--    x -> literal2Stg l -- no overrides fancy
--  o -> literal2Stg l
----o -> error $ "bad type for literal: " ++ show l ++ " : " ++ show o

literal2Stg :: Literal -> StgConst = \l ->
  let mkChar c = C.Int 8 $ toInteger $ ord c 
  in case l of
    Char c   -> mkChar c
    String s -> C.Array (LLVM.AST.IntegerType 8) (mkChar<$>(s++['\0']))
    x -> error $ show x
--    Int i    -> C.Int 32 $ i
--    Frac f   -> C.Float (LF.Double $ fromRational f)

-- most llvm instructions take flags, stg wants functions on operands
prim2llvm :: PrimInstr -> StgPrimitive = \case
  IntInstr i  -> StgPrim2 $ case i of
      Add  -> \a b -> L.Add False False a b []
      Sub  -> \a b -> L.Sub False False a b []
      Mul  -> \a b -> L.Mul False False a b []
      SDiv -> \a b -> L.SDiv False      a b []
      SRem -> \a b -> L.SRem            a b []
      ICmp -> \a b -> L.ICmp IP.EQ      a b []
      And  -> \a b -> L.And             a b []
      Or   -> \a b -> L.Or              a b []
      Xor  -> \a b -> L.Xor             a b []
      Shl  -> \a b -> L.Shl False False a b []
      Shr  -> \a b -> L.LShr False      a b []
  NatInstr i  -> StgPrim2 $ case i of
      UDiv -> \a b -> L.UDiv False a b []
      URem -> \a b -> L.URem a b []
  FracInstr i -> StgPrim2 $ case i of
      FAdd -> \a b -> L.FAdd L.noFastMathFlags a b []
      FSub -> \a b -> L.FSub L.noFastMathFlags a b []
      FMul -> \a b -> L.FMul L.noFastMathFlags a b []
      FDiv -> \a b -> L.FDiv L.noFastMathFlags a b []
      FRem -> \a b -> L.FRem L.noFastMathFlags a b []
      FCmp -> \a b -> L.FCmp FP.UEQ a b []
  MemInstr i -> case i of
      Gep        -> StgGep
      ExtractVal -> StgExtractVal -- idx
      InsertVal  -> StgInsertVal
  -- StgPrim1 $ \a -> L.ExtractValue a [fromIntegral idx] []
  -- InsertVal  -> \a b -> L.InsertValue True a [b] []
  MkTuple -> StgMkTuple
  Alloc   -> StgAlloc
  t -> error $ show t

primTy2llvm :: PrimType -> LLVM.AST.Type =
  let doExtern isVa tys =
        let (argTys, [retTy]) = splitAt (length tys -1) tys
        in LT.FunctionType retTy argTys isVa
  in \case
  PrimInt   i   -> LT.IntegerType $ fromIntegral i
  PrimFloat f   -> LT.FloatingPointType $ case f of
      HalfTy    -> LT.HalfFP
      FloatTy   -> LT.FloatFP
      DoubleTy  -> LT.DoubleFP
      FP128     -> LT.FP128FP
      PPC_FP128 -> LT.PPC_FP128FP
  PtrTo ty      -> LT.PointerType (primTy2llvm ty) (AddrSpace 0)
  PrimExtern   argTys -> doExtern False (primTy2llvm <$> argTys)
  PrimExternVA argTys -> doExtern True  (primTy2llvm <$> argTys)
  PrimArr t     -> _
  PrimTuple tys -> -- StgTuple (primTy2llvm <$> tys)
    let structTy = LT.StructureType False (primTy2llvm <$> tys)
    in  LT.PointerType structTy (AddrSpace 0)

