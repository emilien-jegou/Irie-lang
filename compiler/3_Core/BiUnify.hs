-- See presentation/TypeTheory for commentary
module BiUnify (bisub , instantiate) where
import Prim
import CoreSyn as C
import Errors
import CoreUtils
import TCState
import PrettyCore
import Externs
import qualified Data.Vector as V
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

-- inferred type: a & (a -> i1 -> i1) -> i1
-- contravariant recursive type; this only makes sense if a is higher rank polymorphic:
-- a & a -> i1 -> i1 => (Π B → B → B)

failBiSub :: BiFail -> Type -> Type -> TCEnv s BiCast
failBiSub msg a b = BiEQ <$ (tmpFails %= (TmpBiSubError msg a b:))

bisub a b = --when global_debug (traceM ("bisub: " <> prettyTyRaw a <> " <==> " <> prettyTyRaw b)) *>
  biSubType a b

biSubTVars :: BitSet -> BitSet -> TCEnv s BiCast
biSubTVars m p = BiEQ <$ (bitSet2IntList m `forM` \v -> biSubTVarTVar v `mapM` bitSet2IntList p)

biSubTVarTVar p m = use bis >>= \v -> MV.read v m >>= \(BiSub p' m') -> do
--  | p == m {-|| p' `hasVar` p-} -> pure BiEQ
  when global_debug (traceM ("bisub: " <> prettyTyRaw (TyVar m) <> " <==> " <> prettyTyRaw (TyVar p)))
  MV.write v m (BiSub (mergeTVar p p') m')
  unless (p == m) $ void $ biSubType (TyVar p) m'
--biSubType (TyVar p) m'
  pure BiEQ

biSubTVarP v m = use bis >>= \b -> MV.read b v >>= \(BiSub p' m') -> case mergeTysNoop m m' of
  Nothing      -> pure BiEQ -- we already bisubbed these, stop here in case this would loop
  Just mMerged -> do
    when global_debug (traceM ("bisub: " <> prettyTyRaw (TyVar v) <> " <==> " <> prettyTyRaw m))
    use escapedVars >>= \escapees -> when (testBit escapees v) $ escapedVars %= (.|. getTVarsType m)
    MV.write b v (BiSub p' mMerged)
    biSubType p' m

biSubTVarM p v = use bis >>= \b -> MV.read b v >>= \(BiSub p' m') -> case mergeTysNoop p p' of
  Nothing      -> pure BiEQ -- we already bisubbed these, stop here in case this would loop
  Just pMerged -> do
  when global_debug (traceM ("bisub: " <> prettyTyRaw p <> " <==> " <> prettyTyRaw (TyVar v)))
  use escapedVars >>= \escapees -> when (testBit escapees v) $ escapedVars %= (.|. getTVarsType p)
  MV.write b v (BiSub pMerged m')
  biSubType p m'

biSubType :: Type -> Type -> TCEnv s BiCast
biSubType tyP tyM =
  let ((pVs , pTs) , (mVs , mTs)) = (partitionType tyP , partitionType tyM) in do
  biSubTVars pVs mVs
  unless (null mTs) $ bitSet2IntList pVs `forM_` \v -> biSubTVarP v (TyGround mTs)
  unless (null pTs) $ bitSet2IntList mVs `forM_` \v -> biSubTVarM (TyGround pTs) v
  biSub pTs mTs
  pure BiEQ

--(TyVar p , TyGround [mRaw]) -> use bis >>= \v -> MV.read v p >>=
--  \(BiSub p' m') -> if mRaw `elem` m' then pure BiEQ else
--  BiEQ <$ do --if False && testBit escapees p then do mE <- extrudeTH escapees mRaw biSub mE [mRaw] biSub [THVar p] mE else do
--    escapees <- use escapedVars
--    when (testBit escapees p) $ escapedVars %= (.|. getTVarsTyHead mRaw)
--    MV.write v p (BiSub p' (mergeTyHeadType mRaw m'))
--    biSubType p' tyM
--(TyGround [pRaw] , TyVar m) -> use bis >>= \v -> MV.read v m >>=
--  \(BiSub p' m') -> if pRaw `elem` p' then pure BiEQ else
--  BiEQ <$ do-- if False && testBit escapees m then do pE <- extrudeTH escapees pRaw biSub [pRaw] pE biSub pE [THVar m] else do
--    escapees <- use escapedVars
--    when (testBit escapees m) $ escapedVars %= (.|. getTVarsTyHead pRaw)
--    MV.write v m (BiSub (mergeTyHeadType pRaw p') m')
--    biSubType tyP m'

-- bisub on ground types
biSub :: [TyHead] -> [TyHead] -> TCEnv s BiCast
biSub a b = let
  in case (a , b) of
  -- lattice top and bottom
  ([] ,  _)  -> pure BiEQ
  (_  , [])  -> pure BiEQ
  ([p] , [m])-> atomicBiSub p m
  -- lattice subconstraints
  (p:ps@(p1:p2) , m) -> biSub [p] m *> biSub ps m
  (p , m:ms) -> biSub p [m] *> biSub p ms

-- Instantiation; substitute quantified variables with fresh type vars;
-- Note. weird special case (A & {f : B}) typevars as produced by lens over
--   The A serves to propagate the input record, minus the lens field
--   what is meant is really set difference: A =: A // { f : B }
instantiate nb m x = freshBiSubs (nb + if m >= 0 then m+1 else 0) >>= \tvars@(tvStart:_) -> doInstantiate tvStart x

-- Replace THBound with fresh TVars
doInstantiate :: Int -> Type -> TCEnv s Type
doInstantiate tvarStart ty = let
  mapFn = let
    r = doInstantiate tvarStart
    in \case
    THBound i   -> pure (0 `setBit` (tvarStart + i) , [])
    THMuBound i -> pure (0 `setBit` (tvarStart + i) , [])
    THTyCon t -> (\x -> (0 , [THTyCon x])) <$> case t of
      THArrow as ret -> THArrow   <$> (r `mapM` as) <*> (r ret)
      THProduct as   -> THProduct <$> (r `mapM` as)
      THTuple as     -> THTuple   <$> (r `mapM` as)
      THSumTy as     -> THSumTy   <$> (r `mapM` as)
    t -> pure (0 , [t])
  instantiateGround g = mapFn `mapM` g <&> unzip <&> \(tvars , ty) -> let
    tvs = foldr (.|.) 0 tvars
    groundTys = concat ty
    in if tvs == 0 then TyGround groundTys else TyVars tvs groundTys
  in case ty of 
    TyGround g -> instantiateGround g
    TyVars vs g -> mergeTypes (TyVars vs []) <$> instantiateGround g
    TyVar v -> pure (TyVar v)

atomicBiSub :: TyHead -> TyHead -> TCEnv s BiCast
atomicBiSub p m = let tyM = TyGround [m] ; tyP = TyGround [p] in
 when global_debug (traceM ("⚛bisub: " <> prettyTyRaw tyP <> " <==> " <> prettyTyRaw tyM)) *>
 use escapedVars >>= \escapees -> case (p , m) of
  (_ , THTop) -> pure (CastInstr MkTop)
  (THBot , _) -> pure (CastInstr MkBot)
  (THPrim p1 , THPrim p2) -> primBiSub p1 p2
  (THExt a , THExt b) | a == b -> pure BiEQ
  (p , THExt i) -> biSubType tyP     =<< fromJust . tyExpr . (`readPrimExtern` i) <$> use externs
  (THExt i , m) -> (`biSubType` tyM) =<< fromJust . tyExpr . (`readPrimExtern` i) <$> use externs

  -- Bound vars (removed at +THBi, so should never be encountered during biunification)
  (THBound i , x)   -> error $ "unexpected THBound: " <> show i
  (x , THBound i)   -> error $ "unexpected THBound: " <> show i
  (x , THBi nb m y) -> error $ "unexpected THBi: "    <> show (p,m)

  (THBi nb mus p , m) -> do
    instantiated <- instantiate nb mus p
    biSubType instantiated tyM

  (THTyCon t1 , THTyCon t2) -> biSubTyCon p m (t1 , t2)

--(THPi (Pi p ty) , y) -> biSub ty [y]
--(x , THPi (Pi p ty)) -> biSub [x] ty
  (THSet u , x) -> pure BiEQ
  (x , THSet u) -> pure BiEQ

  (x , THTyCon THArrow{}) -> failBiSub (TextMsg "Excess arguments")       (TyGround [p]) (TyGround [m])
  (THTyCon THArrow{} , x) -> failBiSub (TextMsg "Insufficient arguments") (TyGround [p]) (TyGround [m])
  (a , b) -> failBiSub (TextMsg "Incompatible types") (TyGround [a]) (TyGround [b])

--extrude :: BitSet -> Type -> TCEnv s Type
--extrude escapees t = concat <$> mapM (extrudeTH escapees) t
--
--extrudeTH :: BitSet -> TyHead -> TCEnv s Type
--extrudeTH escapees = let e = extrude escapees in \case
--  THVar   v -> (\x -> [x]) <$> (if escapees `testBit` v then pure (THVar v) else (freshBiSubs 1 <&> \[i] -> THVar i))
--  THVars vs -> fmap concat $ (extrudeTH escapees . THVar) `mapM` bitSet2IntList vs
--  THTyCon t -> (\x -> [THTyCon x]) <$> case t of
--    THArrow ars r -> THArrow   <$> (traverse e ars) <*> e r
--    THProduct   r -> THProduct <$> (traverse e r)
--    THSumTy     r -> THSumTy   <$> (traverse e r)
--    THTuple     r -> THTuple   <$> (traverse e r)
--  x -> case x of
--    THExt{}  -> pure [x]
--    THPrim{} -> pure [x]
--    THBot{} -> pure [x]
--    THTop{} -> pure [x]
--    x -> error $ show x
--x -> x

-- TODO cache THTycon contained vars?
getTVarsType = \case
  TyVar v -> setBit 0 v
  TyVars vs g -> vs .|. foldr (.|.) 0 (getTVarsTyHead <$> g)
  TyGround  g -> foldr (.|.) 0 (getTVarsTyHead <$> g)
getTVarsTyHead :: TyHead -> BitSet
getTVarsTyHead = \case
--THVar   v -> setBit 0 v
--THVars vs -> vs
  THTyCon t -> case t of
    THArrow ars r -> foldr (.|.) 0 (getTVarsType r : (getTVarsType <$> ars) )
    THProduct   r -> foldr (.|.) 0 (getTVarsType <$> IM.elems r)
    THSumTy     r -> foldr (.|.) 0 (getTVarsType <$> IM.elems r)
    THTuple     r -> foldr (.|.) 0 (getTVarsType <$> r)
--THBi _ t -> getTVarsType t
  x -> 0

-- used for computing both differences between 2 IntMaps (alignWith doesn't give access to the ROnly map key)
data KeySubtype
  = LOnly Type       -- OK by record | sumtype subtyping
  | ROnly IName Type -- KO field not present (IName here is a field or label name)
  | Both  Type Type  -- biunify the leaf types

-- This is complicated slightly by needing to recover the necessary subtyping casts
biSubTyCon p m = let tyP = TyGround [p] ; tyM = TyGround [m] in \case
  (THArrow args1 ret1 , THArrow args2 ret2) -> arrowBiSub (args1,args2) (ret1,ret2)
  (THArrow ars ret ,  THSumTy x) -> pure BiEQ --_
  (THTuple x , THTuple y) -> BiEQ <$ V.zipWithM biSubType x y
  (THProduct x , THProduct y) -> let --use normFields >>= \nf -> let -- record: fields in the second must all be in the first
    merged     = IM.mergeWithKey (\k a b -> Just (Both a b)) (fmap LOnly) (IM.mapWithKey ROnly) x y
--  normalized = V.fromList $ IM.elems $ IM.mapKeys (nf VU.!) merged
    normalized = V.fromList $ IM.elems merged -- $ IM.mapKeys (nf VU.!) merged
    go leafCasts normIdx ty = case ty of
      LOnly a   {- drop     -} -> pure $ leafCasts --(field : drops , leafCasts)
      ROnly f a {- no subty -} -> leafCasts <$ failBiSub (AbsentField (QName f)) tyP tyM
      Both  a b {- leafcast -} -> biSubType a b <&> (\x -> (normIdx , x) : leafCasts) -- leaf bicast
    in V.ifoldM go [] normalized <&> \leafCasts ->
       let drops = V.length normalized - length leafCasts -- TODO rm filthy list length
       in if drops > 0
       then CastProduct drops leafCasts -- dropped some fields
       else let leaves = snd <$> leafCasts
       in if all (\case {BiEQ->True;_->False}) leaves then BiEQ else CastLeaves leaves
  (THSumTy x , THSumTy y) -> let
    go label subType = case y IM.!? label of -- y must contain supertypes of all x labels
      Nothing -> failBiSub (AbsentLabel (QName label)) tyP tyM
      Just superType -> biSubType subType superType
    in BiEQ <$ (go `IM.traverseWithKey` x) -- TODO bicasts
  (THSumTy s , THArrow args retT) | [(lName , tuple)] <- IM.toList s -> -- singleton sumtype => Partial application of Label
    let t' = TyGround $ case tuple of
               TyGround [THTyCon (THTuple x)] -> [THTyCon $ THTuple (x V.++ V.fromList args)]
               x                              -> [THTyCon $ THTuple (V.fromList (x : args))]
    in biSubType (TyGround [THTyCon (THSumTy $ IM.singleton lName t')]) retT
  (THSumTy s , THArrow{}) | [single] <- IM.toList s -> failBiSub (TextMsg "Note. Labels must be fully applied to avoid ambiguity") tyP tyM
  (a , b)         -> failBiSub TyConMismatch tyP tyM

arrowBiSub (argsp,argsm) (retp,retm) = let
  bsArgs [] [] = ([] , Nothing , ) <$> biSubType retp retm
  bsArgs x  [] = ([] , Just x  , ) <$> biSubType (prependArrowArgsTy x retp) retm  -- Partial application
  bsArgs []  x = ([] , Nothing , ) <$> biSubType retp (prependArrowArgsTy x retm)  -- Returns a function
  bsArgs (p : ps) (m : ms) = (\arg (xs,pap,retbi) -> (arg:xs , pap , retbi)) <$> biSubType m p <*> bsArgs ps ms
  in (\(argCasts, pap, retCast) -> CastApp argCasts pap retCast) <$> bsArgs argsp argsm

primBiSub p1 m1 = case (p1 , m1) of
  (PrimInt p , PrimInt m) -> if p == m then pure BiEQ else if m > p then pure (CastInstr Zext) else (BiEQ <$ failBiSub (TextMsg "Primitive Finite Int") (TyGround [THPrim p1]) (TyGround [THPrim m1]))
  (PrimInt p , PrimBigInt) -> pure (CastInstr (GMPZext p))
  (p , m) -> if (p /= m) then (failBiSub (TextMsg "primitive types") (TyGround [THPrim p1]) (TyGround [THPrim m1])) else pure BiEQ

-- deciding term equalities ..
termEq t1 t2 = case (t1,t2) of
--(Var v1 , Var v2) -> v1 == v2
  x -> True
--x -> False

-- evaluate type application (from THIxPAp s)
--tyAp :: [TyHead] -> IM.IntMap Expr -> [TyHead]
--tyAp ty argMap = map go ty where
--  go :: TyHead -> TyHead = \case
--    THTyCon (THArrow as ret) -> THTyCon $ THArrow (map go <$> as) (go <$> ret)
--    x -> x
