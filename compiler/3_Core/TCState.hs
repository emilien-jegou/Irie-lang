{-# LANGUAGE TemplateHaskell #-}
module TCState where
import CoreSyn
import Errors
import Externs
import qualified ParseSyntax as P
import qualified Data.Vector as V
import qualified Data.Vector.Mutable as MV
import Control.Lens

type TCEnv s a = StateT (TCEnvState s) (ST s) a
data TCEnvState s = TCEnvState {
 -- in
   _pBinds  :: V.Vector P.TopBind -- parsed module
 , _externs :: Externs            -- imported bindings
 , _thisMod :: ModuleIName        -- used to make the QName for local bindings

 -- out
 , _wip         :: MV.MVector s Bind
 , _biFails     :: [BiSubError] -- inference failure
 , _scopeFails  :: [ScopeError] -- name not in scope
 , _checkFails  :: [CheckError] -- type annotation doesn't subsume the inferred one

 -- Biunification state
 , _bindWIP     :: IName              -- to identify recursion and mutuals
 , _tmpFails    :: [TmpBiSubError]    -- bisub failures are dealt with at an enclosing App
 , _blen        :: Int                -- cursor for bis whose length may exceed number of active vars
 , _bis         :: MV.MVector s BiSub -- typeVars
 , _argVars     :: MV.MVector s Int   -- arg IName -> TVar map (used to be Arg i => TVar i, but bis should be minimal)
 , _seenVars    :: Integer            -- cache for biunification to avoid looping
 , _escapedVars :: Integer            -- bitmask for TVars of shallower let-nests (don't generalize them until fully captured)

 -- Generalisation state
 , _quants      :: Int     -- fresh names for generalised typevars [A..Z,A1..Z1..]
 , _biEqui      :: MV.MVector s IName -- TVar -> Maybe genned var map (complement 0 indicates Nothing)

 -- Generalisation analysis phase
 , _recVars     :: Integer -- bitmask for recursive TVars
 , _coOccurs    :: MV.MVector s ([Type] , [Type]) -- (pos , neg) occurs are used to enable simplifications
}

makeLenses ''TCEnvState

--tcFail e = error $ e -- Poison e _ --(errors %= (e:)) *> pure (Fail e)

clearBiSubs :: Int -> TCEnv s ()
clearBiSubs n = blen .= n

-- spawn new tvars slots in the bisubs vector
freshBiSubs :: Int -> TCEnv s [Int]
freshBiSubs n = do
  bisubs <- use bis
  biLen  <- use blen
  let tyVars  = [biLen .. biLen+n-1]
  blen .= (biLen + n)
  bisubs <- if MV.length bisubs < biLen + n then MV.grow bisubs n else pure bisubs
  bis .= bisubs
  tyVars `forM` \i -> MV.write bisubs i (BiSub [] [])
  pure tyVars
