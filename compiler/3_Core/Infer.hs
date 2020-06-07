-- see "Algebraic subtyping" by Stephen Dolan <https://www.cl.cam.ac.uk/~sd601/thesis.pdf>

module Infer where
import Prim
import BiUnify
import qualified ParseSyntax as P
import CoreSyn as C
import TCState
import PrettyCore
import DesugarParse
import Externs

import qualified Data.Vector as V
import qualified Data.Vector.Mutable as MV -- mutable vectors
--import qualified Data.Vector.Generic.Mutable as MV (growFront) -- mutable vectors
import Control.Monad.ST
import qualified Data.Map as M
import qualified Data.IntMap as IM
import qualified Data.Text as T
import Data.Functor
import Control.Monad
import Control.Applicative
import Control.Monad.Trans.State.Strict
import Data.List --(foldl', intersect)
import Data.STRef
import Control.Lens

import Debug.Trace

-- test1 x = x.foo.bar{foo=3}

judgeModule :: P.Module -> Externs -> V.Vector Bind
judgeModule pm exts@(Externs extNames extBinds) = let
  nBinds = length $ pm ^. P.bindings
  nArgs  = pm ^. P.parseDetails . P.nArgs
  go  = judgeBind `mapM_` [0 .. nBinds-1]
  in V.create $ do
    v    <- MV.new 0
    wips <- MV.replicate nBinds WIP
    d    <- MV.new nArgs
    (\i->MV.write d i (BiSub [THArg i] [THArg i])) `mapM_` [0 .. nArgs-1]
    execStateT go $ TCEnvState
      { _pmodule  = pm
      , _externs  = exts
      , _wip      = wips
      , _bis      = v
      , _domain   = d
      }
    dv_ d
    pure wips

-- add argument holes to monotype env and guard against recursion
withDomain :: IName -> [Int] -> (TCEnv s a) -> TCEnv s (a , MV.MVector s BiSub)
withDomain bindINm idxs action = do
  d <- use domain
  -- anticipate recursive type
  use wip >>= (\v -> MV.write v bindINm (Checking [THRec bindINm]))
  r <- action
  argTys <- case idxs of
    [] -> MV.new 0
    x  -> pure $ MV.slice (head idxs) (length idxs) d
  pure (r , argTys)

-- do a bisub with typevars
withBiSubs :: Int -> (Int->TCEnv s a) -> TCEnv s (a , MV.MVector s BiSub)
withBiSubs n action = do
  bisubs <- use bis
  let biSubLen = MV.length bisubs
      genFn i = let tv = [THVar i] in BiSub tv tv
  bisubs <- MV.grow bisubs n
  (\i->MV.write bisubs i (genFn i)) `mapM` [biSubLen .. biSubLen+n-1]
  bis .= bisubs
  ret <- action biSubLen
  let vars = MV.slice biSubLen n bisubs
  pure (ret , vars)

judgeBind :: IName -> TCEnv s Bind
judgeBind bindINm = use wip >>= (`MV.read` bindINm) >>= \case
  t@BindTerm{} -> pure t
  t@BindType{} -> pure t
  Checking  ty -> pure $ BindTerm [] (Var$VBind bindINm) ty
  WIP -> mdo
    P.FunBind hNm implicits matches tyAnn
      <- (!! bindINm) <$> use (id . pmodule . P.bindings)
    let (mainArgs , mainArgTys , tt) = matches2TT matches
        args = implicits ++ mainArgs
        nArgs = length args

    (expr , argSubs) <- withDomain bindINm args (infer tt)
    argTys <- fmap _mSub <$> V.freeze argSubs
    -- Generalization ?!
    (newBind , bindTy) <- case expr of
      Core x t -> let
        bindTy=if nArgs==0 then t else[THArrow (V.toList argTys) t]
        in pure $ (BindTerm args x bindTy , bindTy)
      Ty   t   -> pure $ (BindType args t , [THSet 0]) -- args ? TODO
    case tyAnn of
      Nothing  -> pure ()
      Just ann -> do
        ann' <- infer ann
--      let implicitArgTys = (\x->[THArg x]) `map` implicits
--          annTy = [THArrow implicitArgTys (tyExpr ann')]
        let annTy = tyExpr ann'
        exts <- use externs
        unless (check exts argTys bindTy annTy)
          $ error (show bindTy ++ "\n!<:\n" ++ show ann')
    (\v -> MV.write v bindINm newBind) =<< use wip
    pure newBind

infer :: P.TT -> TCEnv s Expr
infer = let
 -- expr found in type context (should be a type or var)
 -- in product types, we fold with ttApp to find type arguments
 yoloGetTy :: Expr -> Type
 yoloGetTy = \case
   Ty x -> x
   Core (Var v) typed -> case v of
     VBind i -> [THAlias i]
     VArg  i -> [THArg i]
     VExt  i -> [THExt i]
   Core e ty -> _ --[THEta e ty]
   x -> error $ "type expected: " ++ show x
 in \case
  P.WildCard -> pure $ Ty tyTOP
  -- vars : lookup in appropriate environment
  P.Var v -> case v of
    P.VBind b   -> -- polytype env
      judgeBind b <&> \case
        BindTerm args e ty -> Core (Var $ VBind b) ty
        BindType [] ty -> Ty ty
        BindType args ty -> Ty [THIxPAp args ty M.empty M.empty]
        x -> error $ show x -- recursion guard ?
    P.VLocal l  -> do -- monotype env (fn args)
      pure $ Core (Var $ VArg l) [THArg l]
    P.VExtern i -> (`readParseExtern` i) <$> use externs
    x -> error $ show x

  -- APP: f : [Df-]ft+ , Pi ^x : [Df-]ft+ ==> e2:[Dx-]tx+
  -- |- f x : biunify [Df n Dx]tx+ under (tf+ <= tx+ -> a)
  -- * introduce a typevar 'a', and biunify (tf+ <= tx+ -> a)
  -- Structurally infer Dependent App:
  P.App f args -> let
    ttApp :: Expr -> Expr -> Expr
    ttApp a b = case (a , b) of
      (Core t ty , Core t2 ty2) -> case t of
        App f x -> Core (App f (x++[t2])) [] -- dont' forget to set retTy
        _       -> Core (App t [t2])      []
      (Ty fn@[THIxPAp ars ty typeArgs termArgs] , ttArg) -> case (ars , ttArg) of
         (lam:arNms , Core t ty) -> Ty [THIxPAp arNms ty typeArgs (M.insert lam t termArgs)]
         (lam:arNms , Ty tArg) -> Ty [THIxPAp arNms ty (M.insert lam tArg typeArgs) termArgs]
         (arNms , Ty [THIxPAp arNms' ty' typeArgs' termArgs']) ->
           error (" --- " ++ show a ++ "\n- " ++ show b)
         (arNms , t) -> error $ "not a function: " ++ show (tyAp ty typeArgs)  ++ "\napplied to: " ++ show t
      (f,a) -> error $ "panic: not a function: " ++ show f ++ "\n applied to arg: " ++ show a
    in do
    f'    <- infer f
    args' <- infer `mapM` args
    case f' of
      -- special case: Array Literal
      Core (Lit l) ty -> do
        let getLit (Core (Lit l) _) = Just l
            getLit x = Nothing
            argLits = case sequence $ getLit <$> args' of
              Just ars -> ars
              Nothing  -> error $ "not a function: " ++ show l
        pure $ Core (Lit . Array $ l : argLits) [THArray ty]
        -- TODO merge (join) all tys ?

      -- special case: "->" THArrow tycon. ( : Set->Set->Set)
      Core (Instr ArrowTy) _ty -> let
        getTy t = yoloGetTy t --case yoloGetTy t of { Ty t -> t }
        (ars, [ret]) = splitAt (length args' - 1) (getTy <$> args')
        in pure $ Ty [THArrow ars ret]

      -- normal function app
      f' -> do
        bs <- snd <$> withBiSubs 1 (\idx ->
            biSub_ (getArgTy f') [THArrow (getArgTy <$> args') [THVar idx]])
        retTy <- _pSub <$> (`MV.read` 0) bs
        pure $ case foldl' ttApp f' args' of
          Core f _ -> Core f retTy
          t -> t

  -- Record
  P.Cons construct   -> do -- assign arg types to each label (cannot fail)
    let (fields , rawTTs) = unzip construct
    exprs <- infer `mapM` rawTTs
    let (tts , tys) = unzip $ (\case { Core t ty -> (t , ty) }) <$> exprs
    pure $ Core (Cons (M.fromList $ zip fields tts)) [THProd (M.fromList $ zip fields tys)]

  P.Proj tt field -> do -- biunify (t+ <= {l:a})
    recordTy <- infer tt
    bs <- snd <$> withBiSubs 1 (\ix ->
      biSub_ (getArgTy recordTy)
             [THProd (M.singleton field [THVar ix])])
    retTy <- _pSub <$> (`MV.read` 0) bs
    pure $ case recordTy of
      Core f _ -> Core (Proj f field) retTy
      t -> t

  -- Sum
  -- TODO label should biunify with the label's type if known
  P.Label l tts -> do
    tts' <- infer `mapM` tts
    let unwrap = \case { Core t ty -> (t , ty) }
        (terms , tys) = unzip $ unwrap <$> tts'
    pure $ Core (Label l terms) [THSum $ M.fromList [(l , tys)]]

--  P.TySum alts -> let
--    mkTyHead mp = Ty $ [THSum mp]
--    in do
--      sumArgsMap <- (\(l,impls,ty)->(l,)<$>infer ty) `mapM` alts
----    pure . mkTyHead $ map yoloGetTy <$> sumArgsMap
--      pure $ Ty $ M.fromList sumArgsMap

--P.Match alts -> let
--    (labels , patterns , rawTTs) = unzip3 alts
--  -- * find the type of the sum type being deconstructed
--  -- * find the type of it's alts (~ lambda abstractions)
--  -- * type of Match is (sumTy -> Join altTys)
--  in do
--  (exprs , vArgSubs) <-
--    unzip <$> (withBiSubs 1 . (\t _->infer t)) `mapM` rawTTs
--  let vArgTys = (_mSub <$>) <$> vArgSubs
--      (altTTs , altTys) = unzip
--        $ (\case { Core t ty -> (t , ty) }) <$> exprs
--      argTys  = V.toList <$> vArgTys
--      sumTy   = [THSum . M.fromList $ zip labels argTys]
--      matchTy = [THArrow [sumTy] (concat $ altTys)]
--      labelsMap = M.fromList $ zip labels altTTs
--  pure $ Core (Match labelsMap Nothing) matchTy

  P.MultiIf branches elseE -> do -- Bool ?
    let (rawConds , rawAlts) = unzip branches
        boolTy = getPrimIdx "Bool" & \case
          { Just i->THExt i; Nothing->error "panic: \"Bool\" not in scope" }
        addBool = doSub boolTy
    condExprs <- infer `mapM` rawConds
    alts      <- infer `mapM` rawAlts
    elseE'    <- infer elseE
    let retTy = foldr1 mergeTypes (getArgTy <$> (alts ++ [elseE'])) :: [TyHead]
        condTys = getArgTy <$> condExprs
        e2t (Core e ty) = e
        ifE = MultiIf (zip (e2t<$>condExprs) (e2t<$>alts)) (e2t elseE') 

    (`biSub_` [boolTy]) `mapM` condTys -- check the condTys all subtype bool
    pure $ Core ifE retTy

  -- desugar
  P.Lit l  -> pure $ Core (Lit l) [typeOfLit l]
  P.TyListOf t -> (\x-> Ty [THArray x]) . yoloGetTy <$> infer t
  P.InfixTrain lArg train -> infer $ resolveInfixes _ lArg train
  x -> error $ "inference engine not ready for parsed tt: " ++ show x
