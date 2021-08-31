-- See presentation/TypeTheory for commentary
module BiUnify where
import Prim
import CoreSyn as C
import CoreUtils
import TCState
import PrettyCore
import Externs
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as VU
import qualified Data.Vector.Mutable as MV
import qualified Data.IntMap as IM
import Control.Lens

-- First class polymorphism:
-- \i => if (i i) true then true else true
-- i used as:
-- i : (i1 -> i1) -> (i1 -> i1)
-- i : i1 -> i1
-- => Need to consider i may be polymorphic
-- i : a -> a

-- inferred type:
-- i : a -> ((i1 -> i1) & a)
-- i : (b -> b) -> ((i1 -> i1) & (b -> b))

failBiSub :: Text -> Type -> Type -> TCEnv s BiCast
failBiSub msg a b = BiEQ <$ (tmpFails %= (TmpBiSubError msg a b:))

biSub_ a b = do
  when global_debug $ traceM ("bisub: " <> prettyTyRaw a <> " <==> " <> prettyTyRaw b)
  biSub a b

biSub :: TyPlus -> TyMinus -> TCEnv s BiCast
biSub a b = let
  in case (a , b) of
  -- lattice top and bottom
  ([] ,  _) -> pure BiEQ
  (_  , []) -> pure BiEQ
  -- lattice subconstraints
  ((p1:p2:p3) , m) -> biSub [p1] m *> biSub (p2:p3) m
  (p , (m1:m2:m3)) -> biSub p [m1] *> biSub p (m2:m3)
  ([p] , [m])      -> atomicBiSub p m

-- merge types and attempt to eliminate the THVar
--solveTVar varI (THVar v) [] = if varI == v then [] else [THVar v]
--solveTVar _ newTy [] = [newTy] -- TODO dangerous ?
solveTVar varI newTy (ty:tys) = if eqTyHead newTy ty
  then mergeTyHead newTy ty `mergeTypes` tys
  else ty : solveTVar varI newTy tys

atomicBiSub :: TyHead -> TyHead -> TCEnv s BiCast
atomicBiSub p m = (\go -> if global_debug then trace ("⚛bisub: " <> prettyTyRaw [p] <> " <==> " <> prettyTyRaw [m]) go else go) $
 case (p , m) of
  (_ , THTop) -> pure (CastInstr MkTop)
  (THBot , _) -> pure (CastInstr MkBot)
  (THPrim p1 , THPrim p2) -> primBiSub p1 p2
--(h@(THSet uni) , (THArrow x ret)) -> biSub [h] ret
  (THExt a , THExt b) | a == b -> pure BiEQ
  (p , THExt i) -> biSub [p]     =<< tyExpr . (`readPrimExtern` i)<$>use externs
  (THExt i , m) -> (`biSub` [m]) =<< tyExpr . (`readPrimExtern` i)<$>use externs

  -- Bound vars (removed at THBi, so should never be encountered during biunification)
  (THBound i , x) -> panic $ "unexpected THBound: " <> show i
  (x , THBound i) -> panic $ "unexpected THBound: " <> show i
  (THBi nb x , y) -> do
    -- make new THVars for the debruijn bound vars here
    level %= (\(Dominion (f,x)) -> Dominion (f,x+nb))
    bisubs <- (`MV.grow` nb) =<< use bis
    let blen = MV.length bisubs
        tvars = [blen - nb .. blen - 1] 
    tvars `forM_` \i -> MV.write bisubs i (BiSub [] [] 0 0)
    bis .= bisubs
    r <- biSub (substFreshTVars (blen - nb) x) [y]
    -- todo is it ok that substitution of debruijns doesn't distinguish between + and - types
--  insts <- tvars `forM` \i -> MV.read bisubs i
--  traceM $ "Instantiate: " <> show tvars <> "----" <> show insts <> "---" <> show r
--  pure . did_ $ BiInst insts r
    pure r

  (THTyCon t1 , THTyCon t2) -> biSubTyCon p m (t1 , t2)
--(THArray t1 , THPrim (PrimArr p1)) -> biSub t1 [THPrim p1]
  (THPi (Pi p ty) , y) -> biSub ty [y]
  (x , THPi (Pi p ty)) -> biSub [x] ty

  -- TODO subi(mu a.t+ <= t-) = { t+[mu a.t+ / a] <= t- } -- mirror case for t+ <= mu a.t-
  -- Recursive types are not deBruijn indexed ! this means we must note the equivalent mu types
  (THMu a x , THMu b y) | a == b -> do --(muEqui %= IM.insert a b) *>  do
    biSub x y
--  ret <$ (muEqui %= IM.delete a)
--(x , THMu i y) -> biSub [x] y -- TODO is it alright to drop mus ?
--(THMu i x , y) -> biSub x [y] -- TODO is it alright to drop mus ?
  (THMuBound x, THMuBound y) -> use muEqui >>= \equi -> case (equi IM.!? x) of
    Just found -> if found == y then pure BiEQ else error $ "mu types not equal: " <> show x <> " /= " <> show y
    Nothing -> panic $ "Found Mu-bound variable without binder!" -- TODO can maybe be legit
  -- TODO can unrolling recursive types loop ?
  (x , THMuBound y) -> use bis >>= \d -> MV.read d y >>= biSub [x] . _pSub -- unroll recursive types
  (THMuBound x , y) -> use bis >>= \d -> MV.read d x >>= biSub [y] . _mSub -- unroll recursive types

  (THRecSi f1 a1, THRecSi f2 a2) -> if f1 == f2
    then if (length a1 == length a2) && all identity (zipWith termEq a1 a2)
      then pure BiEQ
      else error $ "RecSi arities mismatch"
    else error $ "RecSi functions do not match ! " ++ show f1 ++ " /= " ++ show f2
  (THSet u , x) -> pure BiEQ
  (x , THSet u) -> pure BiEQ
  (THVar p , THVar m) -> use bis >>= \v -> BiEQ <$ do
    MV.modify v (\(BiSub a b qa qb) -> BiSub (THVar p : a) b qa qb) m
    MV.modify v (\(BiSub a b qa qb) -> BiSub a (THVar m : b) qa qb) p
    dupVar True m
  (THVar p , m) -> use bis >>= \v -> (_pSub <$> MV.read v p) >>= \t -> do
    MV.modify v (\(BiSub a b qa qb) -> BiSub a (m : b) qa qb) p
--  MV.modify v (\(BiSub a b qa qb) -> BiSub a (THVar p : b) qa qb) p
    -- need to duping guarded variables that are otherwise never bisubbed
--  (void $ dupp p True [m]) -- *> dupp p False [m] {- ? -})
    void $ dupp p False [m]
    biSub t [m]
  (p , THVar m) -> use bis >>= \v -> (_mSub <$> MV.read v m) >>= \t    -> do
--  (void $ dupp m False [p] *> dupp m True [p]) -- ??
--  void $ dupp m True [p]
--  MV.modify v (\(BiSub a b qa qb) -> BiSub (THVar m : a) b qa qb) m
    MV.modify v (\(BiSub a b qa qb) -> BiSub (p : a) b qa qb) m
    biSub [p] t

  (a , b) -> failBiSub "" [a] [b]

-- used for computing both differences between 2 IntMaps
data KeySubtype
  = LOnly Type         -- OK by record | sumtype subtyping
  | ROnly IField Type  -- KO field not present
  | Both  Type Type    -- OK biunify the leaf types

biSubTyCon p m = \case
  (THArrow args1 ret1 , THArrow args2 ret2) -> arrowBiSub (args1,args2) (ret1,ret2)
  (THArrow ars ret ,  THSumTy x) -> pure BiEQ --_
  (THTuple x , THTuple y) -> BiEQ <$ V.zipWithM biSub x y
  (THProduct x , THProduct y) -> use normFields >>= \nf -> let -- record: fields in the second must all be in the first
    merged     = IM.mergeWithKey (\k a b -> Just (Both a b)) (fmap LOnly) (IM.mapWithKey ROnly) x y
    normalized = V.fromList $ IM.elems $ IM.mapKeys (nf VU.!) merged
    go leafCasts normIdx ty = case ty of
      LOnly a   {- drop     -} -> pure $ leafCasts --(field : drops , leafCasts)
      ROnly f a {- no subty -} -> leafCasts <$ failBiSub ("Product type: field not present: " <> show f) [p] [m]
      Both  a b {- leafcast -} -> biSub a b <&> (\x -> (normIdx , x) : leafCasts) -- leaf bicast
    in V.ifoldM go [] normalized <&> \leafCasts ->
       let drops = V.length normalized - length leafCasts -- TODO rm filthy list length
       in if drops > 0
       then CastProduct drops leafCasts -- dropped some fields
       else let leaves = snd <$> leafCasts
       in if all (\case {BiEQ->True;_->False}) leaves then BiEQ else CastLeaves leaves
  (THSumTy x , THSumTy y) -> let
    go label subType = case y IM.!? label of -- y must contain supertypes of all x labels
      Nothing -> failBiSub ("Sum type: label not present: " <> show label) [p] [m]
      Just superType -> biSub superType subType
    in BiEQ <$ (go `IM.traverseWithKey` x) -- TODO bicasts
--(THArrow ars ret, THTuple y) -> pure BiEQ -- labelBiSub-- TODO
  (THTuple y, THArrow ars ret) -> pure BiEQ -- labelBiSub-- TODO
  (a , b) -> failBiSub "Type constructor mismatch" [THTyCon a] [THTyCon b]

arrowBiSub (argsp,argsm) (retp,retm) = let
  bsArgs [] [] = ([] , Nothing , ) <$> biSub retp retm
  bsArgs x  [] = ([] , Just x  , ) <$> biSub (addArrowArgs x retp) retm  -- Partial application
  bsArgs []  x = ([] , Nothing , ) <$> biSub retp (addArrowArgs x retm)  -- Returns a function
  bsArgs (p : ps) (m : ms) = (\arg (xs,pap,retbi) -> (arg:xs , pap , retbi)) <$> biSub m p <*> bsArgs ps ms
  in (\(argCasts, pap, retCast) -> CastApp argCasts pap retCast) <$> bsArgs argsp argsm

primBiSub p1 m1 = case (p1 , m1) of
  (PrimInt p , PrimInt m) -> if p == m then pure BiEQ else if m > p then pure (CastInstr Zext) else (BiEQ <$ failBiSub "Primitive Finite Int" [THPrim p1] [THPrim m1])
  (PrimInt p , PrimBigInt) -> pure (CastInstr (GMPZext p))
  (p , m) -> if (p /= m) then (failBiSub "primitive types" [THPrim p1] [THPrim m1]) else pure BiEQ

-- deciding term equalities ..
termEq t1 t2 = case (t1,t2) of
--(Var v1 , Var v2) -> v1 == v2
  x -> True
--x -> False

-- evaluate type application (from THIxPAp s)
tyAp :: [TyHead] -> IM.IntMap Expr -> [TyHead]
tyAp ty argMap = map go ty where
  go :: TyHead -> TyHead = \case
    THTyCon (THArrow as ret) -> THTyCon $ THArrow (map go <$> as) (go <$> ret)
    x -> x
